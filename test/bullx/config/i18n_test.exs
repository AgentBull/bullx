defmodule BullX.Config.I18nTest do
  use ExUnit.Case, async: false

  alias BullX.Config.I18n

  setup do
    previous = Application.get_env(:bullx, :i18n)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :i18n)
        value -> Application.put_env(:bullx, :i18n, value)
      end
    end)

    :ok
  end

  test "reads boot/static I18n config through BullX.Config" do
    Application.put_env(:bullx, :i18n, locales_dir: "tmp/locales")

    assert I18n.i18n_locales_dir!() == "tmp/locales"
  end
end
