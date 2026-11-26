defmodule DruzhokWebWeb.LlmProxy.BalanceNoticeTest do
  use ExUnit.Case, async: true

  alias DruzhokWebWeb.LlmProxy.BalanceNotice

  # Anyone in the chat reads this, and only the owner can pay: it sends them
  # to the owner, and offers no top-up (that is Druzhok.Cabinet's note).
  test "points chatters at the owner, in the bot's language, without a top-up" do
    assert BalanceNotice.text(%{language: "ru"}) ==
             "Лимит тарифа на сейчас исчерпан. Подробности — у владельца бота в «Кабинете»."

    assert BalanceNotice.text(%{language: "en"}) ==
             "The plan's limit is used up for now. The bot's owner has the details in «Кабинет»."

    assert BalanceNotice.text(%{language: "de"}) == BalanceNotice.text(%{language: "en"})

    for lang <- ["ru", "en"] do
      refute BalanceNotice.text(%{language: lang}) =~ ~r/пополн|баланс|top.?up|balance/iu
    end
  end
end
