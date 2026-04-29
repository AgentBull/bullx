defmodule BullXAIAgent.ModelAliases do
  @moduledoc """
  Four-alias model resolution backed by the LLM provider catalog.

  Allowed aliases are statically `:default`, `:fast`, `:heavy`, and
  `:compression`. Each persisted alias binding targets a provider row. When
  `:fast` or `:heavy` has no row, it reuses the `:default` provider; when
  `:compression` has no row, it reuses the resolved `:fast` provider.
  """

  @type alias_name :: :default | :fast | :heavy | :compression

  @aliases [:default, :fast, :heavy, :compression]

  @spec aliases() :: [alias_name()]
  def aliases, do: @aliases

  @spec alias?(term()) :: boolean()
  def alias?(value), do: value in @aliases

  @spec resolve_model(alias_name()) :: BullXAIAgent.LLM.ResolvedProvider.t() | no_return()
  def resolve_model(alias_name) when alias_name in @aliases do
    BullXAIAgent.LLM.Catalog.resolve_alias!(alias_name)
  end

  def resolve_model(other) do
    raise ArgumentError,
          "Unknown model alias: #{inspect(other)}. " <>
            "Allowed aliases are :default, :fast, :heavy, :compression."
  end
end
