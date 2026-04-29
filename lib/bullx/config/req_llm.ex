defmodule BullX.Config.ReqLLM do
  @moduledoc """
  ReqLLM settings owned by `BullX.Config` and bridged into `:req_llm`.

  Only settings that req_llm reads at call time belong here. Application-start
  settings such as `:load_dotenv` and `:custom_providers`, plus provider-specific
  API keys, intentionally stay outside this bridge.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:receive_timeout_ms,
    key: [:req_llm, :receive_timeout_ms],
    type: :integer,
    default: 30_000
  )

  @envdoc false
  bullx_env(:metadata_timeout_ms,
    key: [:req_llm, :metadata_timeout_ms],
    type: :integer,
    default: 300_000
  )

  @envdoc false
  bullx_env(:stream_completion_cleanup_after_ms,
    key: [:req_llm, :stream_completion_cleanup_after_ms],
    type: :integer,
    default: 30_000
  )

  @envdoc false
  bullx_env(:debug,
    key: [:req_llm, :debug],
    type: :boolean,
    default: false
  )

  @envdoc false
  bullx_env(:redact_context,
    key: [:req_llm, :redact_context],
    type: :boolean,
    default: false
  )

  @doc false
  @spec bridge_keyspec() :: [{atom(), (-> term())}]
  def bridge_keyspec do
    [
      {:receive_timeout, &receive_timeout_ms!/0},
      {:metadata_timeout, &metadata_timeout_ms!/0},
      {:stream_completion_cleanup_after, &stream_completion_cleanup_after_ms!/0},
      {:debug, &debug!/0},
      {:redact_context, &redact_context!/0}
    ]
  end
end
