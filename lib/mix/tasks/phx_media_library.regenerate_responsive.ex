defmodule Mix.Tasks.PhxMediaLibrary.RegenerateResponsive do
  @moduledoc """
  Regenerates responsive images from JSONB data on parent schemas.

  This task loads records from a specified schema, extracts image media items
  (mime_type starting with "image/") from the JSONB column, regenerates
  responsive image variants, and updates the JSONB data.

  ## Usage

      # Regenerate responsive images for a model
      $ mix phx_media_library.regenerate_responsive --model MyApp.Post

      # Regenerate for a specific collection
      $ mix phx_media_library.regenerate_responsive --model MyApp.Post --collection images

      # Dry run
      $ mix phx_media_library.regenerate_responsive --model MyApp.Post --dry-run

  ## Options

      --model         Schema module to process (required)
      --collection    Only regenerate for this collection
      --dry-run       Show what would be regenerated without doing it

  """

  @shortdoc "Regenerates responsive images"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          collection: :string,
          model: :string,
          dry_run: :boolean
        ]
      )

    unless opts[:model] do
      Mix.shell().error("Missing required --model option.")
      Mix.shell().error("Usage: mix phx_media_library.regenerate_responsive --model MyApp.Post")
      exit(:shutdown)
    end

    Mix.Task.run("app.start")

    model_module = Module.concat([opts[:model]])
    collection_filter = opts[:collection]
    dry_run? = opts[:dry_run] || false

    Code.ensure_loaded(model_module)

    unless function_exported?(model_module, :__media_column__, 0) do
      Mix.shell().error("#{inspect(model_module)} does not export __media_column__/0")
      exit(:shutdown)
    end

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Regenerate Responsive Images#{IO.ANSI.reset()}
    =============================================
    """)

    if dry_run? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}\n")
    end

    repo = PhxMediaLibrary.Config.repo()
    column = model_module.__media_column__()
    owner_type = PhxMediaLibrary.Helpers.owner_type_for_module(model_module)
    records = repo.all(model_module)

    items = collect_image_items(records, column, owner_type, collection_filter)
    total = length(items)

    Mix.shell().info("Found #{total} image(s) to process\n")

    if total == 0 do
      Mix.shell().info("#{IO.ANSI.green()}Nothing to regenerate.#{IO.ANSI.reset()}")
    else
      items
      |> Enum.with_index(1)
      |> Enum.each(fn {{record, item}, index} ->
        process_item(record, item, model_module, column, dry_run?, repo, index, total)
      end)

      Mix.shell().info("\n#{IO.ANSI.green()}Regeneration complete!#{IO.ANSI.reset()}")
    end
  end

  defp collect_image_items(records, column, owner_type, collection_filter) do
    Enum.flat_map(records, fn record ->
      data = Map.get(record, column) || %{}
      owner_id = to_string(record.id)

      items =
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

      # Only include image media items
      items
      |> Enum.filter(&image?/1)
      |> Enum.map(&{record, &1})
    end)
  end

  defp image?(%{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp image?(_), do: false

  defp process_item(_record, item, _model_module, _column, true = _dry_run?, _repo, index, total) do
    Mix.shell().info("[#{index}/#{total}] Would regenerate: #{item.file_name}")
  end

  defp process_item(record, item, model_module, column, false = _dry_run?, repo, index, total) do
    Mix.shell().info("[#{index}/#{total}] Processing: #{item.file_name}")

    case PhxMediaLibrary.ResponsiveImages.generate_all(item) do
      {:ok, responsive_data} ->
        update_responsive_images(record, item, model_module, column, responsive_data, repo)
        Mix.shell().info("  #{IO.ANSI.green()}Done#{IO.ANSI.reset()}")

      {:error, reason} ->
        Mix.shell().error("  #{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
    end
  end

  defp update_responsive_images(record, item, model_module, column, responsive_data, repo) do
    # Reload the record to get fresh data
    fresh = repo.get!(model_module, record.id)
    current_data = Map.get(fresh, column) || %{}

    updated_data =
      PhxMediaLibrary.MediaData.update_item(
        current_data,
        item.collection_name,
        item.uuid,
        fn i -> %{i | responsive_images: responsive_data} end
      )

    fresh
    |> Ecto.Changeset.change(%{column => updated_data})
    |> repo.update!()
  end
end
