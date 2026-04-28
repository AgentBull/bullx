defmodule BullXAccounts.AuthZ.Cedar do
  @moduledoc """
  Elixir wrapper around the Cedar policy NIF in `BullX.Ext`.

  BullX permission grants do not store complete Cedar policies. They store
  the boolean expression that BullX wraps as a Cedar `when` condition after
  applicability has already been decided. The wrapper builds one synthetic
  `permit(principal, action, resource) when { <condition> }` policy and
  calls Cedar through the NIF.

  All NIF and parse failures fail closed for the grant; callers see a
  failed grant, not a process crash.
  """

  alias BullXAccounts.AuthZ.Request

  @principal_type "BullXUser"
  @action_type "BullXAction"
  @resource_type "BullXResource"
  @nif_unavailable_reason "cedar nif unavailable"

  @type loaded_grant :: {String.t(), String.t(), String.t()}
  @type invalid_grant :: {String.t(), String.t()}

  @doc """
  Validate a condition string. Cedar parses the synthetic policy and
  rejects extra policies, `forbid`, `unless`, or templates.
  """
  @spec validate_condition(String.t()) :: :ok | {:error, String.t()}
  def validate_condition(condition) when is_binary(condition) do
    try do
      case BullX.Ext.cedar_condition_validate(condition) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
    end
  end

  def validate_condition(_other), do: {:error, "condition must be a string"}

  @doc """
  Evaluate a condition against a normalized AuthZ request. Returns
  `{:ok, true}`, `{:ok, false}`, or `{:error, reason}`.
  """
  @spec evaluate(String.t(), Request.t()) :: {:ok, boolean()} | {:error, String.t()}
  def evaluate(condition, %Request{} = request) when is_binary(condition) do
    try do
      case BullX.Ext.cedar_condition_eval(condition, cedar_request(request)) do
        result when is_boolean(result) -> {:ok, result}
        {:error, reason} -> {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
    end
  end

  @doc """
  Evaluate already-loaded AuthZ grants against a normalized request.

  The caller keeps persistence concerns in Elixir/Ecto and passes only the
  native boundary data: `{grant_id, resource_pattern, condition}`.
  """
  @spec eval_loaded_grants(Request.t(), [loaded_grant()]) ::
          {:ok, boolean(), [invalid_grant()]} | {:error, String.t()}
  def eval_loaded_grants(%Request{} = request, loaded_grants) when is_list(loaded_grants) do
    try do
      case BullX.Ext.authz_eval_loaded_grants(cedar_request(request), loaded_grants) do
        {:allow, invalid_grants} when is_list(invalid_grants) ->
          {:ok, true, invalid_grants}

        {:deny, invalid_grants} when is_list(invalid_grants) ->
          {:ok, false, invalid_grants}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
    end
  end

  defp cedar_request(%Request{} = request) do
    %{
      "principal" => %{
        "type" => @principal_type,
        "id" => request.user_id,
        "attrs" => %{
          "id" => request.user_id
        }
      },
      "action" => %{
        "type" => @action_type,
        "id" => request.action
      },
      "resource" => %{
        "type" => @resource_type,
        "id" => request.resource
      },
      "context" => %{"request" => request.context}
    }
  end
end
