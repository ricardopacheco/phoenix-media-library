defmodule Mix.Tasks.PhxMediaLibrary.Doctor do
  @moduledoc """
  Runs health checks on media files and records.

  Walks every schema registered with `PhxMediaLibrary.HasMedia` (via
  `PhxMediaLibrary.ModelRegistry.all_models/0`) and verifies that the files
  referenced from each schema's JSONB media column actually exist on disk.

  Performs two checks (orphan and soft-delete checks from the upstream
  polymorphic version do not apply to embedded JSONB storage):

  1. **File existence** — every original file referenced from JSONB exists
     on the configured disk (skipped for non-local adapters such as S3).
  2. **Broken conversions** — every entry in `generated_conversions` points
     to a file that exists on disk.

  ## Usage

      $ mix phx_media_library.doctor

  ## Options

      --skip-files    Skip file existence and broken-conversion checks
      --type TYPE     Restrict to one media type (matches __media_type__/0)
      --fix           Remove broken/missing media items from the JSONB
                      (asks for confirmation before each removal)

  ## Examples

      # Full health check
      $ mix phx_media_library.doctor

      # Restrict to one model type
      $ mix phx_media_library.doctor --type posts

      # Automatically clean up broken items after confirmation
      $ mix phx_media_library.doctor --fix

  """

  @shortdoc "Runs health checks on media files (JSONB-aware)"

  use Mix.Task

  alias PhxMediaLibrary.{Config, Helpers, MediaData, ModelRegistry, PathGenerator}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          skip_files: :boolean,
          type: :string,
          fix: :boolean
        ]
      )

    Mix.Task.run("app.start")

    repo = Config.repo()
    skip_files? = Keyword.get(opts, :skip_files, false)
    fix? = Keyword.get(opts, :fix, false)
    type_filter = opts[:type]

    Mix.shell().info("")

    Mix.shell().info(
      "#{IO.ANSI.cyan()}#{IO.ANSI.bright()}PhxMediaLibrary Doctor#{IO.ANSI.reset()}"
    )

    Mix.shell().info("======================")
    Mix.shell().info("")

    models = filter_models(ModelRegistry.all_models(), type_filter)

    if models == [] do
      Mix.shell().info(
        "#{IO.ANSI.yellow()}No HasMedia schemas registered.#{IO.ANSI.reset()}"
      )
    else
      if skip_files? do
        Mix.shell().info(
          "#{IO.ANSI.yellow()}Skipping file existence checks (--skip-files).#{IO.ANSI.reset()}"
        )

        Mix.shell().info("")
      else
        run_file_checks(repo, models, fix?)
      end
    end

    Mix.shell().info("")
  end

  # ---------------------------------------------------------------------------
  # File existence + broken conversion checks
  # ---------------------------------------------------------------------------

  defp filter_models(models, nil), do: models

  defp filter_models(models, type) do
    Enum.filter(models, &(&1.__media_type__() == type))
  end

  defp run_file_checks(repo, models, fix?) do
    Mix.shell().info("#{IO.ANSI.cyan()}File existence:#{IO.ANSI.reset()}")

    {missing, missing_conversions} =
      Enum.reduce(models, {[], []}, fn module, {miss_acc, conv_acc} ->
        m = check_module_files(repo, module)
        {miss_acc ++ m.missing, conv_acc ++ m.missing_conversions}
      end)

    print_missing(missing)
    print_missing_conversions(missing_conversions)

    if fix? and (missing != [] or missing_conversions != []) do
      run_fix(repo, missing, missing_conversions)
    end

    if missing == [] and missing_conversions == [] do
      Mix.shell().info("  #{IO.ANSI.green()}All files present.#{IO.ANSI.reset()}")
    end
  end

  defp check_module_files(repo, module) do
    type = module.__media_type__()
    column = module.__media_column__()

    rows = repo.all(module)

    Enum.reduce(rows, %{missing: [], missing_conversions: []}, fn row, acc ->
      data = Map.get(row, column) || %{}
      owner_id = to_string(row.id)

      MediaData.collection_names(data)
      |> Enum.reduce(acc, fn collection, inner_acc ->
        items =
          MediaData.get_collection(data, collection,
            owner_type: type,
            owner_id: owner_id
          )

        Enum.reduce(items, inner_acc, fn item, item_acc ->
          item_acc
          |> check_original(item, module, row, collection)
          |> check_conversions(item, module, row, collection)
        end)
      end)
    end)
  end

  defp check_original(acc, item, module, row, collection) do
    case PathGenerator.full_path(item, nil) do
      nil ->
        # Remote storage (e.g. S3) — file existence cannot be checked from here.
        acc

      full_path ->
        if File.exists?(full_path) do
          acc
        else
          entry = %{
            module: module,
            row_id: row.id,
            collection: collection,
            uuid: item.uuid,
            file_name: item.file_name,
            disk: item.disk,
            path: full_path
          }

          %{acc | missing: [entry | acc.missing]}
        end
    end
  end

  defp check_conversions(acc, item, module, row, collection) do
    Map.keys(item.generated_conversions || %{})
    |> Enum.reduce(acc, fn conversion, conv_acc ->
      case PathGenerator.full_path(item, conversion) do
        nil ->
          conv_acc

        full_path ->
          if File.exists?(full_path) do
            conv_acc
          else
            entry = %{
              module: module,
              row_id: row.id,
              collection: collection,
              uuid: item.uuid,
              file_name: item.file_name,
              conversion: conversion,
              disk: item.disk,
              path: full_path
            }

            %{conv_acc | missing_conversions: [entry | conv_acc.missing_conversions]}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp print_missing([]), do: :ok

  defp print_missing(entries) do
    Mix.shell().info(
      "  #{IO.ANSI.red()}#{length(entries)} missing original file(s):#{IO.ANSI.reset()}"
    )

    Enum.each(entries, fn e ->
      Mix.shell().info(
        "    - #{inspect(e.module)} ##{e.row_id} :#{e.collection} #{e.file_name} (uuid: #{e.uuid}, disk: #{e.disk})"
      )

      Mix.shell().info("        expected at: #{e.path}")
    end)
  end

  defp print_missing_conversions([]), do: :ok

  defp print_missing_conversions(entries) do
    Mix.shell().info(
      "  #{IO.ANSI.red()}#{length(entries)} missing conversion file(s):#{IO.ANSI.reset()}"
    )

    Enum.each(entries, fn e ->
      Mix.shell().info(
        "    - #{inspect(e.module)} ##{e.row_id} :#{e.collection} #{e.file_name} → #{e.conversion} (uuid: #{e.uuid})"
      )

      Mix.shell().info("        expected at: #{e.path}")
    end)
  end

  # ---------------------------------------------------------------------------
  # --fix mode: remove broken items from JSONB after confirmation
  # ---------------------------------------------------------------------------

  defp run_fix(repo, missing, missing_conversions) do
    Mix.shell().info("")
    Mix.shell().info("#{IO.ANSI.cyan()}--fix mode:#{IO.ANSI.reset()}")

    # Items with a missing original are removed entirely from the JSONB.
    Enum.each(missing, fn entry ->
      prompt =
        "  Remove #{inspect(entry.module)} ##{entry.row_id} :#{entry.collection} item #{entry.uuid} (#{entry.file_name}) from JSONB?"

      if Mix.shell().yes?(prompt) do
        remove_item_from_jsonb(repo, entry)

        Mix.shell().info(
          "    #{IO.ANSI.green()}removed#{IO.ANSI.reset()} #{entry.uuid}"
        )
      end
    end)

    # Missing conversions: clear that conversion from the item's
    # generated_conversions, but keep the item itself.
    Enum.each(missing_conversions, fn entry ->
      prompt =
        "  Clear conversion :#{entry.conversion} from #{inspect(entry.module)} ##{entry.row_id} item #{entry.uuid}?"

      if Mix.shell().yes?(prompt) do
        clear_conversion(repo, entry)

        Mix.shell().info(
          "    #{IO.ANSI.green()}cleared#{IO.ANSI.reset()} :#{entry.conversion} on #{entry.uuid}"
        )
      end
    end)
  end

  defp remove_item_from_jsonb(repo, entry) do
    row = repo.get!(entry.module, entry.row_id)

    Helpers.update_media_data(row, fn data ->
      {_removed, updated} = MediaData.remove_item(data, entry.collection, entry.uuid)
      updated
    end)
  end

  defp clear_conversion(repo, entry) do
    row = repo.get!(entry.module, entry.row_id)

    Helpers.update_media_data(row, fn data ->
      MediaData.update_item(data, entry.collection, entry.uuid, fn item ->
        %{item | generated_conversions: Map.delete(item.generated_conversions, entry.conversion)}
      end)
    end)
  end
end
