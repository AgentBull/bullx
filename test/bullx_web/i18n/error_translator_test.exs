defmodule BullXWeb.I18n.ErrorTranslatorTest do
  use ExUnit.Case, async: false

  alias BullXWeb.I18n.ErrorTranslator

  test "translates length validations through the TOML key skeleton" do
    assert ErrorTranslator.translate_error(
             {"should be at least %{count} character(s)",
              [validation: :length, kind: :min, type: :string, count: 2]}
           ) == "should be at least 2 characters"
  end

  test "translates number validations through the TOML key skeleton" do
    assert ErrorTranslator.translate_error(
             {"must be less than %{number}", [validation: :number, kind: :less_than, number: 2]}
           ) == "must be less than 2"
  end
end
