defmodule BullXGateway.Security do
  @moduledoc """
  Executes adapter-supplied security hooks around Gateway traffic.

  The `:verify` stage runs before inbound dedupe and policy so adapters can
  apply transport-specific sender checks. The `:sanitize` stage runs on
  outbound deliveries before adapter send, edit, or stream calls. Both stages
  share the same bounded execution and fail-open or fail-closed fallback policy
  used by the rest of Gateway.
  """

  alias BullXGateway.PolicyRunner

  @type stage :: :verify | :sanitize
  @type input ::
          BullXGateway.Inputs.Message.t()
          | BullXGateway.Inputs.MessageEdited.t()
          | BullXGateway.Inputs.MessageRecalled.t()
          | BullXGateway.Inputs.Reaction.t()
          | BullXGateway.Inputs.Action.t()
          | BullXGateway.Inputs.SlashCommand.t()
          | BullXGateway.Inputs.Trigger.t()

  @callback verify_sender(BullXGateway.Delivery.channel(), input(), keyword()) ::
              :ok | {:ok, map()} | {:deny, atom(), String.t()} | {:error, term()}

  @callback sanitize_outbound(
              BullXGateway.Delivery.channel(),
              BullXGateway.Delivery.t(),
              keyword()
            ) ::
              {:ok, BullXGateway.Delivery.t()}
              | {:ok, BullXGateway.Delivery.t(), map()}
              | {:error, term()}

  def verify_sender(channel, input, config, timeout_fallback, error_fallback) do
    case Keyword.get(config, :adapter) do
      nil ->
        :ok

      adapter ->
        verify_sender_with_adapter(
          adapter,
          channel,
          input,
          Keyword.get(config, :adapter_opts, []),
          Keyword.get(config, :verify_timeout_ms, 50),
          timeout_fallback,
          error_fallback
        )
    end
  end

  def sanitize_outbound(channel, delivery, config, timeout_fallback, error_fallback) do
    case Keyword.get(config, :adapter) do
      nil ->
        {:ok, delivery}

      adapter ->
        sanitize_outbound_with_adapter(
          adapter,
          channel,
          delivery,
          Keyword.get(config, :adapter_opts, []),
          Keyword.get(config, :sanitize_timeout_ms, 50),
          timeout_fallback,
          error_fallback
        )
    end
  end

  defp verify_sender_with_adapter(
         adapter,
         channel,
         input,
         adapter_opts,
         timeout_ms,
         timeout_fallback,
         error_fallback
       ) do
    if function_exported?(adapter, :verify_sender, 3) do
      case PolicyRunner.run(
             fn -> adapter.verify_sender(channel, input, adapter_opts) end,
             timeout_ms
           ) do
        {:ok, :ok} ->
          :ok

        {:ok, {:ok, metadata}} ->
          {:ok, metadata}

        {:ok, {:deny, reason, description}} ->
          {:deny, reason, description}

        {:ok, {:error, reason}} ->
          handle_verify_error(adapter, reason, error_fallback)

        {:ok, other} ->
          handle_verify_error(adapter, {:invalid_return, other}, error_fallback)

        {:error, :timeout} ->
          handle_verify_timeout(adapter, timeout_fallback)

        {:error, {:raised, reason}} ->
          handle_verify_error(adapter, reason, error_fallback)
      end
    else
      :ok
    end
  end

  defp sanitize_outbound_with_adapter(
         adapter,
         channel,
         delivery,
         adapter_opts,
         timeout_ms,
         timeout_fallback,
         error_fallback
       ) do
    if function_exported?(adapter, :sanitize_outbound, 3) do
      case PolicyRunner.run(
             fn -> adapter.sanitize_outbound(channel, delivery, adapter_opts) end,
             timeout_ms
           ) do
        {:ok, {:ok, sanitized_delivery}} ->
          {:ok, sanitized_delivery}

        {:ok, {:ok, sanitized_delivery, metadata}} ->
          {:ok, sanitized_delivery, metadata}

        {:ok, {:error, reason}} ->
          handle_sanitize_error(adapter, reason, error_fallback, delivery)

        {:ok, other} ->
          handle_sanitize_error(adapter, {:invalid_return, other}, error_fallback, delivery)

        {:error, :timeout} ->
          handle_sanitize_timeout(adapter, timeout_fallback, delivery)

        {:error, {:raised, reason}} ->
          handle_sanitize_error(adapter, reason, error_fallback, delivery)
      end
    else
      {:ok, delivery}
    end
  end

  defp handle_verify_timeout(adapter, :allow_with_flag) do
    {:ok, %{"reason" => "timeout_fallback", "module" => inspect(adapter)}}
  end

  defp handle_verify_timeout(adapter, _fallback) do
    {:deny, :timeout_fallback, "#{inspect(adapter)} timed out"}
  end

  defp handle_verify_error(adapter, reason, :allow_with_flag) do
    {:ok,
     %{"reason" => "error_fallback", "module" => inspect(adapter), "detail" => inspect(reason)}}
  end

  defp handle_verify_error(adapter, reason, _fallback) do
    {:deny, :error_fallback, "#{inspect(adapter)} errored: #{inspect(reason)}"}
  end

  defp handle_sanitize_timeout(adapter, :allow_with_flag, delivery) do
    {:ok, delivery, %{"reason" => "timeout_fallback", "module" => inspect(adapter)}}
  end

  defp handle_sanitize_timeout(adapter, _fallback, _delivery) do
    {:error, {:security_denied, :sanitize, :timeout_fallback, "#{inspect(adapter)} timed out"}}
  end

  defp handle_sanitize_error(adapter, reason, :allow_with_flag, delivery) do
    {:ok, delivery,
     %{"reason" => "error_fallback", "module" => inspect(adapter), "detail" => inspect(reason)}}
  end

  defp handle_sanitize_error(adapter, reason, _fallback, _delivery) do
    {:error,
     {:security_denied, :sanitize, :error_fallback,
      "#{inspect(adapter)} errored: #{inspect(reason)}"}}
  end
end
