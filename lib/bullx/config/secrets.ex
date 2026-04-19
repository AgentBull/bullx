defmodule BullX.Config.Secrets do
  use BullX.Config

  @envdoc """
  Root secret used to derive all application keys (Phoenix secret_key_base, LiveView
  signing_salt, etc.). Must be set via `BULLX_SECRET_BASE` environment variable.
  Generate with `mix phx.gen.secret`. No default; absence raises at startup.
  Database configuration is intentionally disallowed for this setting.
  """
  bullx_env(:bullx_secret_base, :secret_base,
    type: :binary,
    required: true,
    binding_order: [BullX.Config.SystemBinding],
    binding_skip: [:system, :config],
    zoi: Zoi.string() |> Zoi.min(64)
  )
end
