defmodule Mix.Tasks.PhxMediaLibrary.Stats do
  @moduledoc """
  Displays storage statistics for media files.

  Walks every schema registered with `PhxMediaLibrary.HasMedia` (via
  `PhxMediaLibrary.ModelRegistry.all_models/0`) and aggregates counts and
  sizes from each schema's JSONB media column at the database level using
  PostgreSQL `jsonb_each`/`jsonb_array_elements`.

  ## Usage

      $ mix phx_media_library.stats

  ## Options

      --collection NAME   Filter to a specific collection name
      --type TYPE         Filter to a specific media type (matches the schema's
                          __media_type__/0, e.g. "posts")
      --include-trashed   Accepted for compatibility with the upstream task.
                          The JSONB fork does not implement soft-delete, so
                          this flag has no effect.

  ## Examples

      # Show all stats
      $ mix phx_media_library.stats

      # Filter to a single collection
      $ mix phx_media_library.stats --collection photos

      # Filter to a single model type
      $ mix phx_media_library.stats --type posts

  """

  @shortdoc "Shows storage statistics for media files (JSONB-aware)"

  use Mix.Task

  alias PhxMediaLibrary.{Config, ModelRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          include_trashed: :boolean,
          collection: :string,
          type: :string
        ]
      )

    Mix.Task.run("app.start")

    repo = Config.repo()
    collection_filter = opts[:collection]
    type_filter = opts[:type]

    Mix.shell().info("")

    Mix.shell().info(
      "#{IO.ANSI.cyan()}#{IO.ANSI.bright()}PhxMediaLibrary Storage Stats#{IO.ANSI.reset()}"
    )

    Mix.shell().info("==============================")
    Mix.shell().info("")

    models = filter_models(ModelRegistry.all_models(), type_filter)

    {collection_rows, disk_rows} = aggregate(repo, models, collection_filter)

    print_collection_table(collection_rows)
    print_disk_table(disk_rows)
  end

  # ---------------------------------------------------------------------------
  # Aggregation
  # ---------------------------------------------------------------------------

  defp filter_models(models, nil), do: models

  defp filter_models(models, type) do
    Enum.filter(models, fn module ->
      module.__media_type__() == type
    end)
  end

  defp aggregate(repo, models, collection_filter) do
    Enum.reduce(models, {[], %{}}, fn module, {coll_acc, disk_acc} ->
      type = module.__media_type__()
      table = module.__schema__(:source)
      column = module.__media_column__()

      coll_rows = fetch_collection_stats(repo, type, table, column, collection_filter)
      disk_acc = merge_disk_stats(disk_acc, fetch_disk_stats(repo, table, column, collection_filter))

      {coll_acc ++ coll_rows, disk_acc}
    end)
    |> then(fn {coll, disk_map} ->
      sorted_disk =
        disk_map
        |> Enum.map(fn {disk, {count, total_size}} ->
          %{disk: disk, count: count, total_size: total_size}
        end)
        |> Enum.sort_by(& &1.disk)

      {coll, sorted_disk}
    end)
  end

  defp fetch_collection_stats(repo, type, table, column, collection_filter) do
    {filter_sql, params} =
      case collection_filter do
        nil -> {"", []}
        name -> {"WHERE j.key = $1", [name]}
      end

    sql = """
    SELECT j.key AS collection_name,
           count(*) AS count,
           coalesce(sum((item->>'size')::bigint), 0) AS total_size,
           coalesce(avg((item->>'size')::bigint), 0) AS avg_size
    FROM "#{table}",
         jsonb_each("#{column}") AS j(key, value),
         jsonb_array_elements(value) AS item
    #{filter_sql}
    GROUP BY j.key
    ORDER BY j.key
    """

    case Ecto.Adapters.SQL.query!(repo, sql, params).rows do
      rows ->
        Enum.map(rows, fn [collection, count, total_size, avg_size] ->
          %{
            mediable_type: type,
            collection_name: collection,
            count: count,
            total_size: total_size,
            avg_size: avg_size
          }
        end)
    end
  end

  defp fetch_disk_stats(repo, table, column, collection_filter) do
    {filter_sql, params} =
      case collection_filter do
        nil -> {"", []}
        name -> {"WHERE j.key = $1", [name]}
      end

    sql = """
    SELECT coalesce(item->>'disk', '(unknown)') AS disk,
           count(*) AS count,
           coalesce(sum((item->>'size')::bigint), 0) AS total_size
    FROM "#{table}",
         jsonb_each("#{column}") AS j(key, value),
         jsonb_array_elements(value) AS item
    #{filter_sql}
    GROUP BY 1
    """

    Ecto.Adapters.SQL.query!(repo, sql, params).rows
  end

  defp merge_disk_stats(acc, rows) do
    Enum.reduce(rows, acc, fn [disk, count, total_size], map ->
      Map.update(map, disk, {count, total_size}, fn {c, s} ->
        {c + count, s + total_size}
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Table printers
  # ---------------------------------------------------------------------------

  defp print_collection_table([]) do
    Mix.shell().info("#{IO.ANSI.yellow()}No media records found.#{IO.ANSI.reset()}")
    Mix.shell().info("")
  end

  defp print_collection_table(rows) do
    Mix.shell().info("#{IO.ANSI.cyan()}By Collection:#{IO.ANSI.reset()}")

    header =
      "  " <>
        lpad("media_type", 18) <>
        "  " <>
        lpad("collection", 14) <>
        "  " <>
        rpad("count", 7) <>
        "  " <>
        rpad("total_size", 12) <>
        "  " <>
        rpad("avg_size", 10)

    sep = "  " <> String.duplicate("─", String.length(header) - 2)

    Mix.shell().info(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    Mix.shell().info(sep)

    Enum.each(rows, fn row ->
      total = to_bytes(row.total_size)
      avg = to_bytes(row.avg_size)

      line =
        "  " <>
          lpad(row.mediable_type, 18) <>
          "  " <>
          lpad(row.collection_name, 14) <>
          "  " <>
          rpad(to_string(row.count), 7) <>
          "  " <>
          rpad(format_size(total), 12) <>
          "  " <>
          rpad(format_size(avg), 10)

      Mix.shell().info(line)
    end)

    Mix.shell().info(sep)

    total_count = Enum.sum(Enum.map(rows, & &1.count))
    total_size = rows |> Enum.map(&to_bytes(&1.total_size)) |> Enum.sum()
    total_avg = if total_count > 0, do: div(total_size, total_count), else: 0

    total_line =
      IO.ANSI.bright() <>
        "  " <>
        lpad("TOTAL", 18) <>
        "  " <>
        lpad("", 14) <>
        "  " <>
        rpad(to_string(total_count), 7) <>
        "  " <>
        rpad(format_size(total_size), 12) <>
        "  " <>
        rpad(format_size(total_avg), 10) <>
        IO.ANSI.reset()

    Mix.shell().info(total_line)
    Mix.shell().info("")
  end

  defp print_disk_table([]) do
    Mix.shell().info("#{IO.ANSI.yellow()}No disk records found.#{IO.ANSI.reset()}")
    Mix.shell().info("")
  end

  defp print_disk_table(rows) do
    Mix.shell().info("#{IO.ANSI.cyan()}By Disk:#{IO.ANSI.reset()}")

    header =
      "  " <>
        lpad("disk", 14) <>
        "  " <>
        rpad("count", 7) <>
        "  " <>
        rpad("total_size", 12)

    sep = "  " <> String.duplicate("─", String.length(header) - 2)

    Mix.shell().info(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    Mix.shell().info(sep)

    Enum.each(rows, fn row ->
      total = to_bytes(row.total_size)

      line =
        "  " <>
          lpad(row.disk, 14) <>
          "  " <>
          rpad(to_string(row.count), 7) <>
          "  " <>
          rpad(format_size(total), 12)

      Mix.shell().info(line)
    end)

    Mix.shell().info(sep)
    Mix.shell().info("")
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp lpad(str, width), do: String.pad_trailing(to_string(str || ""), width)
  defp rpad(str, width), do: String.pad_leading(to_string(str || ""), width)

  defp format_size(0), do: "0 B"

  defp format_size(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  end

  defp format_size(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 1)} MB"
  end

  defp format_size(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 1)} KB"
  end

  defp format_size(bytes), do: "#{bytes} B"

  defp to_bytes(nil), do: 0
  defp to_bytes(n) when is_integer(n), do: n
  defp to_bytes(n) when is_float(n), do: round(n)

  defp to_bytes(d) when is_struct(d, Decimal) do
    d |> Decimal.round(0) |> Decimal.to_integer()
  end
end
