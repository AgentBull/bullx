defmodule BullXGateway.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias BullXGateway.RetryPolicy

  test "retryable failures are allowed through max_attempts attempts" do
    policy = RetryPolicy.build(max_attempts: 3)
    error = %{"kind" => "network", "message" => "temporary"}

    assert RetryPolicy.classify(policy, error, 1) == :retry
    assert RetryPolicy.classify(policy, error, 2) == :retry
    assert RetryPolicy.classify(policy, error, 3) == :terminal
  end
end
