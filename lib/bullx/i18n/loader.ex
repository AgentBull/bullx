defmodule BullX.I18n.Loader do
  @moduledoc """
  Scans `priv/locales/*.toml` and returns a map of locale ID atom
  to normalized `{messages, meta}` maps. One TOML file per locale —
  the filename (minus `.toml`) is the locale atom. Each file's MF2
  sources are validated and canonicalised by `BullX.I18n.Normalizer`.
  """

  alias BullX.I18n.Normalizer

  @type locale_entry :: %{
          messages: %{String.t() => String.t()},
          meta: map()
        }

  @spec load_all(Path.t(), Keyword.t()) :: %{atom() => locale_entry()}
  def load_all(dir, opts \\ []) when is_binary(dir) do
    spec = Keyword.get(opts, :toml_spec, :"1.1.0")

    dir
    |> list_toml_files()
    |> Map.new(fn path -> {locale_id_from_path(path), parse_file(path, spec)} end)
  end

  @spec list_toml_files(Path.t()) :: [Path.t()]
  def list_toml_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @spec locale_id_from_path(Path.t()) :: atom()
  def locale_id_from_path(path) do
    path
    |> Path.basename(".toml")
    |> String.to_atom()
  end

  defp parse_file(path, spec) do
    raw = File.read!(path)

    table =
      case TomlElixir.decode(raw, spec: spec) do
        {:ok, decoded} ->
          decoded

        {:error, exception} ->
          reraise_with_file(exception, path)
      end

    Normalizer.normalize(table, file: path)
  end

  defp reraise_with_file(exception, path) do
    raise BullX.I18n.Normalizer.Error,
      file: path,
      reason: "TOML parse error — #{Exception.message(exception)}"
  end
end
