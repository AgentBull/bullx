defmodule BullX.I18n.Catalog do
  @moduledoc """
  Owns the `:persistent_term` catalog for BullX's translation
  dictionaries.

  At boot the Catalog:

    1. Scans `priv/locales/*.toml` via `BullX.I18n.Loader`.
    2. Validates the configured default locale against the scan
       result via `BullX.Config.I18n.i18n_default_locale!/0`.
    3. Calls `Localize.put_supported_locales/1` with the scan
       result and `Localize.put_default_locale/1` with the
       resolved language tag.
    4. Writes each locale's canonical dictionary into
       `:persistent_term` through `BullX.I18n.Resolver.put_catalog/3`.

  In `:dev` it also starts a `FileSystem`-backed watcher as an
  internal child task, so edits under `priv/locales/` hot-reload
  the affected locale (RFC 0007 §9).
  """

  use GenServer
  require Logger

  alias BullX.I18n.{Loader, Resolver}

  @name __MODULE__

  defstruct [:locales_dir, :watcher_pid]

  @type t :: %__MODULE__{
          locales_dir: Path.t(),
          watcher_pid: pid() | nil
        }

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(@name, :reload)

  @spec reload_locales!() :: :ok
  def reload_locales!, do: GenServer.call(@name, :reload_locales)

  @impl true
  def init(opts) do
    locales_dir = Keyword.get(opts, :locales_dir, configured_locales_dir())
    full_path = expand_locales_dir(locales_dir)

    state = %__MODULE__{locales_dir: full_path}

    with :ok <- load_catalog(full_path),
         :ok <- apply_config_default_locale() do
      {:ok, maybe_start_watcher(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    result = apply_config_default_locale()
    {:reply, result, state}
  end

  def handle_call(:reload_locales, _from, state) do
    :ok = load_catalog(state.locales_dir)
    :ok = apply_config_default_locale()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, events}}, state) do
    cond do
      toml?(path) and reload_event?(events) ->
        rescan_locales(path, state.locales_dir)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ── Loading ────────────────────────────────────────────────────

  defp load_catalog(dir) do
    try do
      locales = Loader.load_all(dir)

      if locales == %{} do
        Logger.warning(
          "no locale files found in #{dir}; BullX.I18n will degrade to key literals",
          domain: :i18n
        )
      end

      ids = Map.keys(locales)
      current = Resolver.loaded() |> MapSet.to_list()

      Enum.each(current -- ids, &Resolver.drop_catalog/1)

      :ok = sync_supported_locales(ids)
      :ok = Resolver.put_loaded(ids)

      Enum.each(locales, fn {locale, %{messages: messages, meta: meta}} ->
        Resolver.put_catalog(locale, messages, meta)
      end)

      :ok
    rescue
      exception ->
        {:error, exception}
    end
  end

  defp apply_config_default_locale do
    configured = BullX.Config.I18n.i18n_default_locale!()
    loaded = Resolver.loaded()
    loaded_locale = exact_loaded_locale(configured, loaded)

    if loaded_locale do
      case language_tag_for_loaded_locale(loaded_locale) do
        {:ok, tag} ->
          {:ok, _} = Localize.put_default_locale(tag)
          Resolver.clear_chain_cache()
          :ok

        {:error, exception} ->
          {:error, exception}
      end
    else
      available = loaded |> MapSet.to_list() |> Enum.sort() |> Enum.map(&Atom.to_string/1)

      {:error,
       %ArgumentError{
         message:
           "configured i18n_default_locale #{inspect(configured)} is not available. " <>
             "Available locales: #{inspect(available)}"
       }}
    end
  end

  # ── Dev watcher ────────────────────────────────────────────────

  defp maybe_start_watcher(state) do
    case Mix.env() do
      :dev -> start_watcher(state)
      _ -> state
    end
  rescue
    _ -> state
  end

  defp start_watcher(state) do
    if Code.ensure_loaded?(FileSystem) do
      case apply(FileSystem, :start_link, [[dirs: [state.locales_dir], name: nil]]) do
        {:ok, pid} ->
          apply(FileSystem, :subscribe, [pid])
          %{state | watcher_pid: pid}

        {:error, reason} ->
          Logger.warning("i18n dev watcher failed to start: #{inspect(reason)}",
            domain: :i18n
          )

          state
      end
    else
      state
    end
  end

  defp toml?(path), do: String.ends_with?(path, ".toml")

  defp reload_event?(events) when is_list(events) do
    Enum.any?(events, &(&1 in [:modified, :created, :removed, :renamed]))
  end

  defp reload_event?(_), do: false

  # Any TOML change under priv/locales/ triggers a full rescan:
  # simpler than per-file reconciliation and makes locale sharding
  # (multiple files for one locale) behave correctly.
  defp rescan_locales(triggering_path, dir) do
    try do
      locales = Loader.load_all(dir)
      ids = Map.keys(locales)
      :ok = sync_supported_locales(ids)

      current = Resolver.loaded() |> MapSet.to_list()

      Enum.each(current -- ids, &Resolver.drop_catalog/1)

      Enum.each(locales, fn {locale, %{messages: messages, meta: meta}} ->
        Resolver.put_catalog(locale, messages, meta)
      end)

      :ok = Resolver.put_loaded(ids)

      Logger.info("i18n dev rescan after #{triggering_path}: #{length(ids)} locale(s) loaded",
        domain: :i18n
      )
    rescue
      exception ->
        Logger.error("i18n dev rescan failed: #{Exception.message(exception)}",
          domain: :i18n
        )
    end
  end

  # ── Paths ──────────────────────────────────────────────────────

  defp configured_locales_dir do
    BullX.Config.I18n.i18n_locales_dir!()
  end

  defp expand_locales_dir(dir) do
    case Path.type(dir) do
      :absolute ->
        dir

      _ ->
        app_dir = Application.app_dir(:bullx, dir)
        if File.dir?(app_dir), do: app_dir, else: Path.expand(dir, File.cwd!())
    end
  end

  defp sync_supported_locales(locale_ids) do
    locale_ids
    |> Enum.map(&language_tag_for_loaded_locale!/1)
    |> Enum.map(& &1.cldr_locale_id)
    |> Enum.uniq()
    |> Localize.put_supported_locales()
  end

  defp language_tag_for_loaded_locale(locale) do
    locale
    |> Atom.to_string()
    |> Localize.LanguageTag.new()
    |> case do
      {:ok, %Localize.LanguageTag{cldr_locale_id: id} = tag} when is_atom(id) ->
        {:ok, tag}

      {:ok, _tag} ->
        {:error,
         %ArgumentError{
           message: "locale #{inspect(locale)} did not resolve to a CLDR locale identifier"
         }}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp language_tag_for_loaded_locale!(locale) do
    case language_tag_for_loaded_locale(locale) do
      {:ok, tag} -> tag
      {:error, exception} -> raise exception
    end
  end

  defp exact_loaded_locale(locale, loaded) when is_binary(locale) do
    Enum.find(loaded, fn loaded_locale ->
      Atom.to_string(loaded_locale) == locale
    end)
  end

  defp exact_loaded_locale(_locale, _loaded), do: nil
end
