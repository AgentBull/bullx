defmodule BullX.Config.Gateway.AdapterList do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value), do: BullXGateway.AdapterConfig.cast(value)
end

defmodule BullX.Config.Gateway.KeywordList do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_value), do: :error
end

defmodule BullX.Config.Gateway.PolicyFallback do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value) when value in [:deny, :allow_with_flag], do: {:ok, value}
  def cast("deny"), do: {:ok, :deny}
  def cast("allow_with_flag"), do: {:ok, :allow_with_flag}
  def cast(_value), do: :error
end

defmodule BullX.Config.Gateway do
  @moduledoc """
  Gateway configuration resolved through the BullX configuration boundary.

  Complex boot/static values such as adapter specs and policy module lists are
  read from application config through `BullX.Config.ApplicationBinding`.
  Runtime overrides for scalar values still resolve through the standard
  PostgreSQL -> OS env -> application config -> default chain.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:gateway_adapters,
    key: [:gateway, :adapters],
    type: BullX.Config.Gateway.AdapterList,
    default: []
  )

  @envdoc false
  bullx_env(:gateway_gating,
    key: [:gateway, :gating],
    type: BullX.Config.Gateway.KeywordList,
    default: []
  )

  @envdoc false
  bullx_env(:gateway_moderation,
    key: [:gateway, :moderation],
    type: BullX.Config.Gateway.KeywordList,
    default: []
  )

  @envdoc false
  bullx_env(:gateway_security,
    key: [:gateway, :security],
    type: BullX.Config.Gateway.KeywordList,
    default: []
  )

  @envdoc false
  bullx_env(:gateway_policy_timeout_fallback,
    key: [:gateway, :policy_timeout_fallback],
    type: BullX.Config.Gateway.PolicyFallback,
    default: :deny
  )

  @envdoc false
  bullx_env(:gateway_policy_error_fallback,
    key: [:gateway, :policy_error_fallback],
    type: BullX.Config.Gateway.PolicyFallback,
    default: :deny
  )

  def config do
    [
      adapters: gateway_adapters!(),
      gating: gateway_gating!(),
      moderation: gateway_moderation!(),
      security: gateway_security!(),
      policy_timeout_fallback: gateway_policy_timeout_fallback!(),
      policy_error_fallback: gateway_policy_error_fallback!()
    ]
  end

  def adapters, do: gateway_adapters!()
end
