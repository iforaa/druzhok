defmodule DruzhokWebWeb.LlmProxy.BalanceNoticeTest do
  use ExUnit.Case, async: true

  alias DruzhokWebWeb.LlmProxy.BalanceNotice

  # Anyone in the chat reads this, and only the owner can pay: it names the
  # plan and offers no top-up (that is Druzhok.Cabinet's note).
  test "names the plan's limit in the bot's language, without a top-up" do
    assert BalanceNotice.text(%{language: "ru"}) ==
             "Лимит тарифа на сейчас исчерпан. Когда он обновится и как сменить тариф — в «Кабинете»."

    assert BalanceNotice.text(%{language: "en"}) ==
             "The plan's limit is used up for now. When it resets and how to change plans — in «Кабинет»."

    assert BalanceNotice.text(%{language: "de"}) == BalanceNotice.text(%{language: "en"})

    for lang <- ["ru", "en"] do
      refute BalanceNotice.text(%{language: lang}) =~ ~r/пополн|баланс|top.?up|balance/iu
    end
  end
end
