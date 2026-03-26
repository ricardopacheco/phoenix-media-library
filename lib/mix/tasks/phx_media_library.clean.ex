defmodule Mix.Tasks.PhxMediaLibrary.Clean do
  @moduledoc """
  Cleans up orphaned media files by comparing storage contents against JSONB data.

  This task discovers all schemas that use `PhxMediaLibrary.HasMedia` (via
  `__media_column__/0`), loads their records, extracts media items from the
  JSONB column, and compares against files present in storage.

  ## Usage

      # Dry run — report orphaned and missing files without changes
      $ mix phx_media_library.clean

      # Actually delete orphaned files from storage
      $ mix phx_media_library.clean --force

      # Only check a specific model
      $ mix phx_media_library.clean --model MyApp.Post

      # Only check a specific disk
      $ mix phx_media_library.clean --disk local

  ## Options

      --force         Actually delete orphaned files (default: dry run)
      --dry-run       Explicitly request dry run (default behavior)
      --disk          Only check this disk
      --model         Only check a specific schema module

  """

  @shortdoc "Cleans up orphaned media files"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          dry_run: :boolean,
          disk: :string,
          model: :string
        ]
      )

    Mix.Task.run("app.start")

    force? = opts[:force] || false

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Clean#{IO.ANSI.reset()}
    =====================
    """)

    unless force? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}")
      Mix.shell().info("Use --force to actually delete orphaned files\n")
    end

    modules = discover_modules(opts[:model])

    if modules == [] do
      Mix.shell().info("No schemas with __media_column__/0 found.")
    else
      Mix.shell().info("Discovered #{length(modules)} schema(s): #{inspect(modules)}\n")

      disks = get_disks(opts[:disk])
      all_items = collect_all_media_items(modules)

      Mix.shell().info("Found #{length(all_items)} media item(s) across all schemas\n")

      Enum.each(disks, fn disk_name ->
        check_disk(disk_name, all_items, force?)
      end)
    end

    Mix.shell().info("\n#{IO.ANSI.green()}Cleanup complete!#{IO.ANSI.reset()}")
  end

  # ---------------------------------------------------------------------------
  # Module discovery
  # ---------------------------------------------------------------------------

  defp discover_modules(nil) do
    :code.all_loaded()
    |> Enum.filter(fn {mod, _path} ->
      function_exported?(mod, :__media_column__, 0)
    end)
    |> Enum.map(fn {mod, _path} -> mod end)
    |> Enum.sort()
  end

  defp discover_modules(model_string) do
    module = Module.concat([model_string])

    unless function_exported?(module, :__media_column__, 0) do
      Mix.shell().error("#{inspect(module)} does not export __media_column__/0")
      exit(:shutdown)
    end

    [module]
  end

  # ---------------------------------------------------------------------------
  # Media item collection
  # ---------------------------------------------------------------------------

  defp collect_all_media_items(modules) do
    repo = PhxMediaLibrary.Config.repo()

    Enum.flat_map(modules, fn module ->
      column = module.__media_column__()
      owner_type = PhxMediaLibrary.Helpers.owner_type_for_module(module)
      records = repo.all(module)

      Enum.flat_map(records, fn record ->
        data = Map.get(record, column) || %{}

        PhxMediaLibrary.MediaData.all_items(data,
          owner_type: owner_type,
          owner_id: to_string(record.id)
        )
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Disk checking
  # ---------------------------------------------------------------------------

  defp get_disks(nil) do
    Application.get_env(:phx_media_library, :disks, [])
    |> Keyword.keys()
  end

  defp get_disks(disk) do
    [String.to_atom(disk)]
  end

  defp check_disk(disk_name, all_items, force?) do
    Mix.shell().info("#{IO.ANSI.cyan()}Disk: #{disk_name}#{IO.ANSI.reset()}")

    config = PhxMediaLibrary.Config.disk_config(disk_name)
    adapter = config[:adapter]

    disk_items = Enum.filter(all_items, &(&1.disk == to_string(disk_name)))

    # Build the set of expected paths from JSONB data
    expected_paths =
      disk_items
      |> Enum.flat_map(&get_all_paths/1)
      |> MapSet.new()

    case adapter do
      PhxMediaLibrary.Storage.Disk ->
        check_local_disk(config, expected_paths, disk_items, force?)

      PhxMediaLibrary.Storage.S3 ->
        Mix.shell().info("  S3 listing not yet implemented\n")

      _ ->
        Mix.shell().info("  Skipping (unsupported adapter)\n")
    end
  end

  defp check_local_disk(config, expected_paths, disk_items, force?) do
    root = config[:root]

    unless File.exists?(root) do
      Mix.shell().info("  Storage root doesn't exist: #{root}\n")
      return(:ok)
    end

    # Get all files in storage
    storage_files =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> MapSet.new()

    # Orphaned files: in storage but not expected by any JSONB record
    orphaned = MapSet.difference(storage_files, expected_paths)
    report_orphaned_files(orphaned, root, force?)

    # Missing files: expected by JSONB but not in storage
    storage = PhxMediaLibrary.Config.storage_adapter(disk_items |> List.first() |> Map.get(:disk))
    missing = find_missing_files(disk_items, storage)
    report_missing_files(missing)

    Mix.shell().info("")
  end

  # ---------------------------------------------------------------------------
  # Orphaned files
  # ---------------------------------------------------------------------------

  defp report_orphaned_files(orphaned, _root, _force?) when map_size(orphaned) == 0 do
    Mix.shell().info("  #{IO.ANSI.green()}No orphaned files found#{IO.ANSI.reset()}")
  end

  defp report_orphaned_files(orphaned, root, force?) do
    Mix.shell().info("  Found #{MapSet.size(orphaned)} orphaned file(s):")

    Enum.each(orphaned, fn path ->
      if force? do
        full_path = Path.join(root, path)
        File.rm!(full_path)
        Mix.shell().info("    #{IO.ANSI.red()}Deleted#{IO.ANSI.reset()}: #{path}")
      else
        Mix.shell().info("    #{path}")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Missing files
  # ---------------------------------------------------------------------------

  defp find_missing_files([], _storage), do: []

  defp find_missing_files(items, storage) do
    Enum.filter(items, fn item ->
      path = PhxMediaLibrary.PathGenerator.relative_path(item, nil)
      not PhxMediaLibrary.StorageWrapper.exists?(storage, path)
    end)
  end

  defp report_missing_files([]) do
    Mix.shell().info("  #{IO.ANSI.green()}No missing files found#{IO.ANSI.reset()}")
  end

  defp report_missing_files(missing) do
    Mix.shell().info(
      "  #{IO.ANSI.yellow()}Found #{length(missing)} missing file(s) (in JSONB but not in storage):#{IO.ANSI.reset()}"
    )

    Enum.each(missing, fn item ->
      Mix.shell().info(
        "    #{item.file_name} (uuid: #{item.uuid}, owner: #{item.owner_type}/#{item.owner_id})"
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  defp get_all_paths(item) do
    original = PhxMediaLibrary.PathGenerator.relative_path(item, nil)

    conversion_paths =
      item.generated_conversions
      |> Map.keys()
      |> Enum.filter(fn key -> item.generated_conversions[key] == true end)
      |> Enum.map(&PhxMediaLibrary.PathGenerator.relative_path(item, &1))

    responsive_paths =
      item.responsive_images
      |> Map.values()
      |> Enum.flat_map(fn entry ->
        variants = Map.get(entry, "variants", [])
        Enum.map(variants, & &1["path"]) |> Enum.filter(& &1)
      end)

    [original | conversion_paths ++ responsive_paths]
  end

  defp return(value), do: value
end
