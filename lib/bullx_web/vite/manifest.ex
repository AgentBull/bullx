defmodule BullXWeb.Vite.Manifest do
  @moduledoc false

  defmodule Chunk do
    @moduledoc false

    defstruct [
      :key,
      :file,
      :src,
      :name,
      is_entry?: false,
      is_dynamic_import?: false,
      assets: [],
      css: [],
      dynamic_imports: [],
      names: [],
      imports: []
    ]
  end

  def parse(%{} = chunks_map) do
    Map.new(chunks_map, fn {key, chunk} ->
      parsed_chunk = %Chunk{
        key: key,
        file: Map.fetch!(chunk, "file"),
        src: Map.get(chunk, "src"),
        name: Map.get(chunk, "name"),
        is_entry?: Map.get(chunk, "isEntry", false),
        is_dynamic_import?: Map.get(chunk, "isDynamicImport", false),
        assets: Map.get(chunk, "assets", []),
        css: Map.get(chunk, "css", []),
        dynamic_imports: Map.get(chunk, "dynamicImports", []),
        names: Map.get(chunk, "names", []),
        imports: Map.get(chunk, "imports", [])
      }

      {key, parsed_chunk}
    end)
  end

  def parse(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> parse()
  end

  def parse({app, path}) when is_atom(app) and is_binary(path) do
    app
    |> Application.app_dir(path)
    |> File.read!()
    |> parse()
  end

  def imported_chunks(%{} = manifest, name) do
    chunk = Map.fetch!(manifest, name)

    {chunks, _seen} =
      Enum.reduce(chunk.imports, {[], MapSet.new()}, fn import_name, {acc_chunks, seen} ->
        {chunks, seen} = imported_chunks(manifest, import_name, seen)

        {acc_chunks ++ chunks, seen}
      end)

    chunks
  end

  defp imported_chunks(manifest, name, seen) do
    chunk = Map.fetch!(manifest, name)

    case MapSet.member?(seen, name) do
      true ->
        {[], seen}

      false ->
        seen = MapSet.put(seen, name)

        {chunks, seen} =
          Enum.reduce(chunk.imports, {[], seen}, fn import_name, {acc_chunks, seen} ->
            {chunks, seen} = imported_chunks(manifest, import_name, seen)

            {acc_chunks ++ chunks, seen}
          end)

        {[chunk | chunks], seen}
    end
  end
end
