defmodule BullXGateway.Adapter do
  @moduledoc """
  Behaviour implemented by outbound channel adapters.

  Gateway core owns delivery orchestration, retries, DLQ, and dedupe. Adapters
  only translate a `BullXGateway.Delivery` into a transport-specific side
  effect and may start transport-local children for a `{adapter, channel_id}`
  channel. `capabilities/0` is the contract Gateway uses to decide which
  operations and metadata shapes a channel actually supports.
  """

  @type context :: %{
          required(:channel) => BullXGateway.Delivery.channel(),
          required(:config) => map(),
          required(:telemetry) => map(),
          optional(atom()) => term()
        }

  @type op_capability :: :send | :edit | :stream
  @type metadata_capability :: :reactions | :cards | :threads | atom()
  @type capability :: op_capability() | metadata_capability()
  @type localized_url_map :: %{String.t() => String.t()}
  @type connectivity_result :: %{
          required(String.t()) => term(),
          optional(String.t()) => term()
        }

  @callback adapter_id() :: atom()
  @callback config_docs() :: localized_url_map()
  @callback connectivity_check(channel :: BullXGateway.Delivery.channel(), config :: map()) ::
              {:ok, connectivity_result()} | {:error, map()}
  @callback child_specs(channel :: BullXGateway.Delivery.channel(), config :: map()) ::
              [Supervisor.child_spec()]
  @callback deliver(BullXGateway.Delivery.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
  @callback stream(BullXGateway.Delivery.t(), Enumerable.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
  @callback capabilities() :: [capability()]

  @optional_callbacks child_specs: 2, deliver: 2, stream: 3

  @spec config_doc_url(module(), String.t() | atom()) :: String.t() | nil
  def config_doc_url(adapter_module, locale) when is_atom(adapter_module) do
    docs = adapter_module.config_docs()
    locale = normalize_locale(locale)

    Map.get(docs, locale) || Map.get(docs, "en-US")
  end

  defp normalize_locale(locale) when is_atom(locale), do: Atom.to_string(locale)
  defp normalize_locale(locale) when is_binary(locale), do: locale
  defp normalize_locale(_locale), do: "en-US"
end
