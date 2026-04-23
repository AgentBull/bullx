defmodule BullX.I18n.Resolver do
  @moduledoc """
  Fallback-chain construction and catalog lookup.

  Reads the persistent-term dictionary populated by
  `BullX.I18n.Catalog` and, for a requested locale, produces an
  ordered deduplicated list of locales to try. The first locale in
  the chain that has a message for the requested key wins.

  The chain order, per RFC 0007 §4.4:

  1. The requested locale.
  2. Same-language parents via BCP 47 truncation (`zh-Hans-CN →
     zh-Hans → zh`).
  3. `__meta__.fallback` from the requested locale's TOML, if any.
  4. Same-language parents of that meta fallback.
  5. The application default locale.
  6. Same-language parents of the default locale.
  7. `:"en-US"` as the final backstop.

  Every step is filtered against the set of loaded locales, so
  nonexistent parents never appear in the chain.
  """

  @messages_prefix {:bullx_i18n, :messages}
  @meta_prefix {:bullx_i18n, :meta}
  @loaded_key {:bullx_i18n, :loaded}
  @chain_cache_key {:bullx_i18n, :chains}
  @default_fallback :"en-US"

  @type catalog_key :: atom()
  @type message :: String.t()

  @spec put_catalog(atom(), %{optional(String.t()) => String.t()}, map()) :: :ok
  def put_catalog(locale, messages, meta) do
    :persistent_term.put({@messages_prefix, locale}, messages)
    :persistent_term.put({@meta_prefix, locale}, meta)
    clear_chain_cache()
    :ok
  end

  @spec drop_catalog(atom()) :: :ok
  def drop_catalog(locale) do
    :persistent_term.erase({@messages_prefix, locale})
    :persistent_term.erase({@meta_prefix, locale})
    clear_chain_cache()
    :ok
  end

  @spec put_loaded([atom()]) :: :ok
  def put_loaded(locales) when is_list(locales) do
    :persistent_term.put(@loaded_key, MapSet.new(locales))
    clear_chain_cache()
    :ok
  end

  @doc false
  @spec clear_chain_cache() :: :ok
  def clear_chain_cache do
    :persistent_term.erase(@chain_cache_key)
    :ok
  end

  @spec loaded() :: MapSet.t(atom())
  def loaded do
    :persistent_term.get(@loaded_key, MapSet.new())
  end

  @spec loaded_list() :: [atom()]
  def loaded_list do
    loaded() |> MapSet.to_list() |> Enum.sort()
  end

  @spec messages(atom()) :: %{String.t() => String.t()} | nil
  def messages(locale) do
    :persistent_term.get({@messages_prefix, locale}, nil)
  end

  @spec meta(atom()) :: map()
  def meta(locale) do
    :persistent_term.get({@meta_prefix, locale}, %{})
  end

  @doc """
  Resolve `key` in `locale`. Returns `{resolved_locale, message}` or
  `nil` if no fallback entry matched.
  """
  @spec lookup(String.t(), atom()) :: {atom(), String.t()} | nil
  def lookup(key, locale) do
    Enum.find_value(fallback_chain(locale), fn candidate ->
      case messages(candidate) do
        nil -> nil
        map -> map |> Map.get(key) |> wrap(candidate)
      end
    end)
  end

  defp wrap(nil, _locale), do: nil
  defp wrap(message, locale), do: {locale, message}

  @doc """
  Build and memoise the fallback chain for `locale`.
  """
  @spec fallback_chain(atom()) :: [atom()]
  def fallback_chain(locale) do
    chains = :persistent_term.get(@chain_cache_key, %{})

    case Map.get(chains, locale) do
      nil ->
        chain = build_chain(locale)
        :persistent_term.put(@chain_cache_key, Map.put(chains, locale, chain))
        chain

      chain ->
        chain
    end
  end

  @doc """
  Resolve a `%Localize.LanguageTag{}` to the catalog locale atom,
  preferring the user-supplied BCP 47 tag, then the CLDR locale ID,
  then the English backstop. Used by `BullX.I18n.t/3` when no
  `:locale` option is provided.
  """
  @spec language_tag_to_locale(Localize.LanguageTag.t()) :: atom()
  def language_tag_to_locale(%Localize.LanguageTag{} = tag) do
    loaded = loaded()

    exact_loaded_locale(tag.requested_locale_id, loaded) ||
      exact_loaded_locale(tag.cldr_locale_id, loaded) ||
      @default_fallback
  end

  defp build_chain(locale) do
    loaded = loaded()
    default = default_locale_atom(loaded)
    default_fallback = @default_fallback

    ([locale] ++
       loaded_parents(locale, loaded) ++
       meta_fallback_chain(locale) ++
       [default] ++
       loaded_parents(default, loaded) ++
       [default_fallback] ++
       loaded_parents(default_fallback, loaded))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(loaded, &1))
  end

  defp meta_fallback_chain(locale) do
    case meta(locale) do
      %{fallback: fallback} when is_binary(fallback) ->
        loaded = loaded()

        case exact_loaded_locale(fallback, loaded) do
          nil -> []
          atom -> [atom | loaded_parents(atom, loaded)]
        end

      _ ->
        []
    end
  end

  defp default_locale_atom(loaded) do
    case Localize.default_locale() do
      %Localize.LanguageTag{} = tag ->
        exact_loaded_locale(tag.requested_locale_id, loaded) ||
          exact_loaded_locale(tag.cldr_locale_id, loaded)

      _ ->
        nil
    end
  end

  defp loaded_parents(locale, loaded) when is_atom(locale) do
    locale
    |> Atom.to_string()
    |> String.split("-")
    |> ancestors()
    |> Enum.map(&exact_loaded_locale(&1, loaded))
    |> Enum.reject(&is_nil/1)
  end

  defp loaded_parents(_locale, _loaded), do: []

  defp exact_loaded_locale(locale, loaded) when is_atom(locale) do
    if MapSet.member?(loaded, locale), do: locale
  end

  defp exact_loaded_locale(locale, loaded) when is_binary(locale) do
    Enum.find(loaded, fn loaded_locale ->
      Atom.to_string(loaded_locale) == locale
    end)
  end

  defp exact_loaded_locale(_locale, _loaded), do: nil

  @doc """
  Same-language parents of `locale` via BCP 47 truncation, most
  specific first.

  `:"zh-Hans-CN"` → `[:"zh-Hans", :zh]`
  `:"en-US"` → `[:en]`
  `:en` → `[]`
  """
  @spec parents(atom()) :: [atom()]
  def parents(locale) when is_atom(locale) do
    locale
    |> Atom.to_string()
    |> String.split("-")
    |> ancestors()
    |> Enum.map(&String.to_atom/1)
  end

  def parents(_), do: []

  defp ancestors([_single]), do: []

  defp ancestors(segments) when is_list(segments) do
    segments
    |> Enum.reverse()
    |> Enum.drop(1)
    |> Enum.reverse()
    |> case do
      [] -> []
      parent -> [Enum.join(parent, "-") | ancestors(parent)]
    end
  end
end
