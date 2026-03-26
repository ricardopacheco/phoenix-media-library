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
    Helpers,
    Media,
    MediaData,
    MediaItem,
    MetadataExtractor,
    MimeDetector,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    Telemetry
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
        with {:ok, file_info} <- resolve_source(adder),
             {:ok, file_info, header} <- read_and_detect_mime(file_info),
             {:ok, _validated} <- validate_collection(adder, collection_name, file_info),
             :ok <- maybe_verify_content_type(adder, collection_name, file_info, header),
             {:ok, metadata} <- maybe_extract_metadata(adder, file_info),
             {:ok, media_item} <-
               store_and_persist(adder, collection_name, file_info, metadata, opts) do
          # Trigger async conversion processing
          maybe_process_conversions(adder.model, media_item, collection_name)
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

  defp resolve_source(%__MODULE__{source: source, custom_filename: custom_filename}) do
    case source do
      {:url, url, url_opts} ->
        download_from_url(url, custom_filename, url_opts)

      {:url, url} ->
        download_from_url(url, custom_filename, [])

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

  defp download_from_url(url, custom_filename, url_opts) do
    with :ok <- validate_url(url) do
      req_opts = build_req_opts(url_opts)

      Telemetry.span(
        [:phx_media_library, :download],
        %{url: url},
        fn -> execute_download(url, custom_filename, req_opts) end
      )
    end
  end

  defp execute_download(url, custom_filename, req_opts) do
    result = do_download(url, custom_filename, req_opts)

    stop_metadata =
      case result do
        {:ok, info} -> %{url: url, size: info.size, mime_type: info.mime_type}
        {:error, reason} -> %{url: url, error: reason}
      end

    {result, stop_metadata}
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_url, :unsupported_scheme, uri.scheme}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, {:invalid_url, :missing_host}}

      true ->
        :ok
    end
  end

  defp validate_url(_), do: {:error, {:invalid_url, :not_a_string}}

  defp build_req_opts(url_opts) do
    base = [decode_body: false, redirect: true, max_redirects: 5]

    # Allow custom headers (e.g. for authenticated URLs)
    headers = Keyword.get(url_opts, :headers, [])
    timeout = Keyword.get(url_opts, :timeout)

    opts = if headers != [], do: Keyword.put(base, :headers, headers), else: base
    opts = if timeout, do: Keyword.put(opts, :receive_timeout, timeout), else: opts

    opts
  end

  defp do_download(url, custom_filename, req_opts) do
    case Req.get(url, req_opts) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        filename = custom_filename || filename_from_url(url, headers)
        mime_type = get_content_type(headers) || MIME.from_path(filename)

        temp_path = write_temp_file(body, filename)

        {:ok,
         %{
           path: temp_path,
           filename: filename,
           mime_type: mime_type,
           size: byte_size(body),
           temp: true,
           source_url: url
         }}

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp resolve_file_path(path, custom_filename) do
    with {:ok, stat} <- File.stat(path) do
      filename = custom_filename || Path.basename(path)
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
        MimeDetector.verify(header, file_info.filename, file_info.mime_type)
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

    # Build custom properties (merge source URL if present)
    custom_props =
      case file_info do
        %{source_url: url} when is_binary(url) ->
          Map.put(adder.custom_properties, "source_url", url)

        _ ->
          adder.custom_properties
      end

    # Build the media item
    media_item =
      MediaItem.new(
        uuid: uuid,
        name: Helpers.sanitize_name(file_info.filename),
        file_name: file_info.filename,
        mime_type: file_info.mime_type,
        disk: to_string(disk),
        size: file_info.size,
        custom_properties: custom_props,
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

      # Add item to model's JSONB column
      updated_model =
        Helpers.update_media_data(adder.model, fn data ->
          MediaData.put_item(data, collection_name, media_item)
        end)

      # Handle single file / max_files constraints
      maybe_cleanup_collection(updated_model, collection_name, media_item)

      # Generate responsive images if requested
      media_item =
        if adder.generate_responsive and image?(file_info.mime_type) do
          generate_responsive_images(updated_model, collection_name, media_item)
        else
          media_item
        end

      # Cleanup temp file if needed
      if file_info.temp, do: File.rm(file_info.path)

      {:ok, media_item}
    end
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

  defp generate_responsive_images(model, collection_name, media_item) do
    case ResponsiveImages.generate(media_item, nil) do
      {:ok, responsive_data} ->
        updated_item = %{media_item | responsive_images: responsive_data}

        Helpers.update_media_data(model, fn data ->
          MediaData.update_item(data, collection_name, media_item.uuid, fn _item ->
            updated_item
          end)
        end)

        updated_item

      {:error, _reason} ->
        # Log error but don't fail the upload
        media_item
    end
  end

  defp maybe_process_conversions(model, media_item, collection_name) do
    conversions = get_conversions_for(model, collection_name)

    if conversions != [] do
      # Pass context for the async processor to locate the media item
      context = %{
        owner_module: model.__struct__,
        owner_id: model.id,
        collection_name: to_string(collection_name),
        item_uuid: media_item.uuid
      }

      Config.async_processor().process_async(context, conversions)
    end
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
      uuids_to_remove = Enum.map(excess_items, & &1.uuid)

      Helpers.update_media_data(model, fn data ->
        Enum.reduce(uuids_to_remove, data, fn uuid, acc ->
          {_removed, updated} = MediaData.remove_item(acc, collection_name, uuid)
          updated
        end)
      end)
    end
  end

  defp generate_uuid, do: Ecto.UUID.generate()

  defp get_conversions_for(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_conversions, 1) do
      model.__struct__.get_media_conversions(collection_name)
    else
      []
    end
  end

  defp filename_from_url(url, headers) do
    # Try Content-Disposition first, then fall back to URL path
    case get_content_disposition_filename(headers) do
      nil -> url |> URI.parse() |> Map.get(:path, "") |> Path.basename()
      filename -> filename
    end
  end

  defp get_content_disposition_filename(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-disposition" end)
    |> case do
      {_, value} ->
        Regex.run(~r/filename="?([^"]+)"?/, value, capture: :all_but_first)
        |> case do
          [filename] -> filename
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, value} -> value |> String.split(";") |> List.first() |> String.trim()
      _ -> nil
    end
  end

  defp write_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    path
  end

  defp source_type({:url, _, _}), do: :url
  defp source_type({:url, _}), do: :url
  defp source_type(%Plug.Upload{}), do: :upload
  defp source_type(%{path: _, filename: _}), do: :upload_entry
  defp source_type(path) when is_binary(path), do: :path
  defp source_type(_), do: :unknown
end
