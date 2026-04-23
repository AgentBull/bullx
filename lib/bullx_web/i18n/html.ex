defmodule BullXWeb.I18n.HTML do
  @moduledoc """
  HEEx/EEx translation helpers.

  Imported into every `BullXWeb.html/0`-using module (controllers,
  LiveViews, components). Forwards directly to `BullX.I18n.t/3`;
  no separate HEEx-specific behavior.

  Locale is read from the application-global default — templates do
  NOT need a `locale` assign. RFC 0007 §8.

  ### Example

      <p><%= t("users.greeting", name: @user.name) %></p>
  """

  @doc "See `BullX.I18n.t/3`."
  @spec t(String.t()) :: String.t()
  def t(key), do: BullX.I18n.t(key, %{}, [])

  @spec t(String.t(), BullX.I18n.bindings()) :: String.t()
  def t(key, bindings), do: BullX.I18n.t(key, bindings, [])

  @spec t(String.t(), BullX.I18n.bindings(), BullX.I18n.opts()) :: String.t()
  def t(key, bindings, opts), do: BullX.I18n.t(key, bindings, opts)
end
