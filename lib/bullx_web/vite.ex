defmodule BullXWeb.Vite do
  @moduledoc """
  Minimal Vite integration for BullX's Phoenix root layout.

  Development requests are served by the Vite dev server. Production requests
  are resolved from Vite's manifest under `priv/static/assets/.vite/manifest.json`.
  """

  use Phoenix.Component

  alias BullXWeb.Vite.Manifest

  @asset_prefix "/assets"
  @default_manifest {:bullx, "priv/static/assets/.vite/manifest.json"}
  @default_names ["js/app.jsx", "css/app.css"]

  @doc false
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    opts = Keyword.merge([into: IO.stream(:stdio, :line), stderr_to_stdout: true], opts)

    case System.cmd("bun", args, opts) do
      {_, 0} ->
        :ok

      {_, status} ->
        Process.sleep(2000)
        exit({:vite_command_failed, status})
    end
  end

  @doc false
  def has_vite_watcher?(endpoint) when is_atom(endpoint) do
    endpoint
    |> endpoint_watchers()
    |> Keyword.has_key?(:vite)
  end

  attr :names, :list, default: @default_names
  attr :manifest, :any, default: @default_manifest
  attr :endpoint, :atom, default: BullXWeb.Endpoint
  attr :dev_server, :any, default: nil
  attr :crossorigin, :any, default: false
  attr :react_refresh, :boolean, default: true

  def assets(assigns) do
    assigns =
      assign(assigns, :dev_server, dev_server?(assigns.dev_server, assigns.endpoint))

    case assigns.dev_server do
      true -> assets_from_dev_server(assigns)
      false -> assets_from_manifest(assigns)
    end
  end

  attr :names, :list, required: true
  attr :endpoint, :atom, required: true
  attr :crossorigin, :any, default: false
  attr :react_refresh, :boolean, default: true

  defp assets_from_dev_server(assigns) do
    dev_origin = dev_origin(assigns.endpoint)

    assigns =
      assign(assigns,
        dev_origin: dev_origin,
        react_refresh_preamble: react_refresh_preamble(dev_origin)
      )

    ~H"""
    <script :if={@react_refresh} type="module">
      <%= Phoenix.HTML.raw(@react_refresh_preamble) %>
    </script>
    <script
      phx-track-static
      type="module"
      crossorigin={@crossorigin}
      src={dev_server_url(@dev_origin, "/@vite/client")}
    >
    </script>
    <.reference_for_dev_file
      :for={name <- @names}
      file={name}
      dev_origin={@dev_origin}
      crossorigin={@crossorigin}
    />
    """
  end

  attr :names, :list, required: true
  attr :manifest, :any, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_manifest(%{manifest: manifest} = assigns) do
    case manifest_exists?(manifest) do
      true ->
        assigns = assign(assigns, :manifest, cached_manifest(manifest))

        ~H"""
        <.assets_from_manifest_for_name
          :for={name <- @names}
          name={name}
          manifest={@manifest}
          crossorigin={@crossorigin}
        />
        """

      false ->
        case manifest_required?() do
          true -> raise "Vite manifest not found: #{inspect(manifest)}"
          false -> assets_without_manifest(assigns)
        end
    end
  end

  attr :name, :string, required: true
  attr :manifest, :map, required: true
  attr :crossorigin, :any, default: false

  defp assets_from_manifest_for_name(%{manifest: manifest, name: name} = assigns) do
    name = Path.relative(name)

    assigns =
      assign(assigns,
        chunk: Map.fetch!(manifest, name),
        imported_chunks: Manifest.imported_chunks(manifest, name)
      )

    ~H"""
    <.reference_for_static_file :for={css <- @chunk.css} file={css} crossorigin={@crossorigin} />
    <%= for chunk <- @imported_chunks, css <- chunk.css do %>
      <.reference_for_static_file file={css} crossorigin={@crossorigin} />
    <% end %>
    <.reference_for_static_file file={@chunk.file} crossorigin={@crossorigin} />
    <.modulepreload_link
      :for={chunk <- @imported_chunks}
      file={chunk.file}
      crossorigin={@crossorigin}
    />
    """
  end

  attr :names, :list, required: true
  attr :crossorigin, :any, default: false

  defp assets_without_manifest(assigns) do
    ~H"""
    <.reference_for_static_file
      :for={name <- @names}
      file={name}
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

  attr :file, :string, required: true
  attr :crossorigin, :any, default: false

  defp modulepreload_link(assigns) do
    ~H"""
    <link
      phx-track-static
      rel="modulepreload"
      crossorigin={@crossorigin}
      href={static_asset_path(@file, true)}
    />
    """
  end

  defp endpoint_watchers(endpoint) do
    endpoint.config(:watchers, [])
  end

  defp dev_server?(nil, endpoint), do: has_vite_watcher?(endpoint)
  defp dev_server?(enabled?, _endpoint), do: enabled?

  defp dev_origin(endpoint) do
    endpoint
    |> apply(:static_url, [])
    |> String.trim_trailing("/")
  end

  defp dev_server_url(origin, path) do
    origin <> "/" <> String.trim_leading(path, "/")
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
    Path.extname(file) in [".js", ".ts", ".jsx", ".tsx"]
  end

  defp css_file?(file) do
    Path.extname(file) == ".css"
  end

  defp cached_manifest(%{} = manifest), do: manifest

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
    |> Application.get_env(:vite, [])
    |> Keyword.get(:manifest_required?, false)
  end

  defp react_refresh_preamble(origin) do
    """
    import RefreshRuntime from "#{origin}/@react-refresh"
    RefreshRuntime.injectIntoGlobalHook(window)
    window.$RefreshReg$ = () => {}
    window.$RefreshSig$ = () => (type) => type
    window.__vite_plugin_react_preamble_installed__ = true
    """
  end
end
