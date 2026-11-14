defmodule DruzhokWebWeb.DocsController do
  @moduledoc """
  `POST /v2/docs/convert`, multipart: `file` (required), `to` (one of
  `Druzhok.Docs.targets/0`), optional `filter` (an export filter allowed for
  `to`). Answers 200 with the converted file, or JSON
  `{"error": code, "message": Russian text}`:

  | status | code | when |
  |---|---|---|
  | 400 | `bad_request` | no file, bad `to` or `filter`, not multipart |
  | 413 | `too_large` | file over 20 MiB (body over that plus 64 KiB of framing) |
  | 415 | `unsupported_type` | input extension not allowed (PDF included) |
  | 422 | `convert_failed` | soffice could not convert it |
  | 429 | `busy` | the line is full, or this bot already has a job |
  | 503 | `low_memory` | `MemAvailable` under `docs_min_free_mb` |
  | 503 | `unavailable` | the converter is not installed or refused to run |
  | 504 | `timeout` | the job ran out of time |

  The body is read here, after `Plugs.DocsAuth` (the endpoint skips this
  path), in chunks to a temp file, cut at the limit.
  """

  use DruzhokWebWeb, :controller

  alias Druzhok.Docs

  @codes %{
    "bad_request" =>
      {400, "Неверный запрос: нужен файл (file) и формат (to): pdf, docx, xlsx, pptx, odt, ods, odp или csv."},
    "too_large" => {413, "Файл больше 20 МБ: такой конвертер не примет."},
    "unsupported_type" =>
      {415, "Этот тип файла не конвертируется. Можно: doc, docx, odt, rtf, txt, html, xls, xlsx, ods, csv, ppt, pptx, odp."},
    "convert_failed" => {422, "Не удалось сконвертировать файл: возможно, он повреждён или формат не подходит."},
    "busy" => {429, "Конвертер документов сейчас занят. Подождите минуту и попробуйте ещё раз."},
    "low_memory" => {503, "Сейчас на сервере мало памяти для конвертации. Подождите минуту и попробуйте ещё раз."},
    "unavailable" => {503, "Конвертер документов сейчас недоступен."},
    "timeout" => {504, "Конвертация заняла слишком много времени и была остановлена."}
  }

  # Druzhok.Docs.convert/6's reasons.
  @reasons %{
    busy: "busy",
    low_memory: "low_memory",
    timeout: "timeout",
    failed: "convert_failed",
    unavailable: "unavailable"
  }

  # A conversion can wait in line for minutes; queue mode's drain must not
  # stop the bot under it (`Druzhok.Inflight`).
  def action(conn, opts) do
    ref = Druzhok.Inflight.enter(conn.assigns.instance.id)

    try do
      super(conn, opts)
    after
      Druzhok.Inflight.leave(ref)
    end
  end

  def convert(conn, _params) do
    if declared_too_large?(conn) do
      refuse(conn, "too_large")
    else
      case read_form(conn) do
        {:ok, conn} -> convert_upload(conn)
        {:error, code} -> refuse(conn, code)
      end
    end
  end

  defp convert_upload(conn) do
    params = conn.body_params

    try do
      case fields(params) do
        {:ok, upload, to, filter} ->
          if file_size(upload.path) > Docs.max_input_bytes(),
            do: refuse(conn, "too_large"),
            else: run(conn, upload, to, filter)

        {:error, code} -> refuse(conn, code)
      end
    after
      cleanup(params)
    end
  end

  defp run(conn, upload, to, filter) do
    case input_ext(upload.filename) do
      {:ok, ext} ->
        name = result_name(upload.filename, to)

        case Docs.convert(conn.assigns.instance, upload.path, ext, to, filter, &send_result(conn, &1, name, to)) do
          {:ok, conn} ->
            conn

          {:error, reason} ->
            refuse(conn, Map.fetch!(@reasons, reason))
        end

      :error ->
        refuse(conn, "unsupported_type")
    end
  end

  defp fields(params) do
    to = params["to"]
    filter = if params["filter"] in [nil, ""], do: nil, else: params["filter"]

    with %Plug.Upload{} = upload <- params["file"],
         true <- to in Docs.targets(),
         true <- is_nil(filter) or (is_binary(filter) and Docs.valid_filter?(to, filter)) do
      {:ok, upload, to, filter}
    else
      _ -> {:error, "bad_request"}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp input_ext(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    if ext in Docs.inputs(), do: {:ok, ext}, else: :error
  end

  defp input_ext(_), do: :error

  defp read_form(conn) do
    opts =
      Plug.Parsers.init(
        parsers: [:multipart],
        pass: [],
        length: Docs.max_body_bytes(),
        read_length: 1_000_000
      )

    {:ok, Plug.Parsers.call(conn, opts)}
  rescue
    Plug.Parsers.RequestTooLargeError -> {:error, "too_large"}
    e -> if Plug.Exception.status(e) in 400..499, do: {:error, "bad_request"}, else: reraise(e, __STACKTRACE__)
  end

  defp declared_too_large?(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n > Docs.max_body_bytes()
    else
      _ -> false
    end
  end

  # Plug deletes its temp files only when the connection process ends, which
  # keep-alive delays: the upload goes as soon as the request is answered.
  # Nested too: `file[]` or `file[x]` puts uploads in lists and maps.
  defp cleanup(%Plug.Upload{path: path}), do: File.rm(path)
  defp cleanup(%{} = map) when not is_struct(map), do: Enum.each(map, fn {_, v} -> cleanup(v) end)
  defp cleanup(list) when is_list(list), do: Enum.each(list, &cleanup/1)
  defp cleanup(_), do: :ok

  defp send_result(conn, path, name, to) do
    conn
    |> put_resp_content_type(MIME.type(to), nil)
    |> put_resp_header("content-disposition", disposition(name))
    |> send_file(200, path)
  end

  @doc false
  # "<the upload's own name>.<to>", for the header only: the file on disk is
  # always `input.<to>`.
  def result_name(filename, to) do
    base =
      (filename || "")
      |> String.split(["/", "\\"])
      |> List.last()
      |> Path.rootname()
      |> String.replace(~r/[\x00-\x1f\x7f"]/u, "")
      |> String.trim()

    if base == "", do: "document." <> to, else: base <> "." <> to
  end

  defp disposition(name) do
    ascii = String.replace(name, ~r/[^A-Za-z0-9._ -]/u, "_")
    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end

  defp refuse(conn, code) do
    {status, message} = Map.fetch!(@codes, code)
    conn |> put_status(status) |> json(%{error: code, message: message})
  end
end
