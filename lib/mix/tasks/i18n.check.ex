defmodule Mix.Tasks.I18n.Check do
  @shortdoc "Validate BullX I18n TOML catalogs"
  @moduledoc """
  Offline sanity check for BullX's translation catalogs.

  Confirms that:

    * Every locale under `priv/locales/*.toml` parses as TOML and
      normalises through `BullX.I18n.Normalizer` without errors.
    * Every locale under `priv/locales/client/*.toml` is validated
      with the same parser and normaliser when the client catalog
      directory exists.
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
        strict: [client_dir: :string, dir: :string]
      )

    dir = Keyword.get(opts, :dir, "priv/locales")
    client_dir = Keyword.get(opts, :client_dir, Path.join(dir, "client"))
    require_client_dir? = Keyword.has_key?(opts, :client_dir) or File.dir?(client_dir)

    server = validate_catalog!("server", dir, required?: true)
    client = validate_catalog!("client", client_dir, required?: require_client_dir?)
    drift = server.drift ++ client.drift

    case drift do
      [] ->
        Mix.shell().info(ok_message(server, client))

      errors ->
        Mix.shell().error("i18n.check failed:")
        Enum.each(errors, &Mix.shell().error("  - " <> &1))
        die("#{length(errors)} drift issue(s)")
    end
  end

  defp validate_catalog!(label, dir, opts) do
    required? = Keyword.fetch!(opts, :required?)
    locales = load_locales!(label, dir)

    cond do
      locales == %{} and required? ->
        die("no #{label} locale files found in #{dir}")

      locales == %{} ->
        %{label: label, dir: dir, locales: locales, source_count: 0, drift: []}

      not Map.has_key?(locales, @source_locale) ->
        die("#{label} source locale #{inspect(@source_locale)} not found in #{dir}")

      true ->
        drift = catalog_drift(label, locales)

        %{
          label: label,
          dir: dir,
          locales: locales,
          source_count:
            locales |> Map.fetch!(@source_locale) |> Map.fetch!(:messages) |> map_size(),
          drift: drift
        }
    end
  end

  defp load_locales!(label, dir) do
    Loader.load_all(dir)
  rescue
    exception ->
      die("#{label} catalog in #{dir}: #{Exception.message(exception)}")
  end

  defp catalog_drift(label, locales) do
    source_keys = locales |> Map.fetch!(@source_locale) |> Map.fetch!(:messages) |> Map.keys()
    source_set = Map.new(source_keys, &{&1, true})

    source_vars =
      for {key, message} <- locales[@source_locale].messages, into: %{} do
        {key, mf2_variables(message)}
      end

    locales
    |> Enum.reject(fn {locale, _} -> locale == @source_locale end)
    |> Enum.flat_map(fn {locale, %{messages: messages}} ->
      keys = Map.new(messages, fn {k, _} -> {k, true} end)
      extra = Map.drop(keys, Map.keys(source_set))

      extra_errors =
        for key <- extra |> Map.keys() |> Enum.sort() do
          "#{label}: #{locale}: key #{inspect(key)} not present in source locale #{inspect(@source_locale)}"
        end

      var_errors =
        for {key, message} <- messages,
            Map.has_key?(source_set, key),
            mismatch = variable_mismatch(source_vars, key, message),
            mismatch != nil do
          "#{label}: #{locale}: key #{inspect(key)} — #{mismatch}"
        end

      extra_errors ++ var_errors
    end)
  end

  defp ok_message(server, %{locales: locales}) when locales == %{} do
    "i18n.check: #{summary(server)} — OK"
  end

  defp ok_message(server, client) do
    "i18n.check: #{summary(server)}; #{summary(client)} — OK"
  end

  defp summary(%{label: label, locales: locales, source_count: source_count}) do
    "#{label} #{map_size(locales)} locale(s), #{source_count} source key(s)"
  end

  defp variable_mismatch(source_vars, key, translation) do
    source = Map.get(source_vars, key, %{})
    actual = mf2_variables(translation)
    missing = Map.drop(source, Map.keys(actual))
    extra = Map.drop(actual, Map.keys(source))

    case {map_size(missing), map_size(extra)} do
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
    if map_size(set) == 0 do
      acc
    else
      acc ++ [label <> (set |> Map.keys() |> Enum.sort() |> Enum.join(", "))]
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
    {variables, locals} = collect_variables(ast, %{}, %{})
    Map.drop(variables, Map.keys(locals))
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
    {variables, Map.put(locals, name, true)}
  end

  defp collect_variables({:input, expression}, variables, locals) do
    collect_variables(expression, variables, locals)
  end

  defp collect_variables({:match, selectors, variants}, variables, locals) do
    variables =
      Enum.reduce(selectors, variables, fn
        {:variable, name}, vars -> Map.put(vars, name, true)
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

  defp collect_operand_variables(variables, {:variable, name}), do: Map.put(variables, name, true)
  defp collect_operand_variables(variables, _operand), do: variables

  defp collect_function_variables(variables, {:function, _name, options}) do
    collect_option_variables(variables, options)
  end

  defp collect_function_variables(variables, _function), do: variables

  defp collect_option_variables(variables, options) do
    Enum.reduce(options, variables, fn
      {:option, _key, {:variable, name}}, vars -> Map.put(vars, name, true)
      _other, vars -> vars
    end)
  end

  defp collect_attributes_variables(variables, attributes) do
    Enum.reduce(attributes, variables, fn
      {:attribute, _key, {:variable, name}}, vars -> Map.put(vars, name, true)
      _other, vars -> vars
    end)
  end

  defp die(reason) do
    Mix.shell().error("i18n.check: " <> reason)
    exit({:shutdown, 1})
  end
end
