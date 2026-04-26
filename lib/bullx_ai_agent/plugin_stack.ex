defmodule BullXAIAgent.PluginStack do
  @moduledoc """
  Centralized default plugin composition for BullXAIAgent agent macros.
  """

  @default_plugins [
    BullXAIAgent.Plugins.TaskSupervisor,
    BullXAIAgent.Plugins.Policy,
    BullXAIAgent.Plugins.ModelRouting
  ]

  @doc """
  Returns the default runtime plugin list for AI agent macros.

  Always includes `TaskSupervisor`, `Policy`, and `ModelRouting`.
  Optional plugins are enabled via `:retrieval` and `:quota` options.
  """
  @spec default_plugins(keyword()) :: [module() | {module(), map()}]
  def default_plugins(opts \\ []) when is_list(opts) do
    @default_plugins
    |> maybe_add_optional(BullXAIAgent.Plugins.Retrieval, Keyword.get(opts, :retrieval, false))
    |> maybe_add_optional(BullXAIAgent.Plugins.Quota, Keyword.get(opts, :quota, false))
  end

  defp maybe_add_optional(plugins, _module, false), do: plugins
  defp maybe_add_optional(plugins, module, true), do: plugins ++ [module]

  defp maybe_add_optional(plugins, module, config) when is_map(config),
    do: plugins ++ [{module, config}]

  defp maybe_add_optional(plugins, module, config) when is_list(config),
    do: plugins ++ [{module, Map.new(config)}]

  defp maybe_add_optional(plugins, _module, _), do: plugins
end
