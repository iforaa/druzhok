defmodule PiCore.Tools.Schema do
  alias PiCore.Tools.Tool

  def to_openai(%Tool{} = tool) do
    properties = Map.new(tool.parameters, fn {name, spec} ->
      type_str = to_string(spec[:type] || Map.get(spec, :type))
      prop = %{"type" => type_str}
      desc = spec[:description] || Map.get(spec, :description, nil)
      prop = if desc, do: Map.put(prop, "description", desc), else: prop
      {to_string(name), prop}
    end)
    required = tool.parameters
      |> Enum.reject(fn {_name, spec} -> spec[:required] == false end)
      |> Enum.map(fn {name, _spec} -> to_string(name) end)
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => %{"type" => "object", "properties" => properties, "required" => required}
      }
    }
  end

  def to_openai_list(tools), do: Enum.map(tools, &to_openai/1)
end
