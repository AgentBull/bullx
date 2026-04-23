defmodule BullX.Config.I18n do
  @moduledoc """
  Runtime configuration for the I18n subsystem.

  Resolves static paths and the application-wide default locale via the
  standard `BullX.Config` precedence chain. The values are consumed by
  `BullX.I18n.Catalog` at boot and whenever `BullX.I18n.reload/0` is called.
  """
  use BullX.Config

  @envdoc false
  bullx_env(:i18n_default_locale,
    type: :binary,
    default: "en-US"
  )

  @envdoc false
  bullx_env(:i18n_locales_dir,
    key: [:i18n, :locales_dir],
    type: :binary,
    default: "priv/locales"
  )
end
