defmodule FeishuOpenAPI.TokenStore do
  @moduledoc false
  # Dedicated owner of the `:feishu_openapi_tokens` ETS table. Kept separate from
  # the per-app `TokenManager` so that transient manager restarts do not drop
  # the shared token cache.

  use GenServer

  @table :feishu_openapi_tokens

  @spec table() :: atom()
  def table, do: @table

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    _ =
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      else
        @table
      end

    {:ok, %{}}
  end
end
