defmodule Mix.Tasks.PhxMediaLibrary.Regenerate do
  @moduledoc """
  Regenerates media conversions from JSONB data on parent schemas.

  This task loads records from a specified schema, extracts media items from
  the JSONB column, and re-runs conversion processing for each item.

  ## Usage

      # Regenerate all conversions for a model
      $ mix phx_media_library.regenerate --model MyApp.Post

      # Regenerate a specific conversion
      $ mix phx_media_library.regenerate --model MyApp.Post --conversion thumb

      # Regenerate for a specific collection only
      $ mix phx_media_library.regenerate --model MyApp.Post --collection images

      # Dry run
      $ mix phx_media_library.regenerate --model MyApp.Post --dry-run

  ## Options

      --model         Schema module to process (required)
      --conversion    Only regenerate this conversion (can be repeated)
      --collection    Only regenerate for this collection
      --dry-run       Show what would be regenerated without doing it

  """

  @shortdoc "Regenerates media conversions"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          conversion: [:string, :keep],
          collection: :string,
          model: :string,
          dry_run: :boolean
        ]
      )

    unless opts[:model] do
      Mix.shell().error("Missing required --model option.")
      Mix.shell().error("Usage: mix phx_media_library.regenerate --model MyApp.Post")
      exit(:shutdown)
    end

    Mix.Task.run("app.start")

    model_module = Module.concat([opts[:model]])
    filter_conversions = Keyword.get_values(opts, :conversion)
    collection_filter = opts[:collection]
    dry_run? = opts[:dry_run] || false

    unless function_exported?(model_module, :__media_column__, 0) do
      Mix.shell().error("#{inspect(model_module)} does not export __media_column__/0")
      exit(:shutdown)
    end

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Regenerate#{IO.ANSI.reset()}
    ==========================
    """)

    if dry_run? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}\n")
    end

    repo = PhxMediaLibrary.Config.repo()
    column = model_module.__media_column__()
    owner_type = PhxMediaLibrary.Helpers.owner_type_for_module(model_module)
    records = repo.all(model_module)

    items = collect_items(records, column, owner_type, collection_filter)
    total = length(items)

    Mix.shell().info("Found #{total} media item(s) to process\n")

    if total == 0 do
      Mix.shell().info("#{IO.ANSI.green()}Nothing to regenerate.#{IO.ANSI.reset()}")
    else
      items
      |> Enum.with_index(1)
      |> Enum.each(fn {item, index} ->
        process_item(item, model_module, filter_conversions, dry_run?, index, total)
      end)

      Mix.shell().info("\n#{IO.ANSI.green()}Regeneration complete!#{IO.ANSI.reset()}")
    end
  end

  defp collect_items(records, column, owner_type, collection_filter) do
    Enum.flat_map(records, fn record ->
      data = Map.get(record, column) || %{}
      owner_id = to_string(record.id)

      if collection_filter do
        PhxMediaLibrary.MediaData.get_collection(data, collection_filter,
          owner_type: owner_type,
          owner_id: owner_id
        )
      else
        PhxMediaLibrary.MediaData.all_items(data,
          owner_type: owner_type,
          owner_id: owner_id
        )
      end
    end)
  end

  defp process_item(item, model_module, filter_conversions, dry_run?, index, total) do
    progress = "#{String.pad_leading("#{index}", String.length("#{total}"))}/#{total}"
    collection_name = item.collection_name

    conversions = get_conversions(model_module, collection_name, filter_conversions)

    if conversions == [] do
      Mix.shell().info("[#{progress}] #{item.file_name} - no conversions to process")
    else
      conversion_names = Enum.map_join(conversions, ", ", &to_string(&1.name))

      if dry_run? do
        Mix.shell().info(
          "[#{progress}] #{item.file_name} - would regenerate: #{conversion_names}"
        )
      else
        Mix.shell().info("[#{progress}] #{item.file_name} - regenerating: #{conversion_names}")

        context = %{
          owner_module: model_module,
          owner_id: item.owner_id,
          collection_name: collection_name,
          item_uuid: item.uuid
        }

        case PhxMediaLibrary.Conversions.process(context, conversions) do
          :ok ->
            :ok

          {:error, reason} ->
            Mix.shell().error("  #{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        end
      end
    end
  end

  defp get_conversions(model_module, collection_name, filter_conversions) do
    collection_atom =
      if is_binary(collection_name), do: String.to_atom(collection_name), else: collection_name

    conversions =
      PhxMediaLibrary.ModelRegistry.get_model_conversions(model_module, collection_atom)

    if filter_conversions != [] do
      Enum.filter(conversions, &(to_string(&1.name) in filter_conversions))
    else
      conversions
    end
  end

end
