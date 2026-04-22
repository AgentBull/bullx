defmodule BullXGateway.Security do
  @moduledoc false

  alias BullXGateway.PolicyRunner
  alias BullXGateway.Telemetry

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
          emit_decision(adapter, :allow, nil)
          :ok

        {:ok, {:ok, metadata}} ->
          emit_decision(adapter, :allow, nil)
          {:ok, metadata}

        {:ok, {:deny, reason, description}} ->
          emit_decision(adapter, :deny, reason)
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
          emit_decision(adapter, :allow, nil)
          {:ok, sanitized_delivery}

        {:ok, {:ok, sanitized_delivery, metadata}} ->
          emit_decision(adapter, :allow, nil)
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
    emit_decision(adapter, :allow_with_flag, :timeout_fallback)
    {:ok, %{"reason" => "timeout_fallback", "module" => inspect(adapter)}}
  end

  defp handle_verify_timeout(adapter, _fallback) do
    emit_decision(adapter, :deny, :timeout_fallback)
    {:deny, :timeout_fallback, "#{inspect(adapter)} timed out"}
  end

  defp handle_verify_error(adapter, reason, :allow_with_flag) do
    emit_decision(adapter, :allow_with_flag, :error_fallback)

    {:ok,
     %{"reason" => "error_fallback", "module" => inspect(adapter), "detail" => inspect(reason)}}
  end

  defp handle_verify_error(adapter, reason, _fallback) do
    emit_decision(adapter, :deny, :error_fallback)
    {:deny, :error_fallback, "#{inspect(adapter)} errored: #{inspect(reason)}"}
  end

  defp handle_sanitize_timeout(adapter, :allow_with_flag, delivery) do
    emit_decision(adapter, :allow_with_flag, :timeout_fallback)
    {:ok, delivery, %{"reason" => "timeout_fallback", "module" => inspect(adapter)}}
  end

  defp handle_sanitize_timeout(adapter, _fallback, _delivery) do
    emit_decision(adapter, :deny, :timeout_fallback)
    {:error, {:security_denied, :sanitize, :timeout_fallback, "#{inspect(adapter)} timed out"}}
  end

  defp handle_sanitize_error(adapter, reason, :allow_with_flag, delivery) do
    emit_decision(adapter, :allow_with_flag, :error_fallback)

    {:ok, delivery,
     %{"reason" => "error_fallback", "module" => inspect(adapter), "detail" => inspect(reason)}}
  end

  defp handle_sanitize_error(adapter, reason, _fallback, _delivery) do
    emit_decision(adapter, :deny, :error_fallback)

    {:error,
     {:security_denied, :sanitize, :error_fallback,
      "#{inspect(adapter)} errored: #{inspect(reason)}"}}
  end

  defp emit_decision(module, decision, reason) do
    Telemetry.emit([:bullx, :gateway, :security, :decision], %{count: 1}, %{
      module: module,
      decision: decision,
      reason: reason
    })
  end
end
