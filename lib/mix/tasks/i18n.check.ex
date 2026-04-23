defmodule Mix.Tasks.I18n.Check do
  @shortdoc "Validate BullX I18n TOML catalogs"
  @moduledoc """
  Offline sanity check for BullX's translation catalogs.

  Confirms that:

    * Every locale under `priv/locales/*.toml` parses as TOML and
      normalises through `BullX.I18n.Normalizer` without errors.
    * The source locale (`en-US`) exists.
    * Every non-source locale's key set is a subset of the source
      locale's key set.
    * Every translated value has the same set of MF2 input
      variables as the source message.

  Exits 0 on success, 1 on any drift.
  """
  use Mix.Task

  alias BullX.I18n.Loader

  @source_locale :"en-US"

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [dir: :string]
      )

    dir = Keyword.get(opts, :dir, "priv/locales")

    locales =
      try do
        Loader.load_all(dir)
      rescue
        exception ->
          die(Exception.message(exception))
      end

    if locales == %{} do
      die("no locale files found in #{dir}")
    end

    unless Map.has_key?(locales, @source_locale) do
      die("source locale #{inspect(@source_locale)} not found in #{dir}")
    end

    source_keys = locales |> Map.fetch!(@source_locale) |> Map.fetch!(:messages) |> Map.keys()
    source_set = MapSet.new(source_keys)

    source_vars =
      for {key, message} <- locales[@source_locale].messages, into: %{} do
        {key, mf2_variables(message)}
      end

    drift =
      locales
      |> Enum.reject(fn {locale, _} -> locale == @source_locale end)
      |> Enum.flat_map(fn {locale, %{messages: messages}} ->
        keys = messages |> Map.keys() |> MapSet.new()
        extra = MapSet.difference(keys, source_set)

        extra_errors =
          for key <- Enum.sort(extra) do
            "#{locale}: key #{inspect(key)} not present in source locale #{inspect(@source_locale)}"
          end

        var_errors =
          for {key, message} <- messages,
              MapSet.member?(source_set, key),
              mismatch = variable_mismatch(source_vars, key, message),
              mismatch != nil do
            "#{locale}: key #{inspect(key)} — #{mismatch}"
          end

        extra_errors ++ var_errors
      end)

    case drift do
      [] ->
        Mix.shell().info(
          "i18n.check: #{map_size(locales)} locale(s), #{MapSet.size(source_set)} source key(s) — OK"
        )

      errors ->
        Mix.shell().error("i18n.check failed:")
        Enum.each(errors, &Mix.shell().error("  - " <> &1))
        die("#{length(errors)} drift issue(s)")
    end
  end

  defp variable_mismatch(source_vars, key, translation) do
    source = Map.get(source_vars, key, MapSet.new())
    actual = mf2_variables(translation)
    missing = MapSet.difference(source, actual)
    extra = MapSet.difference(actual, source)

    case {MapSet.size(missing), MapSet.size(extra)} do
      {0, 0} ->
        nil

      _ ->
        parts =
          []
          |> maybe_append(missing, "missing variables: ")
          |> maybe_append(extra, "unexpected variables: ")

        Enum.join(parts, "; ")
    end
  end

  defp maybe_append(acc, set, label) do
    if MapSet.size(set) == 0 do
      acc
    else
      acc ++ [label <> (set |> MapSet.to_list() |> Enum.sort() |> Enum.join(", "))]
    end
  end

  defp mf2_variables(message) do
    case Localize.Message.Parser.parse(message) do
      {:ok, ast} ->
        required_variables(ast)

      {:error, reason} ->
        raise Localize.ParseError, input: message, reason: reason
    end
  end

  defp required_variables(ast) do
    {variables, locals} = collect_variables(ast, MapSet.new(), MapSet.new())
    MapSet.difference(variables, locals)
  end

  defp collect_variables(list, variables, locals) when is_list(list) do
    Enum.reduce(list, {variables, locals}, fn element, {vars, lcls} ->
      collect_variables(element, vars, lcls)
    end)
  end

  defp collect_variables({:complex, declarations, body}, variables, locals) do
    {variables, locals} = collect_variables(declarations, variables, locals)
    collect_variables(body, variables, locals)
  end

  defp collect_variables({:local, {:variable, name}, expression}, variables, locals) do
    {variables, locals} = collect_variables(expression, variables, locals)
    {variables, MapSet.put(locals, name)}
  end

  defp collect_variables({:input, expression}, variables, locals) do
    collect_variables(expression, variables, locals)
  end

  defp collect_variables({:match, selectors, variants}, variables, locals) do
    variables =
      Enum.reduce(selectors, variables, fn
        {:variable, name}, vars -> MapSet.put(vars, name)
        _other, vars -> vars
      end)

    collect_variables(variants, variables, locals)
  end

  defp collect_variables({:variant, _keys, pattern}, variables, locals) do
    collect_variables(pattern, variables, locals)
  end

  defp collect_variables({:quoted_pattern, parts}, variables, locals) do
    collect_variables(parts, variables, locals)
  end

  defp collect_variables({:expression, operand, function, attributes}, variables, locals) do
    variables
    |> collect_operand_variables(operand)
    |> collect_function_variables(function)
    |> collect_attributes_variables(attributes)
    |> then(&{&1, locals})
  end

  defp collect_variables({:markup_open, _name, options, attributes}, variables, locals) do
    collect_options_and_attributes(options, attributes, variables, locals)
  end

  defp collect_variables({:markup_standalone, _name, options, attributes}, variables, locals) do
    collect_options_and_attributes(options, attributes, variables, locals)
  end

  defp collect_variables({:markup_close, _name, options, attributes}, variables, locals) do
    collect_options_and_attributes(options, attributes, variables, locals)
  end

  defp collect_variables({:text, _}, variables, locals), do: {variables, locals}
  defp collect_variables(_, variables, locals), do: {variables, locals}

  defp collect_options_and_attributes(options, attributes, variables, locals) do
    variables =
      variables
      |> collect_option_variables(options)
      |> collect_attributes_variables(attributes)

    {variables, locals}
  end

  defp collect_operand_variables(variables, {:variable, name}), do: MapSet.put(variables, name)
  defp collect_operand_variables(variables, _operand), do: variables

  defp collect_function_variables(variables, {:function, _name, options}) do
    collect_option_variables(variables, options)
  end

  defp collect_function_variables(variables, _function), do: variables

  defp collect_option_variables(variables, options) do
    Enum.reduce(options, variables, fn
      {:option, _key, {:variable, name}}, vars -> MapSet.put(vars, name)
      _other, vars -> vars
    end)
  end

  defp collect_attributes_variables(variables, attributes) do
    Enum.reduce(attributes, variables, fn
      {:attribute, _key, {:variable, name}}, vars -> MapSet.put(vars, name)
      _other, vars -> vars
    end)
  end

  defp die(reason) do
    Mix.shell().error("i18n.check: " <> reason)
    exit({:shutdown, 1})
  end
end
