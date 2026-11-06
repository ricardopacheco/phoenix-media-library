defmodule PhxMediaLibrary.MediaAdder do
  @moduledoc """
  Builder struct for adding media to a model.

  This module provides a fluent API for configuring media before
  it is persisted to storage and the model's JSONB column.

  You typically won't use this module directly - instead use the
  functions in `PhxMediaLibrary` which delegate here.
  """

  alias PhxMediaLibrary.{
    Collection,
    Config,
    Conversions,
    Downloader,
    FileName,
    Helpers,
    Media,
    MediaData,
    MediaItem,
    MetadataExtractor,
    MimeDetector,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    Telemetry,
    UrlGenerator,
    Webp
  }

  defstruct [
    :model,
    :source,
    :custom_filename,
    :custom_properties,
    :generate_responsive,
    :extract_metadata,
    :disk
  ]

  @type source :: Path.t() | {:url, String.t()} | {:url, String.t(), keyword()} | map()

  @type t :: %__MODULE__{
          model: Ecto.Schema.t(),
          source: source(),
          custom_filename: String.t() | nil,
          custom_properties: map(),
          generate_responsive: boolean(),
          extract_metadata: boolean(),
          disk: atom() | nil
        }

  @doc """
  Create a new MediaAdder for the given model and source.
  """
  @spec new(Ecto.Schema.t(), source()) :: t()
  def new(model, source) do
    %__MODULE__{
      model: model,
      source: source,
      custom_properties: %{},
      generate_responsive: false,
      extract_metadata: MetadataExtractor.enabled?()
    }
  end

  @doc """
  Set a custom filename.
  """
  @spec using_filename(t(), String.t()) :: t()
  def using_filename(%__MODULE__{} = adder, filename) do
    %{adder | custom_filename: filename}
  end

  @doc """
  Set custom properties.
  """
  @spec with_custom_properties(t(), map()) :: t()
  def with_custom_properties(%__MODULE__{} = adder, properties) when is_map(properties) do
    %{adder | custom_properties: Map.merge(adder.custom_properties, properties)}
  end

  @doc """
  Enable responsive image generation.
  """
  @spec with_responsive_images(t()) :: t()
  def with_responsive_images(%__MODULE__{} = adder) do
    %{adder | generate_responsive: true}
  end

  @doc """
  Disable automatic metadata extraction for this media.

  By default, PhxMediaLibrary extracts metadata (dimensions, EXIF, etc.)
  from uploaded files. Use this to skip extraction for a specific upload.

  ## Examples

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.without_metadata()
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec without_metadata(t()) :: t()
  def without_metadata(%__MODULE__{} = adder) do
    %{adder | extract_metadata: false}
  end

  @doc """
  Finalize and persist the media to the model's JSONB column.
  """
  @spec to_collection(t(), atom(), keyword()) :: {:ok, MediaItem.t()} | {:error, term()}
  def to_collection(%__MODULE__{} = adder, collection_name, opts \\ []) do
    telemetry_metadata = %{
      collection: collection_name,
      source_type: source_type(adder.source),
      model: adder.model
    }

    Telemetry.span([:phx_media_library, :add], telemetry_metadata, fn ->
      result =
        with {:ok, file_info} <- resolve_source(adder, collection_name),
             {:ok, file_info, header} <- read_and_detect_mime(file_info),
             {:ok, _validated} <- validate_collection(adder, collection_name, file_info),
             :ok <- maybe_verify_content_type(adder, collection_name, file_info, header),
             {:ok, metadata} <- maybe_extract_metadata(adder, file_info),
             {:ok, media_item} <-
               store_and_persist(adder, collection_name, file_info, metadata, opts) do
          process_conversions(adder.model, media_item, collection_name)
          {:ok, media_item}
        end

      stop_metadata =
        case result do
          {:ok, media} -> %{media: media}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  # ---------------------------------------------------------------------------
  # Source resolution  # ---------------------------------------------------------------------------

  defp resolve_source(
         %__MODULE__{source: source, custom_filename: custom_filename} = adder,
         collection_name
       ) do
    case source do
      {:url, url, url_opts} ->
        download_from_url(url, adder, collection_name, url_opts)

      {:url, url} ->
        download_from_url(url, adder, collection_name, [])

      path when is_binary(path) ->
        resolve_file_path(path, custom_filename)

      # Plug.Upload must come before generic map pattern
      %Plug.Upload{path: path, filename: original_filename} ->
        resolve_file_path(path, custom_filename || original_filename)

      # Phoenix.LiveView.UploadEntry or similar map with path/filename
      %{path: path, filename: original_filename} ->
        resolve_file_path(path, custom_filename || original_filename)

      _ ->
        {:error, :invalid_source}
    end
  end

  # Remote downloads go through PhxMediaLibrary.Downloader: private hosts
  # refused, streamed to disk, capped by size and time.
  defp download_from_url(url, adder, collection_name, url_opts) do
    # Cap the download at the collection's max_size unless the caller set one.
    url_opts =
      Keyword.put_new_lazy(url_opts, :max_size, fn ->
        case Helpers.collection_config(adder.model, collection_name) do
          %Collection{max_size: max_size} -> max_size
          _ -> nil
        end
      end)

    Telemetry.span(
      [:phx_media_library, :download],
      %{url: url},
      fn -> execute_download(url, adder.custom_filename, url_opts) end
    )
  end

  defp execute_download(url, custom_filename, url_opts) do
    result =
      case Downloader.download(url, url_opts) do
        {:ok, info} when is_binary(custom_filename) ->
          {:ok, %{info | filename: FileName.safe(custom_filename)}}

        other ->
          other
      end

    stop_metadata =
      case result do
        {:ok, info} -> %{url: url, size: info.size, mime_type: info.mime_type}
        {:error, reason} -> %{url: url, error: reason}
      end

    {result, stop_metadata}
  end

  defp resolve_file_path(path, custom_filename) do
    with {:ok, stat} <- File.stat(path) do
      # Client-supplied names end up in the storage path: keep one safe segment
      filename = FileName.safe(custom_filename || Path.basename(path))
      mime_type = MIME.from_path(filename)

      {:ok,
       %{
         path: path,
         filename: filename,
         mime_type: mime_type,
         size: stat.size,
         temp: false
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation  # ---------------------------------------------------------------------------

  defp validate_collection(%__MODULE__{model: model}, collection_name, file_info) do
    case Helpers.collection_config(model, collection_name) do
      nil ->
        # No explicit collection config - allow any file
        {:ok, :no_config}

      %Collection{} = config ->
        with :ok <- validate_mime_type(config, file_info),
             :ok <- validate_file_size(config, file_info) do
          {:ok, config}
        end
    end
  end

  defp validate_mime_type(%Collection{accepts: accepts}, file_info)
       when is_list(accepts) and accepts != [] do
    if file_info.mime_type in accepts do
      :ok
    else
      {:error, {:invalid_mime_type, file_info.mime_type, accepts}}
    end
  end

  defp validate_mime_type(_config, _file_info), do: :ok

  defp validate_file_size(%Collection{max_size: max_size}, file_info)
       when is_integer(max_size) and max_size > 0 do
    if file_info.size <= max_size do
      :ok
    else
      {:error, {:file_too_large, file_info.size, max_size}}
    end
  end

  defp validate_file_size(_config, _file_info), do: :ok

  # How many bytes to read for magic-byte MIME detection.
  # TAR signatures live at offset 257, so 512 bytes covers all known formats.
  @mime_header_size 512

  defp read_and_detect_mime(file_info) do
    header = read_file_header(file_info.path, @mime_header_size)
    detected_mime = MimeDetector.detect_with_fallback(header, file_info.filename)
    {:ok, %{file_info | mime_type: detected_mime}, header}
  end

  defp read_file_header(path, max_bytes) do
    file = File.open!(path, [:read, :binary])

    try do
      case IO.binread(file, max_bytes) do
        :eof -> <<>>
        data when is_binary(data) -> data
      end
    after
      File.close(file)
    end
  end

  defp maybe_verify_content_type(
         %__MODULE__{model: model},
         collection_name,
         file_info,
         header
       ) do
    case Helpers.collection_config(model, collection_name) do
      %Collection{verify_content_type: false} ->
        :ok

      _ ->
        # Compare the content with the type the *extension* claims: it decides
        # how the file is served. (file_info.mime_type is already the detected
        # type, so comparing against it would always pass.)
        MimeDetector.verify(header, file_info.filename, MIME.from_path(file_info.filename))
    end
  end

  defp maybe_extract_metadata(%__MODULE__{extract_metadata: false}, _file_info) do
    {:ok, %{}}
  end

  defp maybe_extract_metadata(%__MODULE__{}, file_info) do
    MetadataExtractor.extract_metadata(file_info.path, file_info.mime_type)
  end

  defp store_and_persist(
         %__MODULE__{} = adder,
         collection_name,
         file_info,
         metadata,
         opts
       ) do
    uuid = generate_uuid()
    disk = opts[:disk] || adder.disk || Helpers.default_disk(adder.model, collection_name)
    storage = Config.storage_adapter(disk)
    owner_type = Helpers.owner_type(adder.model)
    owner_id = to_string(adder.model.id)

    # Build the media item
    media_item =
      MediaItem.new(
        uuid: uuid,
        name: Helpers.sanitize_name(file_info.filename),
        file_name: file_info.filename,
        mime_type: file_info.mime_type,
        disk: to_string(disk),
        size: file_info.size,
        custom_properties: build_custom_properties(adder, file_info),
        metadata: metadata,
        order: next_order(adder.model, collection_name),
        inserted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        # Virtual fields for path generation
        owner_type: owner_type,
        owner_id: owner_id,
        collection_name: to_string(collection_name)
      )

    # Determine storage path
    storage_path = PathGenerator.for_new_media(media_item)

    # Stream file to storage while computing checksum in a single pass.
    with {:ok, checksum} <- stream_and_checksum(storage, storage_path, file_info.path) do
      media_item = %{media_item | checksum: checksum, checksum_algorithm: "sha256"}

      # The WebP derivative only needs the local source, so it is made before
      # the item is first written and goes into that same write.
      media_item =
        maybe_generate_webp(adder, collection_name, media_item, file_info, storage, storage_path)

      # Add item to model's JSONB column
      updated_model =
        Helpers.update_media_data(adder.model, fn data ->
          MediaData.put_item(data, collection_name, media_item)
        end)

      # Handle single file / max_files constraints
      maybe_cleanup_collection(updated_model, collection_name, media_item)

      media_item =
        generate_derivatives(adder, updated_model, collection_name, media_item, file_info)

      # Cleanup temp file if needed
      if file_info.temp, do: File.rm(file_info.path)

      {:ok, media_item}
    end
  end

  defp maybe_generate_webp(adder, collection_name, media_item, file_info, storage, storage_path) do
    settings = Webp.settings(adder.model, collection_name)

    if Keyword.get(settings, :enabled, false) and Webp.convertible?(file_info.mime_type) do
      Webp.generate(media_item, file_info.path, settings, storage, storage_path)
    else
      media_item
    end
  end

  # Merge the source URL (remote downloads) into the custom properties.
  defp build_custom_properties(adder, %{source_url: url}) when is_binary(url) do
    Map.put(adder.custom_properties, "source_url", url)
  end

  defp build_custom_properties(adder, _file_info), do: adder.custom_properties

  # Generates responsive images, blurhash and video posters for a freshly
  # stored item. Each step persists its own result and returns the updated
  # item; failures are skipped so they never fail the upload.
  defp generate_derivatives(adder, model, collection_name, media_item, file_info) do
    # Generate responsive images when the collection opts in or the upload
    # asked for them. Runs after the WebP step, so variants can follow it.
    responsive = responsive_on_add(adder, model, collection_name)

    media_item =
      if responsive[:enabled] and image?(file_info.mime_type) do
        generate_responsive_images(model, collection_name, media_item, responsive[:widths])
      else
        media_item
      end

    # Generate blurhash placeholder when enabled and Image is available.
    # Runs after responsive images so the same open/resize work could
    # theoretically be shared; kept separate for clarity.
    media_item =
      if image?(file_info.mime_type) and Config.blurhash_enabled?() do
        maybe_generate_blurhash(model, collection_name, media_item, file_info.path)
      else
        media_item
      end

    # Generate poster frame for videos when FFmpeg is available.
    # Must happen before temp file cleanup so the source file is still present.
    if video?(file_info.mime_type) do
      maybe_generate_poster(model, collection_name, media_item, file_info.path)
    else
      media_item
    end
  end

  # Replaces the stored copy of `updated_item` in the model's JSONB.
  defp replace_item(model, collection_name, updated_item) do
    Helpers.update_media_data(model, fn data ->
      MediaData.update_item(data, collection_name, updated_item.uuid, fn _item ->
        updated_item
      end)
    end)
  end

  # Stream a file to storage while computing its SHA-256 checksum in a
  # single pass.  Each chunk is fed to both the storage adapter (via a
  # checksumming stream wrapper) and the running hash state.
  @stream_chunk_size 64 * 1024

  defp stream_and_checksum(storage, storage_path, file_path) do
    hash_key = {__MODULE__, :hash_state, make_ref()}

    Process.put(hash_key, :crypto.hash_init(:sha256))

    checksumming_stream =
      file_path
      |> File.stream!(@stream_chunk_size)
      |> Stream.map(fn chunk ->
        state = Process.get(hash_key)
        Process.put(hash_key, :crypto.hash_update(state, chunk))
        chunk
      end)

    result = StorageWrapper.put(storage, storage_path, {:stream, checksumming_stream})

    hash_state = Process.delete(hash_key)

    case result do
      :ok ->
        checksum =
          hash_state
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, checksum}

      {:error, _} = error ->
        Process.delete(hash_key)
        error
    end
  end

  defp image?(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp video?(mime_type) do
    String.starts_with?(mime_type, "video/")
  end

  defp maybe_generate_poster(model, collection_name, media_item, file_path) do
    processor = Config.video_processor()

    if processor.available?() do
      duration = media_item.metadata |> Map.get("duration") |> coerce_float()
      offset = min(duration * 0.1, 5.0) |> max(0.0)

      case processor.extract_poster(file_path, offset) do
        {:ok, jpeg_data} -> store_poster(model, collection_name, media_item, jpeg_data)
        {:error, _} -> media_item
      end
    else
      media_item
    end
  end

  defp store_poster(model, collection_name, media_item, jpeg_data) do
    storage = Config.storage_adapter(media_item.disk)
    poster_path = poster_storage_path(media_item)

    case StorageWrapper.put(storage, poster_path, jpeg_data) do
      :ok ->
        poster_url = UrlGenerator.url_for_path(media_item, poster_path)

        updated_responsive =
          Map.put(media_item.responsive_images, "poster", %{
            "path" => poster_path,
            "url" => poster_url
          })

        updated_item = %{media_item | responsive_images: updated_responsive}
        replace_item(model, collection_name, updated_item)
        updated_item

      {:error, _} ->
        media_item
    end
  end

  defp poster_storage_path(media_item) do
    base_dir = Path.dirname(PathGenerator.relative_path(media_item, nil))
    Path.join(base_dir, "poster.jpg")
  end

  defp coerce_float(nil), do: 0.0
  defp coerce_float(v) when is_float(v), do: v
  defp coerce_float(v) when is_integer(v), do: v * 1.0

  defp coerce_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp coerce_float(_), do: 0.0

  # Variants of the original are made on upload when the collection opts in
  # (`responsive: true` or a keyword), or when the upload asked for them with
  # with_responsive_images/1 — unless the collection says `responsive: false`
  # or the global config explicitly sets `enabled: false`. The global switch
  # alone doesn't enable them for every collection. Returns the resolved
  # settings, with `:enabled` set to that decision.
  defp responsive_on_add(adder, model, collection_name) do
    override =
      case Helpers.collection_config(model, collection_name) do
        %Collection{responsive: responsive} -> responsive
        _ -> nil
      end

    enabled? =
      case override do
        nil ->
          adder.generate_responsive and
            Keyword.get(Config.responsive_images_config(), :enabled) != false

        override ->
          Config.responsive_for_collection?(%{responsive: override})
      end

    override
    |> Config.resolve_responsive()
    |> Keyword.put(:enabled, enabled? and Code.ensure_loaded?(Image))
  end

  defp generate_responsive_images(model, collection_name, media_item, widths) do
    case ResponsiveImages.generate(media_item, nil, widths: widths) do
      {:ok, responsive_data} ->
        updated_item = %{media_item | responsive_images: responsive_data}
        replace_item(model, collection_name, updated_item)
        updated_item

      {:error, _reason} ->
        # Log error but don't fail the upload
        media_item
    end
  end

  defp maybe_generate_blurhash(model, collection_name, media_item, file_path) do
    case PhxMediaLibrary.Blurhash.generate(file_path) do
      {:ok, hash} ->
        updated_responsive =
          Map.put(media_item.responsive_images, "blurhash", hash)

        updated_item = %{media_item | responsive_images: updated_responsive}
        replace_item(model, collection_name, updated_item)
        updated_item

      {:error, _} ->
        # Blurhash generation failed (e.g. unsupported format) — don't
        # fail the upload, just skip the placeholder.
        media_item
    end
  end

  # Dispatches the collection's conversions. When a WebP derivative replaces
  # the original (keep_original: false), conversions — which read the
  # original — run synchronously first, and the original is deleted last,
  # only once every conversion exists (so a failed one can be retried).
  defp process_conversions(model, media_item, collection_name) do
    conversions = get_conversions_for(model, collection_name)
    context = conversion_context(model, media_item, collection_name)

    cond do
      replaces_original?(model, media_item, collection_name) ->
        if run_conversions_sync(context, conversions) == :ok and
             all_generated?(model, media_item, collection_name, conversions) do
          delete_original(media_item)
        end

      conversions != [] ->
        Config.async_processor().process_async(context, conversions)

      true ->
        :ok
    end
  end

  # Context for the async processor to locate the media item
  defp conversion_context(model, media_item, collection_name) do
    %{
      owner_module: model.__struct__,
      owner_id: model.id,
      collection_name: to_string(collection_name),
      item_uuid: media_item.uuid
    }
  end

  defp replaces_original?(model, media_item, collection_name) do
    Webp.path(media_item) != nil and
      not Keyword.get(Webp.settings(model, collection_name), :keep_original, true)
  end

  defp run_conversions_sync(_context, []), do: :ok

  defp run_conversions_sync(context, conversions) do
    processor = Config.async_processor()
    Code.ensure_loaded(processor)

    if function_exported?(processor, :process_sync, 2) do
      processor.process_sync(context, conversions)
    else
      Conversions.process(context, conversions)
    end
  end

  # Conversions.process/2 reports :ok even when single conversions fail, so
  # check what was actually recorded on the stored item.
  defp all_generated?(_model, _media_item, _collection_name, []), do: true

  defp all_generated?(model, media_item, collection_name, conversions) do
    stored =
      case Config.repo().get(model.__struct__, model.id) do
        nil ->
          nil

        fresh ->
          fresh
          |> Helpers.media_data()
          |> MediaData.get_item(collection_name, media_item.uuid,
            owner_type: media_item.owner_type,
            owner_id: media_item.owner_id
          )
      end

    generated = (stored && stored.generated_conversions) || %{}
    Enum.all?(conversions, &(generated[to_string(&1.name)] == true))
  end

  defp delete_original(media_item) do
    storage = Config.storage_adapter(media_item.disk)
    StorageWrapper.delete(storage, PathGenerator.relative_path(media_item, nil))
  end

  defp next_order(model, collection_name) do
    data = Helpers.media_data(model)
    MediaData.count(data, collection_name)
  end

  defp maybe_cleanup_collection(model, collection_name, new_item) do
    excess_items =
      case Helpers.collection_config(model, collection_name) do
        %Collection{single_file: true} ->
          model
          |> Helpers.media_data()
          |> MediaData.get_collection(collection_name,
            owner_type: new_item.owner_type,
            owner_id: new_item.owner_id
          )
          |> Enum.reject(&(&1.uuid == new_item.uuid))

        %Collection{max_files: max} when is_integer(max) ->
          items =
            model
            |> Helpers.media_data()
            |> MediaData.get_collection(collection_name,
              owner_type: new_item.owner_type,
              owner_id: new_item.owner_id
            )

          if length(items) > max do
            Enum.take(items, length(items) - max)
          else
            []
          end

        _ ->
          []
      end

    if excess_items != [] do
      # Delete files from storage for all excess items
      Enum.each(excess_items, &Media.delete_files/1)

      # Single DB write: remove all excess items from JSONB at once
      remove_items(model, collection_name, Enum.map(excess_items, & &1.uuid))
    end
  end

  defp remove_items(model, collection_name, uuids) do
    Helpers.update_media_data(model, fn data ->
      Enum.reduce(uuids, data, fn uuid, acc ->
        {_removed, updated} = MediaData.remove_item(acc, collection_name, uuid)
        updated
      end)
    end)
  end

  defp generate_uuid, do: Ecto.UUID.generate()

  defp get_conversions_for(model, collection_name) do
    module = model.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :get_media_conversions, 1) do
      module.get_media_conversions(collection_name)
    else
      []
    end
  end

  defp source_type({:url, _, _}), do: :url
  defp source_type({:url, _}), do: :url
  defp source_type(%Plug.Upload{}), do: :upload
  defp source_type(%{path: _, filename: _}), do: :upload_entry
  defp source_type(path) when is_binary(path), do: :path
  defp source_type(_), do: :unknown
end
