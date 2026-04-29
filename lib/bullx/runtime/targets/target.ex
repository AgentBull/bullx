defmodule BullX.Runtime.Targets.Target do
  @moduledoc """
  Persisted Runtime target selected by inbound routing.

  A target is a BullX Runtime abstraction, not a Jido Action or Agent module.
  The `kind` string is resolved through Runtime's code-owned registry before
  execution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @default_soul_md """
  You are BullX Agent, an AI assistant by agentbull.com. You assist users with a wide range of tasks and execute actions via your tools.

  Personality: ENTJ - decisive, strategic, direct.

  Reasoning:
  - Reason from first principles. Treat mainstream consensus as one data point, not the answer.
  - Start without a presupposed position. Deduce and induce from fundamentals, then commit to the highest-probability conclusion as your stance.
  - Bias, when earned through reasoning, is a form of scarce taste.

  Interaction:
  - When the request is ambiguous, ask one targeted clarifying question before acting.
  - For tradeoffs, present the options, give a recommendation with reasoning, and let the user decide.
  - Be targeted and efficient. Match response length to question complexity.
  """

  @type t :: %__MODULE__{}

  schema "runtime_targets" do
    field :kind, :string
    field :name, :string
    field :description, :string
    field :config, :map, default: %{}

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(target, attrs) do
    target
    |> cast(attrs, [:key, :kind, :name, :description, :config])
    |> validate_required([:key, :kind, :name, :config])
    |> validate_format(:key, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,128}$/)
    |> validate_format(:kind, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_config_object()
    |> check_constraint(:kind, name: :runtime_targets_kind_identifier_shape)
    |> check_constraint(:config, name: :runtime_targets_config_json_object)
    |> check_constraint(:key, name: :runtime_targets_main_kind)
  end

  @spec default_main() :: t()
  def default_main do
    %__MODULE__{
      key: "main",
      kind: "agentic_chat_loop",
      name: "Main AI Agent",
      config: %{
        "model" => "default",
        "system_prompt" => %{"soul" => @default_soul_md},
        "agentic_chat_loop" => %{
          "max_iterations" => 4,
          "max_tokens" => 4_096
        }
      }
    }
  end

  @spec default_soul_md() :: String.t()
  def default_soul_md, do: @default_soul_md

  defp validate_config_object(changeset) do
    validate_change(changeset, :config, fn
      :config, config when is_map(config) -> []
      :config, _config -> [config: "must be a JSON object"]
    end)
  end
end
