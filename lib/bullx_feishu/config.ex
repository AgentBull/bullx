defmodule BullXFeishu.Config do
  @moduledoc """
  Normalizes Feishu channel configuration at the adapter boundary.

  The Gateway registry stores adapter specs as user-provided maps. This module
  resolves BullX's `{:system, "ENV"}` indirection, applies Feishu defaults, and
  builds the SDK client without logging secrets.
  """

  alias FeishuOpenAPI.Client

  @default_dedupe_ttl_ms :timer.minutes(5)
  @default_message_context_ttl_ms :timer.hours(24) * 30
  @default_card_action_dedupe_ttl_ms :timer.minutes(15)
  @default_inline_media_max_bytes 524_288
  @default_stream_update_interval_ms 100
  @default_state_max_age_seconds 600

  @derive {Inspect, except: [:app_secret, :client]}
  defstruct [
    :channel,
    :channel_id,
    :app_id,
    :app_secret,
    :verification_token,
    :encrypt_key,
    :bot_open_id,
    :bot_user_id,
    :webhook,
    :client,
    domain: :feishu,
    app_type: :self_built,
    connection_mode: :websocket,
    dedupe_ttl_ms: @default_dedupe_ttl_ms,
    message_context_ttl_ms: @default_message_context_ttl_ms,
    card_action_dedupe_ttl_ms: @default_card_action_dedupe_ttl_ms,
    inline_media_max_bytes: @default_inline_media_max_bytes,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    status_reactions: %{enabled: true, in_progress: "Typing", failure: "CrossMark"},
    sso: %{enabled: false, scopes: ["openid", "profile", "email", "phone"]},
    req_options: [],
    headers: [],
    gateway_module: BullXGateway,
    accounts_module: BullXAccounts,
    endpoint: BullXWeb.Endpoint,
    state_max_age_seconds: @default_state_max_age_seconds,
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @spec normalize(BullXGateway.Delivery.channel(), map() | t()) :: {:ok, t()} | {:error, map()}
  def normalize(channel, %__MODULE__{} = config) do
    {:ok, %{config | channel: channel, channel_id: elem(channel, 1)}}
  end

  def normalize({:feishu, channel_id} = channel, config)
      when is_binary(channel_id) and is_map(config) do
    resolved = resolve(config)

    cfg = %__MODULE__{
      channel: channel,
      channel_id: channel_id,
      app_id: present_string(Map.get(resolved, :app_id)),
      app_secret: present_secret(Map.get(resolved, :app_secret)),
      domain: Map.get(resolved, :domain, :feishu),
      app_type: Map.get(resolved, :app_type, :self_built),
      connection_mode: Map.get(resolved, :connection_mode, :websocket),
      verification_token: present_string(Map.get(resolved, :verification_token)),
      encrypt_key: present_string(Map.get(resolved, :encrypt_key)),
      bot_open_id: present_string(Map.get(resolved, :bot_open_id)),
      bot_user_id: present_string(Map.get(resolved, :bot_user_id)),
      dedupe_ttl_ms: non_negative_integer(resolved, :dedupe_ttl_ms, @default_dedupe_ttl_ms),
      message_context_ttl_ms:
        non_negative_integer(resolved, :message_context_ttl_ms, @default_message_context_ttl_ms),
      card_action_dedupe_ttl_ms:
        non_negative_integer(
          resolved,
          :card_action_dedupe_ttl_ms,
          @default_card_action_dedupe_ttl_ms
        ),
      inline_media_max_bytes:
        non_negative_integer(resolved, :inline_media_max_bytes, @default_inline_media_max_bytes),
      stream_update_interval_ms:
        non_negative_integer(
          resolved,
          :stream_update_interval_ms,
          @default_stream_update_interval_ms
        ),
      status_reactions:
        Map.get(resolved, :status_reactions, %{
          enabled: true,
          in_progress: "Typing",
          failure: "CrossMark"
        }),
      sso: normalize_sso(Map.get(resolved, :sso, %{})),
      webhook: normalize_webhook(Map.get(resolved, :webhook)),
      client: Map.get(resolved, :client),
      req_options: Map.get(resolved, :req_options, []),
      headers: Map.get(resolved, :headers, []),
      gateway_module: Map.get(resolved, :gateway_module, BullXGateway),
      accounts_module: Map.get(resolved, :accounts_module, BullXAccounts),
      endpoint: Map.get(resolved, :endpoint, BullXWeb.Endpoint),
      state_max_age_seconds:
        non_negative_integer(resolved, :state_max_age_seconds, @default_state_max_age_seconds),
      start_transport?: Map.get(resolved, :start_transport?, true)
    }

    validate(cfg)
  end

  def normalize(channel, _config), do: {:error, payload_error("invalid Feishu channel", channel)}

  @spec normalize!(BullXGateway.Delivery.channel(), map() | t()) :: t()
  def normalize!(channel, config) do
    case normalize(channel, config) do
      {:ok, cfg} -> cfg
      {:error, error} -> raise ArgumentError, "invalid Feishu config: #{inspect(error)}"
    end
  end

  @spec client!(t()) :: Client.t()
  def client!(%__MODULE__{client: %Client{} = client}), do: client

  def client!(%__MODULE__{} = config) do
    opts =
      [
        domain: config.domain,
        app_type: config.app_type,
        req_options: config.req_options,
        headers: config.headers
      ]
      |> maybe_base_url(config.domain)

    Client.new(config.app_id, config.app_secret, opts)
  end

  @spec verification_opts(t()) :: keyword()
  def verification_opts(%__MODULE__{} = config) do
    [
      verification_token: config.verification_token,
      encrypt_key: config.encrypt_key
    ]
  end

  @spec sso_enabled?(t()) :: boolean()
  def sso_enabled?(%__MODULE__{sso: %{enabled: enabled}}), do: enabled == true

  @spec redacted(t() | map()) :: map()
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:app_secret, :client])
    |> Map.update(:verification_token, nil, &redact_secret/1)
    |> Map.update(:encrypt_key, nil, &redact_secret/1)
  end

  def redacted(config) when is_map(config), do: config |> resolve() |> Map.drop([:app_secret])

  defp validate(%__MODULE__{app_id: nil, client: nil}) do
    {:error, payload_error("Feishu app_id is required", "app_id")}
  end

  defp validate(%__MODULE__{app_secret: nil, client: nil}) do
    {:error, payload_error("Feishu app_secret is required", "app_secret")}
  end

  defp validate(%__MODULE__{domain: domain})
       when domain not in [:feishu, :lark] and not is_binary(domain) do
    {:error,
     payload_error("Feishu domain must be :feishu, :lark, or a base URL", inspect(domain))}
  end

  defp validate(%__MODULE__{app_type: app_type})
       when app_type not in [:self_built, :marketplace] do
    {:error, payload_error("Feishu app_type is invalid", inspect(app_type))}
  end

  defp validate(%__MODULE__{connection_mode: mode}) when mode not in [:websocket, :webhook] do
    {:error, payload_error("Feishu connection_mode is invalid", inspect(mode))}
  end

  defp validate(%__MODULE__{} = config), do: {:ok, config}

  defp normalize_sso(nil), do: %{enabled: false, scopes: ["openid", "profile", "email", "phone"]}

  defp normalize_sso(sso) when is_map(sso) do
    sso = resolve(sso)

    %{
      enabled: Map.get(sso, :enabled, false),
      redirect_uri: present_string(Map.get(sso, :redirect_uri)),
      scopes: Map.get(sso, :scopes, ["openid", "profile", "email", "phone"]),
      login_url: present_string(Map.get(sso, :login_url))
    }
  end

  defp normalize_sso(_), do: %{enabled: false, scopes: ["openid", "profile", "email", "phone"]}

  defp normalize_webhook(nil), do: nil

  defp normalize_webhook(webhook) when is_map(webhook) do
    webhook = resolve(webhook)

    %{
      scheme: Map.get(webhook, :scheme, :http),
      host: Map.get(webhook, :host, "127.0.0.1"),
      port: Map.get(webhook, :port, 4_005),
      event_path: Map.get(webhook, :event_path, "/webhooks/feishu/event"),
      card_action_path: Map.get(webhook, :card_action_path, "/webhooks/feishu/card_action"),
      max_body_length: Map.get(webhook, :max_body_length, 1_048_576)
    }
  end

  defp normalize_webhook(_), do: nil

  defp resolve(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, resolve_value(value)} end)
  end

  defp resolve_value({:system, name}) when is_binary(name), do: System.get_env(name)

  defp resolve_value({:system, name, default}) when is_binary(name) do
    System.get_env(name) || default
  end

  defp resolve_value(%_{} = struct), do: struct
  defp resolve_value(map) when is_map(map), do: resolve(map)
  defp resolve_value(list) when is_list(list), do: Enum.map(list, &resolve_value/1)
  defp resolve_value(value), do: value

  defp present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(value), do: value

  defp present_secret(fun) when is_function(fun, 0), do: fun
  defp present_secret(value), do: present_string(value)

  defp non_negative_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp maybe_base_url(opts, domain) when is_binary(domain),
    do: Keyword.put(opts, :base_url, domain)

  defp maybe_base_url(opts, _domain), do: opts

  defp redact_secret(nil), do: nil
  defp redact_secret(_), do: "[REDACTED]"

  defp payload_error(message, field) do
    %{"kind" => "payload", "message" => message, "details" => %{"field" => field}}
  end
end
