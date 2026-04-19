defmodule BullX.Config.Bootstrap do
  @moduledoc false

  @doc """
  Loads the appropriate `.env*` files for the given Mix environment and merges
  them into the process environment. Existing OS environment variables are not
  overwritten; file-based values only fill gaps.
  """
  def load_dotenv!(opts) do
    root = Keyword.fetch!(opts, :root)
    env = Keyword.fetch!(opts, :env)
    profile = profile_name(env)
    files = dotenv_files(root, profile, env)

    Enum.each(files, &load_env_file/1)
  end

  # Parses a KEY=value file and sets missing env vars.
  # Falls back to Dotenvy when available (supports quoted values, comments, etc.);
  # uses a minimal built-in parser otherwise (covers the plain KEY=value case).
  defp load_env_file(path) do
    case apply(Dotenvy, :source!, [[path], [require_files: false]]) do
      loaded when is_map(loaded) ->
        Enum.each(loaded, fn {k, v} ->
          if is_nil(System.get_env(k)), do: System.put_env(k, v)
        end)
    end
  rescue
    UndefinedFunctionError ->
      case File.read(path) do
        {:ok, content} -> parse_and_set_env(content)
        {:error, _} -> :ok
      end
  end

  defp parse_and_set_env(content) do
    content
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)

      with false <- line == "" or String.starts_with?(line, "#"),
           [key, value] <- String.split(line, "=", parts: 2),
           key = String.trim(key),
           true <- key != "",
           true <- is_nil(System.get_env(key)) do
        System.put_env(key, String.trim(value))
      end
    end)
  end

  @doc "Returns the string value of an OS environment variable, or `default`."
  def env_string(name, default \\ nil), do: System.get_env(name) || default

  @doc "Parses an OS environment variable as an integer, or returns `default`."
  def env_integer(name, default \\ nil) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {n, ""} ->
            n

          _ ->
            raise "BullX.Config.Bootstrap: invalid integer for #{name}: #{inspect(raw)}"
        end
    end
  end

  @doc "Parses an OS environment variable as a boolean, or returns `default`."
  def env_boolean(name, default \\ nil) do
    case System.get_env(name) do
      nil -> default
      raw when raw in ~w(true 1 yes) -> true
      raw when raw in ~w(false 0 no) -> false
      raw -> raise "BullX.Config.Bootstrap: invalid boolean for #{name}: #{inspect(raw)}"
    end
  end

  @doc """
  Reads a required OS environment variable and applies `parser/1`.
  Raises if the variable is absent.
  """
  def env!(name, parser) when is_function(parser, 1) do
    case System.get_env(name) do
      nil ->
        raise "BullX.Config.Bootstrap: required environment variable #{name} is not set"

      raw ->
        parser.(raw)
    end
  end

  @doc "Validates `value` against a Zoi schema supplied via the `zoi:` option. Raises on failure."
  def validate!(value, opts) when is_list(opts) do
    case Keyword.get(opts, :zoi) do
      nil ->
        value

      schema_or_fn ->
        schema = if is_function(schema_or_fn, 0), do: schema_or_fn.(), else: schema_or_fn

        # apply/3 avoids compile-time undefined-module warnings when this file
        # is loaded before Zoi is compiled.
        case apply(Zoi, :parse, [schema, value]) do
          {:ok, _} ->
            value

          {:error, errors} ->
            raise "BullX.Config.Bootstrap: Zoi validation failed for value #{inspect(value)}: #{inspect(errors)}"
        end
    end
  end

  @doc "Maps a Mix config env atom to a BullX dotenv profile name."
  def profile_name(config_env), do: Atom.to_string(config_env)

  defp dotenv_files(root, profile, env) do
    base = [
      Path.join(root, ".env"),
      Path.join(root, ".env.#{profile}")
    ]

    if env == :dev do
      base ++ [Path.join(root, ".env.local")]
    else
      base
    end
  end
end
