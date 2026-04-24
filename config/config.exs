# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

Code.require_file("support/bootstrap.exs", __DIR__)

config :bullx,
  namespace: BullX,
  ecto_repos: [BullX.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :bullx, BullXWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BullXWeb.ErrorHTML, json: BullXWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BullX.PubSub

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :bullx, BullX.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  bullx: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  bullx: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# I18n / Localize bootstrap. `BullX.I18n.Catalog` owns the per-key
# translation dictionaries under `priv/locales/*.toml`; Localize is
# used only for MF2 parsing/formatting and CLDR data. We deliberately
# do NOT pin `:supported_locales` here — Localize's CLDR-backed
# locale resolution stays on its default (all CLDR IDs) so MF2
# formatters can look up number systems, plurals, etc.
config :localize,
  default_locale: :en,
  mf2_functions: %{}

config :bullx, :i18n, locales_dir: "priv/locales"

config :bullx, :accounts,
  authn_match_rules: [],
  authn_auto_create_users: true,
  authn_require_activation_code: true,
  activation_code_ttl_seconds: 86_400,
  web_auth_code_ttl_seconds: 300

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
