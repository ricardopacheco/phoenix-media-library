defmodule PhxMediaLibrary.Conversions do
  @moduledoc """
  Handles the execution of image conversions.

  Receives a context map (`%{owner_module, owner_id, collection_name, item_uuid}`)
  and a list of `Conversion` structs. Loads the parent record, extracts the
  media item from the JSONB column, processes each conversion, and updates
  `generated_conversions` back in the JSONB.
  """

  alias PhxMediaLibrary.{
    Config,
    Conversion,
    Helpers,
    MediaData,
    PathGenerator,
    ResponsiveImages,
    Telemetry
  }

  @doc """
  Process all conversions for a media item.

  The `context` map must contain:
  - `:owner_module` - The Ecto schema module of the parent record
  - `:owner_id` - The ID of the parent record
  - `:collection_name` - The collection name
  - `:item_uuid` - The UUID of the media item
  """
  @spec process(map(), [Conversion.t()]) :: :ok | {:error, term()}
  def process(context, conversions) do
    %{
      owner_module: owner_module,
      owner_id: owner_id,
      collection_name: collection_name,
      item_uuid: item_uuid
    } = context

    processor = Config.image_processor()

    # Load fresh model and extract the media item
    model = Config.repo().get!(owner_module, owner_id)
    column = Helpers.media_column(model)
    data = Map.get(model, column) || %{}
    owner_type = Helpers.owner_type(model)

    media_item =
      MediaData.get_item(data, collection_name, item_uuid,
        owner_type: owner_type,
        owner_id: to_string(owner_id)
      )

    case media_item do
      nil ->
        {:error, :media_item_not_found}

      item ->
        original_path = PathGenerator.full_path(item, nil)

        with {:ok, image} <- processor.open(original_path) do
          results =
            Enum.map(conversions, fn conversion ->
              process_conversion(item, image, conversion, processor)
            end)

          # Update generated_conversions in JSONB
          generated =
            results
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, name} -> {to_string(name), true} end)
            |> Map.new()

          update_item_in_jsonb(model, collection_name, item_uuid, fn i ->
            %{i | generated_conversions: Map.merge(i.generated_conversions, generated)}
          end)

          # Generate responsive images for conversions if enabled
          maybe_generate_responsive_for_conversions(model, collection_name, item_uuid, results)

          :ok
        end
    end
  end

  @doc """
  Process a single conversion.
  """
  @spec process_single(map(), Conversion.t()) :: :ok | {:error, term()}
  def process_single(context, %Conversion{} = conversion) do
    process(context, [conversion])
  end

  defp process_conversion(media_item, image, %Conversion{} = conversion, processor) do
    telemetry_metadata = %{media: media_item, conversion: conversion.name}

    Telemetry.span([:phx_media_library, :conversion], telemetry_metadata, fn ->
      storage = Config.storage_adapter(media_item.disk)

      result =
        with {:ok, converted} <- processor.apply_conversion(image, conversion),
             conversion_path <- PathGenerator.relative_path(media_item, conversion.name),
             temp_path <- temp_file_path(conversion_path),
             {:ok, _} <- save_image(processor, converted, temp_path, conversion),
             {:ok, content} <- File.read(temp_path),
             :ok <- PhxMediaLibrary.StorageWrapper.put(storage, conversion_path, content) do
          File.rm(temp_path)
          {:ok, conversion.name}
        else
          error ->
            {:error, {conversion.name, error}}
        end

      stop_metadata =
        case result do
          {:ok, name} -> %{conversion: name}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  defp save_image(processor, image, path, conversion) do
    opts =
      [
        format: conversion.format,
        quality: conversion.quality
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    processor.save(image, path, opts)
  end

  defp update_item_in_jsonb(model, collection_name, uuid, update_fn) do
    Helpers.update_media_data(model, fn data ->
      MediaData.update_item(data, collection_name, uuid, update_fn)
    end)
  end

  defp maybe_generate_responsive_for_conversions(model, collection_name, item_uuid, results) do
    if Config.responsive_images_enabled?() do
      generate_responsive_for_conversions(model, collection_name, item_uuid, results)
    end
  end

  defp generate_responsive_for_conversions(model, collection_name, item_uuid, results) do
    # Get fresh model with updated conversions
    fresh = Config.repo().get!(model.__struct__, model.id)
    column = Helpers.media_column(fresh)
    data = Map.get(fresh, column) || %{}
    owner_type = Helpers.owner_type(fresh)

    media_item =
      MediaData.get_item(data, collection_name, item_uuid,
        owner_type: owner_type,
        owner_id: to_string(fresh.id)
      )

    if media_item do
      conversion_names = successful_conversion_names(results)

      responsive_data =
        Enum.reduce(conversion_names, media_item.responsive_images, fn conversion_name, acc ->
          case ResponsiveImages.generate(media_item, conversion_name) do
            {:ok, new_data} -> Map.merge(acc, new_data)
            _ -> acc
          end
        end)

      update_item_in_jsonb(fresh, collection_name, item_uuid, fn item ->
        %{item | responsive_images: responsive_data}
      end)
    end
  end

  defp successful_conversion_names(results) do
    results
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, name} -> name end)
  end

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_conversion_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
