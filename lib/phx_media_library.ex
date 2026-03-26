defmodule PhxMediaLibrary do
  @moduledoc """
  A robust media management library for Elixir and Phoenix.

  PhxMediaLibrary stores media metadata in JSONB columns on your Ecto schemas,
  eliminating the need for a separate `media` table and improving read
  performance. Each schema that needs media declares a `:map` field and the
  library handles storage, conversions, and responsive images.

  ## Quick Start

      # 1. Schema setup
      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          field :media_data, :map, default: %{}
          timestamps()
        end

        media_collections do
          collection :images, max_files: 20 do
            convert :thumb, width: 150, height: 150, fit: :cover
          end
        end
      end

      # 2. Adding media
      {:ok, item} =
        post
        |> PhxMediaLibrary.add("/path/to/image.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      # 3. Retrieving
      PhxMediaLibrary.get_media(post, :images)           # all items
      PhxMediaLibrary.get_first_media_url(post, :images)  # URL of first
      PhxMediaLibrary.get_first_media_url(post, :images, :thumb)

      # 4. Deleting
      PhxMediaLibrary.delete_media(post, :images, item.uuid)
      PhxMediaLibrary.clear_collection(post, :images)

      # 5. Reordering
      PhxMediaLibrary.reorder(post, :images, [uuid3, uuid1, uuid2])

  """

  alias PhxMediaLibrary.{
    Config,
    Error,
    Helpers,
    Media,
    MediaAdder,
    MediaData,
    MediaItem,
    PathGenerator,
    StorageWrapper,
    Telemetry
  }

  # ---------------------------------------------------------------------------
  # Fluent Builder API
  # ---------------------------------------------------------------------------

  @doc """
  Start adding media to a model from a file path or upload.

  Returns a `MediaAdder` struct that can be piped through configuration
  functions before finalizing with `to_collection/2`.

  ## Examples

      post
      |> PhxMediaLibrary.add("/path/to/file.jpg")
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec add(Ecto.Schema.t(), Path.t() | map()) :: MediaAdder.t()
  def add(model, source) do
    MediaAdder.new(model, source)
  end

  @doc """
  Add media from a remote URL.

  ## Options

  - `:headers` — custom request headers
  - `:timeout` — download timeout in milliseconds

  ## Examples

      post
      |> PhxMediaLibrary.add_from_url("https://example.com/image.jpg")
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec add_from_url(Ecto.Schema.t(), String.t(), keyword()) :: MediaAdder.t()
  def add_from_url(model, url, opts \\ []) do
    case opts do
      [] -> MediaAdder.new(model, {:url, url})
      _ -> MediaAdder.new(model, {:url, url, opts})
    end
  end

  @doc """
  Set a custom filename for the media.
  """
  @spec using_filename(MediaAdder.t(), String.t()) :: MediaAdder.t()
  defdelegate using_filename(adder, filename), to: MediaAdder

  @doc """
  Attach custom properties (metadata) to the media.
  """
  @spec with_custom_properties(MediaAdder.t(), map()) :: MediaAdder.t()
  defdelegate with_custom_properties(adder, properties), to: MediaAdder

  @doc """
  Enable responsive image generation for this media.
  """
  @spec with_responsive_images(MediaAdder.t()) :: MediaAdder.t()
  defdelegate with_responsive_images(adder), to: MediaAdder

  @doc """
  Disable automatic metadata extraction for this media.
  """
  @spec without_metadata(MediaAdder.t()) :: MediaAdder.t()
  defdelegate without_metadata(adder), to: MediaAdder

  @doc """
  Finalize adding media to a collection.

  ## Options

  - `:disk` - Override the storage disk for this media

  ## Examples

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec to_collection(MediaAdder.t(), atom(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  defdelegate to_collection(adder, collection_name, opts \\ []), to: MediaAdder

  @doc """
  Same as `to_collection/3` but raises on error.
  """
  @spec to_collection!(MediaAdder.t(), atom(), keyword()) :: MediaItem.t()
  def to_collection!(adder, collection_name, opts \\ []) do
    case to_collection(adder, collection_name, opts) do
      {:ok, media} ->
        media

      {:error, %{message: message} = error} ->
        raise Error,
          message: "Failed to add media to collection #{inspect(collection_name)}: #{message}",
          reason: :add_failed,
          metadata: %{collection: collection_name, original_error: error}

      {:error, reason} ->
        raise Error,
          message:
            "Failed to add media to collection #{inspect(collection_name)}: #{inspect(reason)}",
          reason: :add_failed,
          metadata: %{collection: collection_name, original_error: reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Retrieval — read from JSONB
  # ---------------------------------------------------------------------------

  @doc """
  Get all media for a model, optionally filtered by collection.

  Reads from the model's JSONB column. Items are returned sorted
  by their `order` field.

  ## Examples

      PhxMediaLibrary.get_media(post)
      PhxMediaLibrary.get_media(post, :images)

  """
  @spec get_media(Ecto.Schema.t(), atom() | nil) :: [MediaItem.t()]
  def get_media(model, collection_name \\ nil) do
    data = Helpers.media_data(model)
    owner_opts = [owner_type: Helpers.owner_type(model), owner_id: to_string(model.id)]

    items =
      if collection_name do
        MediaData.get_collection(data, collection_name, owner_opts)
      else
        MediaData.all_items(data, owner_opts)
      end

    Enum.sort_by(items, & &1.order)
  end

  @doc """
  Get the first media item for a model in a collection.
  """
  @spec get_first_media(Ecto.Schema.t(), atom()) :: MediaItem.t() | nil
  def get_first_media(model, collection_name) do
    model
    |> get_media(collection_name)
    |> List.first()
  end

  @doc """
  Get the URL for the first media item in a collection.

  ## Examples

      PhxMediaLibrary.get_first_media_url(post, :images)
      PhxMediaLibrary.get_first_media_url(post, :images, :thumb)
      PhxMediaLibrary.get_first_media_url(post, :avatar, fallback: "/default.jpg")

  """
  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion_or_opts \\ [])

  def get_first_media_url(model, collection_name, conversion) when is_atom(conversion) do
    get_first_media_url(model, collection_name, conversion, [])
  end

  def get_first_media_url(model, collection_name, opts) when is_list(opts) do
    get_first_media_url(model, collection_name, nil, opts)
  end

  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | nil, keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion, opts) do
    fallback = Keyword.get(opts, :fallback)

    case get_first_media(model, collection_name) do
      nil -> fallback
      media -> Media.url(media, conversion)
    end
  end

  @doc """
  Get URLs and metadata for all generated conversions of the first media item
  in a collection.

  Returns a list of maps with `:name`, `:type` (mime_type), `:width`,
  `:height`, and `:url` for each successfully generated conversion.

  ## Examples

      # All generated conversions
      PhxMediaLibrary.get_all_media_url(badge, :avatar)
      #=> [
      #     %{name: :large, type: "image/png", width: 512, height: 512, url: "https://..."},
      #     %{name: :small, type: "image/png", width: 50, height: 50, url: "https://..."}
      #   ]

      # Only specific conversions
      PhxMediaLibrary.get_all_media_url(badge, :avatar, [:large, :thumbnail])

  """
  @spec get_all_media_url(Ecto.Schema.t(), atom(), [atom()]) :: [map()]
  def get_all_media_url(model, collection_name, filter \\ []) do
    case get_first_media(model, collection_name) do
      nil ->
        []

      media ->
        generated =
          media.generated_conversions
          |> Enum.filter(fn {_name, value} -> value == true end)
          |> Enum.map(fn {name, _} -> String.to_existing_atom(name) end)

        names =
          if filter == [] do
            generated
          else
            Enum.filter(generated, &(&1 in filter))
          end

        conversion_defs = get_conversion_definitions(model, collection_name)

        Enum.map(names, fn name ->
          definition = Enum.find(conversion_defs, fn c -> c.name == name end)

          %{
            name: name,
            type: media.mime_type,
            width: if(definition, do: definition.width),
            height: if(definition, do: definition.height),
            url: Media.url(media, name)
          }
        end)
    end
  end

  defp get_conversion_definitions(model, collection_name) do
    module = model.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :get_media_conversions, 1) do
      module.get_media_conversions(collection_name)
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # URL / Path / Srcset delegates
  # ---------------------------------------------------------------------------

  @doc """
  Get the URL for a media item, optionally for a specific conversion.
  """
  @spec url(MediaItem.t() | Media.t(), atom() | nil) :: String.t()
  defdelegate url(media, conversion \\ nil), to: Media

  @doc """
  Get the filesystem path for a media item (local storage only).
  """
  @spec path(MediaItem.t() | Media.t(), atom() | nil) :: String.t() | nil
  defdelegate path(media, conversion \\ nil), to: Media

  @doc """
  Get the srcset attribute value for responsive images.
  """
  @spec srcset(MediaItem.t() | Media.t(), atom() | nil) :: String.t() | nil
  defdelegate srcset(media, conversion \\ nil), to: Media

  @doc """
  Verify the integrity of a stored media file by comparing its stored
  checksum against a freshly computed one.
  """
  @spec verify_integrity(MediaItem.t() | Media.t()) ::
          :ok | {:error, :checksum_mismatch | :no_checksum | term()}
  defdelegate verify_integrity(media), to: Media

  # ---------------------------------------------------------------------------
  # Delete operations
  # ---------------------------------------------------------------------------

  @doc """
  Delete a media item from a collection by UUID.

  Removes the item from the model's JSONB column and deletes all associated
  files (original, conversions, responsive variants) from storage.

  ## Examples

      {:ok, deleted_item} = PhxMediaLibrary.delete_media(post, :images, "uuid-abc")

  """
  @spec delete_media(Ecto.Schema.t(), atom(), String.t()) ::
          {:ok, MediaItem.t()} | {:error, :not_found}
  def delete_media(model, collection_name, uuid) do
    Telemetry.span(
      [:phx_media_library, :delete],
      %{collection: collection_name, uuid: uuid},
      fn ->
        owner_opts = [owner_type: Helpers.owner_type(model), owner_id: to_string(model.id)]

        {removed, updated_data} =
          model
          |> Helpers.media_data()
          |> MediaData.remove_item(collection_name, uuid, owner_opts)

        case removed do
          nil ->
            {{:error, :not_found}, %{error: :not_found}}

          item ->
            # Delete files from storage
            Media.delete_files(item)

            # Save updated JSONB
            column = Helpers.media_column(model)

            Config.repo().get!(model.__struct__, model.id)
            |> Ecto.Changeset.change(%{column => updated_data})
            |> Config.repo().update!()

            {{:ok, item}, %{media: item}}
        end
      end
    )
  end

  @doc """
  Same as `delete_media/3` but raises on error.
  """
  @spec delete_media!(Ecto.Schema.t(), atom(), String.t()) :: MediaItem.t()
  def delete_media!(model, collection_name, uuid) do
    case delete_media(model, collection_name, uuid) do
      {:ok, item} -> item
      {:error, :not_found} -> raise Error, message: "Media item not found", reason: :not_found
    end
  end

  @doc """
  Delete all media in a collection for a model.

  Deletes files from storage for each item, then clears the collection
  from the JSONB column.

  ## Examples

      {:ok, count} = PhxMediaLibrary.clear_collection(post, :images)

  """
  @spec clear_collection(Ecto.Schema.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def clear_collection(model, collection_name) do
    items = get_media(model, collection_name)
    count = length(items)

    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :clear_collection, count: count},
      fn ->
        # Delete files from storage
        Enum.each(items, &Media.delete_files/1)

        # Clear collection from JSONB
        Helpers.update_media_data(model, fn data ->
          Map.put(data, to_string(collection_name), [])
        end)

        {{:ok, count}, %{operation: :clear_collection, count: count}}
      end
    )
  end

  @doc """
  Delete all media for a model.

  Deletes files from storage for each item, then clears the entire
  JSONB column.

  ## Examples

      {:ok, count} = PhxMediaLibrary.clear_media(post)

  """
  @spec clear_media(Ecto.Schema.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear_media(model) do
    items = get_media(model)
    count = length(items)

    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :clear_media, count: count},
      fn ->
        # Delete files from storage
        Enum.each(items, &Media.delete_files/1)

        # Clear entire JSONB
        Helpers.update_media_data(model, fn _data -> %{} end)

        {{:ok, count}, %{operation: :clear_media, count: count}}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Reordering
  # ---------------------------------------------------------------------------

  @doc """
  Reorder media items in a collection by a list of UUIDs.

  Items are sorted to match the order of the UUID list, and their `order`
  field is updated. UUIDs not in the collection are ignored.

  ## Examples

      PhxMediaLibrary.reorder(post, :images, [uuid3, uuid1, uuid2])

  """
  @spec reorder(Ecto.Schema.t(), atom(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reorder(model, collection_name, ordered_uuids) when is_list(ordered_uuids) do
    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :reorder, count: length(ordered_uuids)},
      fn ->
        updated_model =
          Helpers.update_media_data(model, fn data ->
            MediaData.reorder(data, collection_name, ordered_uuids)
          end)

        column = Helpers.media_column(model)
        data = Map.get(updated_model, column) || %{}
        count = MediaData.count(data, collection_name)

        Telemetry.event(
          [:phx_media_library, :reorder],
          %{count: count},
          %{model: model, collection: collection_name}
        )

        {{:ok, count}, %{operation: :reorder, count: count}}
      end
    )
  end

  @doc """
  Move a media item to a specific position within its collection.

  Position is 1-based. Shifts other items to accommodate.

  ## Examples

      PhxMediaLibrary.move_to(post, :images, "uuid-abc", 1)  # move to first

  """
  @spec move_to(Ecto.Schema.t(), atom(), String.t(), pos_integer()) ::
          {:ok, MediaItem.t()} | {:error, :not_found}
  def move_to(model, collection_name, uuid, position)
      when is_integer(position) and position >= 1 do
    data = Helpers.media_data(model)
    items = MediaData.get_collection(data, collection_name)
    uuids = Enum.map(items, & &1.uuid)

    if uuid in uuids do
      # Remove target from list
      others = Enum.reject(uuids, &(&1 == uuid))
      clamped = min(position - 1, length(others))
      reordered = List.insert_at(others, clamped, uuid)

      {:ok, _count} = reorder(model, collection_name, reordered)

      # Return the updated item
      fresh_model = Config.repo().get!(model.__struct__, model.id)
      fresh_data = Helpers.media_data(fresh_model)
      owner_opts = [owner_type: Helpers.owner_type(model), owner_id: to_string(model.id)]

      case MediaData.get_item(fresh_data, collection_name, uuid, owner_opts) do
        nil -> {:error, :not_found}
        item -> {:ok, item}
      end
    else
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Direct / Presigned Uploads
  # ---------------------------------------------------------------------------

  @doc """
  Generate a presigned URL for direct client-to-storage uploads.

  ## Options

  - `:disk` — storage disk to use
  - `:filename` — the filename for the upload (required)
  - `:content_type` — expected MIME type
  - `:expires_in` — URL expiration in seconds
  - `:max_size` — maximum upload size in bytes

  ## Examples

      {:ok, url, fields, key} =
        PhxMediaLibrary.presigned_upload_url(post, :images,
          filename: "photo.jpg",
          content_type: "image/jpeg"
        )

  """
  @spec presigned_upload_url(Ecto.Schema.t(), atom(), keyword()) ::
          {:ok, String.t(), map(), String.t()} | {:error, term()}
  def presigned_upload_url(model, collection_name, opts \\ []) do
    filename = Keyword.fetch!(opts, :filename)
    disk = Keyword.get(opts, :disk) || Helpers.default_disk(model, collection_name)
    storage = Config.storage_adapter(disk)

    uuid = Ecto.UUID.generate()
    owner_type = Helpers.owner_type(model)

    storage_path =
      PathGenerator.for_new_media(%{
        owner_type: owner_type,
        owner_id: model.id,
        uuid: uuid,
        file_name: filename
      })

    presigned_opts =
      opts
      |> Keyword.take([:expires_in, :content_type])
      |> maybe_add_size_constraint(opts)

    case StorageWrapper.presigned_upload_url(storage, storage_path, presigned_opts) do
      {:ok, url, fields} ->
        {:ok, url, fields, storage_path}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Complete a direct (presigned) upload by creating the media record in JSONB.

  ## Required options

  - `:filename` — original filename
  - `:content_type` — MIME type
  - `:size` — file size in bytes

  ## Optional options

  - `:disk` — storage disk
  - `:custom_properties` — metadata map
  - `:checksum` — pre-computed checksum
  - `:checksum_algorithm` — algorithm used (default: `"sha256"`)

  """
  @spec complete_external_upload(Ecto.Schema.t(), atom(), String.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def complete_external_upload(model, collection_name, storage_path, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.fetch!(opts, :content_type)
    size = Keyword.fetch!(opts, :size)
    disk = Keyword.get(opts, :disk) || Helpers.default_disk(model, collection_name)
    custom_properties = Keyword.get(opts, :custom_properties, %{})
    checksum = Keyword.get(opts, :checksum)
    checksum_algorithm = Keyword.get(opts, :checksum_algorithm, "sha256")

    # Extract UUID from the storage path (3rd segment: type/id/uuid/filename)
    uuid =
      storage_path
      |> Path.split()
      |> Enum.at(2) || Ecto.UUID.generate()

    owner_type = Helpers.owner_type(model)

    media_item =
      MediaItem.new(
        uuid: uuid,
        name: Helpers.sanitize_name(filename),
        file_name: filename,
        mime_type: content_type,
        disk: to_string(disk),
        size: size,
        custom_properties: custom_properties,
        metadata: %{},
        order: next_order(model, collection_name),
        checksum: checksum,
        checksum_algorithm: if(checksum, do: checksum_algorithm, else: "sha256"),
        inserted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        owner_type: owner_type,
        owner_id: to_string(model.id),
        collection_name: to_string(collection_name)
      )

    Telemetry.span(
      [:phx_media_library, :add],
      %{collection: collection_name, source_type: :external, model: model},
      fn ->
        # Add to JSONB
        Helpers.update_media_data(model, fn data ->
          MediaData.put_item(data, collection_name, media_item)
        end)

        # Trigger conversions
        maybe_process_conversions(model, media_item, collection_name)

        result = {:ok, media_item}
        {result, %{media: media_item}}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp next_order(model, collection_name) do
    data = Helpers.media_data(model)
    MediaData.count(data, collection_name)
  end

  defp maybe_add_size_constraint(presigned_opts, opts) do
    case Keyword.get(opts, :max_size) do
      nil -> presigned_opts
      max -> Keyword.put(presigned_opts, :content_length_range, {0, max})
    end
  end

  defp maybe_process_conversions(model, media_item, collection_name) do
    module = model.__struct__
    Code.ensure_loaded(module)

    conversions =
      if function_exported?(module, :get_media_conversions, 1) do
        module.get_media_conversions(collection_name)
      else
        []
      end

    if conversions != [] do
      context = %{
        owner_module: model.__struct__,
        owner_id: model.id,
        collection_name: to_string(collection_name),
        item_uuid: media_item.uuid
      }

      Config.async_processor().process_async(context, conversions)
    end
  end
end
