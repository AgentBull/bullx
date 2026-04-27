defmodule BullXWeb.Rsbuild do
  @moduledoc """
  Minimal Rsbuild integration for BullX's Phoenix root layout.

  Development requests are served by the Rsbuild dev server. Production
  requests are resolved from Rsbuild's manifest under
  `priv/static/assets/.rsbuild/manifest.json`.
  """

  use Phoenix.Component

  alias BullXWeb.Rsbuild.Manifest

  @asset_prefix "/assets"
  @default_manifest {:bullx, "priv/static/assets/.rsbuild/manifest.json"}
  @default_entries ["app"]
  @default_dev_files ["css/app.css", "js/app.js"]

  @doc false
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    opts = Keyword.merge([into: IO.stream(:stdio, :line), stderr_to_stdout: true], opts)

    case System.cmd("bun", args, opts) do
      {_, 0} ->
        :ok

      {_, status} ->
        Process.sleep(2000)
        exit({:rsbuild_command_failed, status})
    end
  end

  @doc false
  def has_rsbuild_watcher?(endpoint) when is_atom(endpoint) do
    endpoint
    |> endpoint_watchers()
    |> Keyword.has_key?(:rsbuild)
  end

  attr :entries, :list, default: @default_entries
  attr :dev_files, :list, default: @default_dev_files
  attr :manifest, :any, default: @default_manifest
  attr :endpoint, :atom, default: BullXWeb.Endpoint
  attr :dev_server, :any, default: nil
  attr :crossorigin, :any, default: false

  def assets(assigns) do
    assigns =
      assign(assigns, :dev_server, dev_server?(assigns.dev_server, assigns.endpoint))

    case assigns.dev_server do
      true -> assets_from_dev_server(assigns)
      false -> assets_from_manifest(assigns)
    end
  end

  attr :dev_files, :list, required: true
  attr :entries, :list, required: true
  attr :manifest, :any, required: true
  attr :endpoint, :atom, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_dev_server(%{manifest: manifest} = assigns) do
    assigns = assign(assigns, :dev_origin, dev_origin(assigns.endpoint))

    case manifest_exists?(manifest) do
      true ->
        assigns = assign(assigns, :manifest, parsed_manifest(manifest, false))

        ~H"""
        <.assets_from_dev_manifest_for_entry
          :for={entry <- @entries}
          entry={entry}
          manifest={@manifest}
          dev_origin={@dev_origin}
          crossorigin={@crossorigin}
        />
        """

      false ->
        ~H"""
        <.reference_for_dev_file
          :for={file <- @dev_files}
          file={file}
          dev_origin={@dev_origin}
          crossorigin={@crossorigin}
        />
        """
    end
  end

  attr :entries, :list, required: true
  attr :manifest, :any, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_manifest(%{manifest: manifest} = assigns) do
    case manifest_exists?(manifest) do
      true ->
        assigns = assign(assigns, :manifest, parsed_manifest(manifest, true))

        ~H"""
        <.assets_from_manifest_for_entry
          :for={entry <- @entries}
          entry={entry}
          manifest={@manifest}
          crossorigin={@crossorigin}
        />
        """

      false ->
        case manifest_required?() do
          true -> raise "Rsbuild manifest not found: #{inspect(manifest)}"
          false -> assets_without_manifest(assigns)
        end
    end
  end

  attr :entry, :string, required: true
  attr :manifest, :map, required: true
  attr :dev_origin, :string, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_dev_manifest_for_entry(%{manifest: manifest, entry: entry} = assigns) do
    entry = Path.relative(entry)

    assigns =
      assign(assigns,
        entry: Map.fetch!(manifest, entry)
      )

    ~H"""
    <.reference_for_dev_file
      :for={css <- @entry.initial_css}
      file={css}
      dev_origin={@dev_origin}
      crossorigin={@crossorigin}
    />
    <.reference_for_dev_file
      :for={js <- @entry.initial_js}
      file={js}
      dev_origin={@dev_origin}
      crossorigin={@crossorigin}
    />
    """
  end

  attr :entry, :string, required: true
  attr :manifest, :map, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_manifest_for_entry(%{manifest: manifest, entry: entry} = assigns) do
    entry = Path.relative(entry)

    assigns =
      assign(assigns,
        entry: Map.fetch!(manifest, entry)
      )

    ~H"""
    <.reference_for_static_file
      :for={css <- @entry.initial_css}
      file={css}
      crossorigin={@crossorigin}
    />
    <.reference_for_static_file :for={js <- @entry.initial_js} file={js} crossorigin={@crossorigin} />
    """
  end

  attr :dev_files, :list, required: true
  attr :crossorigin, :any, default: false

  defp assets_without_manifest(assigns) do
    ~H"""
    <.reference_for_static_file
      :for={file <- @dev_files}
      file={file}
      crossorigin={@crossorigin}
      cache={false}
    />
    """
  end

  attr :file, :string, required: true
  attr :dev_origin, :string, required: true
  attr :crossorigin, :any, default: false
  attr :rest, :global

  defp reference_for_dev_file(assigns) do
    ~H"""
    <script
      :if={script_file?(@file)}
      phx-track-static
      type="module"
      crossorigin={@crossorigin}
      src={dev_server_url(@dev_origin, @file)}
      {@rest}
    >
    </script>
    <link
      :if={css_file?(@file)}
      phx-track-static
      rel="stylesheet"
      crossorigin={@crossorigin}
      href={dev_server_url(@dev_origin, @file)}
      {@rest}
    />
    """
  end

  attr :file, :string, required: true
  attr :cache, :boolean, default: true
  attr :crossorigin, :any, default: false
  attr :rest, :global

  defp reference_for_static_file(assigns) do
    ~H"""
    <script
      :if={script_file?(@file)}
      phx-track-static
      type="module"
      crossorigin={@crossorigin}
      src={static_asset_path(@file, @cache)}
      {@rest}
    >
    </script>
    <link
      :if={css_file?(@file)}
      phx-track-static
      rel="stylesheet"
      crossorigin={@crossorigin}
      href={static_asset_path(@file, @cache)}
      {@rest}
    />
    """
  end

  defp endpoint_watchers(endpoint) do
    endpoint.config(:watchers, [])
  end

  defp dev_server?(nil, endpoint), do: has_rsbuild_watcher?(endpoint)
  defp dev_server?(enabled?, _endpoint), do: enabled?

  defp dev_origin(endpoint) do
    endpoint
    |> apply(:static_url, [])
    |> String.trim_trailing("/")
  end

  defp dev_server_url(origin, path) do
    case URI.parse(path) do
      %URI{scheme: scheme} when is_binary(scheme) -> path
      %URI{scheme: nil, host: host} when is_binary(host) -> path
      _ -> origin <> "/" <> String.trim_leading(path, "/")
    end
  end

  defp static_asset_path(file, cache) do
    @asset_prefix
    |> Path.join(file)
    |> maybe_append_cache_query(cache)
  end

  defp maybe_append_cache_query(path, true) do
    path
    |> URI.parse()
    |> URI.append_query("vsn=d")
    |> URI.to_string()
  end

  defp maybe_append_cache_query(path, false), do: path

  defp script_file?(file) do
    Path.extname(file) in [".js", ".mjs", ".ts", ".jsx", ".tsx"]
  end

  defp css_file?(file) do
    Path.extname(file) == ".css"
  end

  defp parsed_manifest(%{} = manifest, _cache?), do: manifest
  defp parsed_manifest(manifest, false), do: Manifest.parse(manifest)
  defp parsed_manifest(manifest, true), do: cached_manifest(manifest)

  defp cached_manifest(manifest) do
    key = {__MODULE__, manifest}

    case :persistent_term.get(key, nil) do
      nil ->
        parsed_manifest = Manifest.parse(manifest)
        :persistent_term.put(key, parsed_manifest)
        parsed_manifest

      parsed_manifest ->
        parsed_manifest
    end
  end

  defp manifest_exists?({app, path}) when is_atom(app) and is_binary(path) do
    app
    |> Application.app_dir(path)
    |> File.exists?()
  end

  defp manifest_exists?(%{}), do: true
  defp manifest_exists?(_manifest), do: false

  defp manifest_required? do
    :bullx
    |> Application.get_env(:rsbuild, [])
    |> Keyword.get(:manifest_required?, false)
  end
end
