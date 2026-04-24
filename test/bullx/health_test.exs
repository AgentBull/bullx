defmodule BullX.HealthTest do
  use ExUnit.Case, async: true

  alias BullX.Health

  defmodule MissingRepo do
  end

  test "live/0 does not include dependency checks" do
    assert %{status: "ok", checks: %{beam: %{status: "ok"}}} = Health.live()
  end

  test "ready/1 reports dependency failures" do
    assert {:error, %{status: "error", checks: %{postgres: postgres}}} =
             Health.ready(repo: MissingRepo)

    assert %{status: "error", error: error} = postgres
    assert is_binary(error)
  end
end
