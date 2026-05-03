defmodule PhxMediaLibrary.Media do
  @moduledoc """
  Utility module for working with media items.

  This is a plain struct (not an Ecto schema) with the same fields as
  `PhxMediaLibrary.MediaItem`. It provides functions for:

  - `url/2`, `path/2` — URL and filesystem path generation
  - `srcset/2`, `placeholder/2` — responsive image helpers
  - `has_conversion?/2` — check if a conversion was generated
  - `verify_integrity/1` — checksum verification against stored files
  - `delete_files/1` — remove all files (original + conversions + responsive) from storage
  - `compute_checksum/2` — compute SHA-256/MD5/SHA-1 checksums
  - `from_media_item/1`, `to_media_item/1` — convert between `Media` and `MediaItem` structs

  ## Fields

  - `uuid` - Unique identifier used in file paths
  - `collection_name` - The collection this media belongs to
  - `name` - Sanitized filename without extension
  - `file_name` - Original filename
  - `mime_type` - MIME type of the file
  - `disk` - Storage disk name (e.g., "local", "s3")
  - `size` - File size in bytes
  - `custom_properties` - User-defined metadata
  - `generated_conversions` - Map of conversion names to completion status
  - `responsive_images` - Data for responsive image srcset
  - `order` - Position within the collection
  - `checksum` - SHA-256 (or other algorithm) hash of the file contents
  - `checksum_algorithm` - Algorithm used for the checksum (e.g., "sha256")
  - `metadata` - Automatically extracted file metadata (dimensions, duration, EXIF, etc.)
  - `inserted_at` - ISO 8601 timestamp of when the item was added
  - `owner_type` - The parent schema's table name (virtual, for path generation)
  - `owner_id` - The parent record's ID (virtual, for path generation)
  """

  alias PhxMediaLibrary.{
    Config,
    Helpers,
    MediaItem,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    UrlGenerator
  }

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          collection_name: String.t() | nil,
          name: String.t() | nil,
          file_name: String.t() | nil,
          mime_type: String.t() | nil,
          disk: String.t() | nil,
          size: non_neg_integer() | nil,
          custom_properties: map(),
          generated_conversions: map(),
          responsive_images: map(),
          order: non_neg_integer() | nil,
          checksum: String.t() | nil,
          checksum_algorithm: String.t(),
          metadata: map(),
          inserted_at: String.t() | nil,
          owner_type: String.t() | nil,
          owner_id: String.t() | nil
        }

  defstruct [
    :uuid,
    :collection_name,
    :name,
    :file_name,
    :mime_type,
    :disk,
    :size,
    :checksum,
    :order,
    :inserted_at,
    :owner_type,
    :owner_id,
    checksum_algorithm: "sha256",
    custom_properties: %{},
    generated_conversions: %{},
    responsive_images: %{},
    metadata: %{}
  ]

  @doc """
  Get the URL for this media item.

  Pass `opts` to forward adapter-specific options such as `signed: true`,
  `download: true`, or `cache_bust: true`. See `PhxMediaLibrary.UrlGenerator`
  for the full list.
  """
  @spec url(t() | MediaItem.t(), atom() | nil, keyword()) :: String.t()
  def url(media, conversion \\ nil, opts \\ []) do
    UrlGenerator.url(media, conversion, opts)
  end

  @doc """
  Get a CDN-friendly URL with a cache-busting fingerprint query parameter.

  Appends `?v={checksum[0..7]}` when the media item has a stored checksum,
  so CDN edges serve a fresh object whenever the file is replaced. Falls back
  to a plain URL when no checksum is available.

  Equivalent to `url(media, conversion, cache_bust: true)`.

  ## Examples

      iex> Media.cdn_url(media)
      "/uploads/images/1/uuid/photo.jpg?v=a1b2c3d4"

  """
  @spec cdn_url(t() | MediaItem.t(), atom() | nil) :: String.t()
  def cdn_url(media, conversion \\ nil) do
    UrlGenerator.cdn_url(media, conversion)
  end

  @doc """
  Get a download URL that triggers a `Content-Disposition: attachment` header.

  For **S3** storage this generates a presigned GET URL with the
  `response-content-disposition` query parameter. For **local disk** storage
  the URL routes through `PhxMediaLibrary.Plug.MediaDownload`.

  Equivalent to `url(media, conversion, download: true)`.
  """
  @spec download_url(t() | MediaItem.t(), atom() | nil, keyword()) :: String.t()
  def download_url(media, conversion \\ nil, opts \\ []) do
    UrlGenerator.download_url(media, conversion, opts)
  end

  @doc """
  Get a signed, time-limited URL for a media item.

  For **S3** this is an AWS Signature V4 presigned GET URL. For **local disk**
  storage this is an HMAC-signed URL verified by
  `PhxMediaLibrary.Plug.MediaDownload`.

  Equivalent to `url(media, conversion, signed: true)`.

  ## Options

  - `:expires_in` — seconds until the URL expires (default: `3600`).
  - `:download` — also force `Content-Disposition: attachment`.
  """
  @spec signed_url(t() | MediaItem.t(), atom() | nil, keyword()) :: String.t()
  def signed_url(media, conversion \\ nil, opts \\ []) do
    UrlGenerator.signed_url(media, conversion, opts)
  end

  @doc """
  Get the filesystem path for this media item (local storage only).
  """
  @spec path(t() | MediaItem.t(), atom() | nil) :: String.t() | nil
  def path(media, conversion \\ nil) do
    PathGenerator.full_path(media, conversion)
  end

  @doc """
  Get the tiny placeholder data URI for progressive loading.
  """
  @spec placeholder(t() | MediaItem.t(), atom() | nil) :: String.t() | nil
  def placeholder(media, conversion \\ nil) do
    ResponsiveImages.placeholder(media, conversion)
  end

  @doc """
  Get the BlurHash string for a media item, or `nil` if not generated.

  Blurhash must be enabled in config and the `:image` library must be
  available. The hash is stored in `media.responsive_images["blurhash"]`
  after upload.

  Use the `<PhxMediaLibrary.Components.blurhash>` component to render the
  decoded placeholder client-side.

  ## Examples

      iex> Media.blurhash(media)
      "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"

      iex> Media.blurhash(media_without_hash)
      nil

  """
  @spec blurhash(t() | MediaItem.t()) :: String.t() | nil
  def blurhash(%{responsive_images: responsive}) do
    get_in(responsive || %{}, ["blurhash"])
  end

  @doc """
  Get the srcset attribute value for responsive images.
  """
  @spec srcset(t() | MediaItem.t(), atom() | nil) :: String.t() | nil
  def srcset(%{responsive_images: responsive} = media, conversion \\ nil) do
    key = Helpers.conversion_key(conversion)

    case Map.get(responsive, key) do
      nil ->
        nil

      %{"variants" => variants} when is_list(variants) ->
        build_srcset(media, variants)

      # Legacy format: list of variants directly
      variants when is_list(variants) ->
        build_srcset(media, variants)

      _ ->
        nil
    end
  end

  @doc """
  Check if a conversion has been generated.
  """
  @spec has_conversion?(t() | MediaItem.t(), atom() | String.t()) :: boolean()
  def has_conversion?(%{generated_conversions: conversions}, name) do
    Map.get(conversions, to_string(name), false) == true
  end

  @doc """
  Verify the integrity of a stored media file by comparing its checksum
  against the stored value.

  Returns `:ok` if the checksums match, `{:error, :checksum_mismatch}` if
  they don't, or `{:error, :no_checksum}` if no checksum was stored.
  """
  @spec verify_integrity(t() | MediaItem.t()) ::
          :ok | {:error, :checksum_mismatch | :no_checksum | term()}
  def verify_integrity(%{checksum: nil}), do: {:error, :no_checksum}
  def verify_integrity(%{checksum_algorithm: nil}), do: {:error, :no_checksum}

  def verify_integrity(media) do
    storage = Config.storage_adapter(media.disk)
    relative = PathGenerator.relative_path(media, nil)

    with {:ok, content} <- StorageWrapper.get(storage, relative) do
      computed = compute_checksum(content, media.checksum_algorithm)

      if computed == media.checksum do
        :ok
      else
        {:error, :checksum_mismatch}
      end
    end
  end

  @doc """
  Compute a checksum for binary content using the given algorithm.

  Supported algorithms: `"sha256"` (default), `"md5"`, `"sha1"`.
  """
  @spec compute_checksum(binary(), String.t()) :: String.t()
  def compute_checksum(content, algorithm \\ "sha256") do
    hash_algorithm =
      case algorithm do
        "sha256" -> :sha256
        "sha1" -> :sha
        "md5" -> :md5
        other -> raise "Unsupported checksum algorithm: #{inspect(other)}"
      end

    :crypto.hash(hash_algorithm, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Delete all files associated with a media item from storage.

  Removes the original file, all generated conversions, and all
  responsive image variants.
  """
  @spec delete_files(t() | MediaItem.t()) :: :ok
  def delete_files(%{disk: disk} = media) do
    storage = Config.storage_adapter(disk)

    # Delete original
    original_path = PathGenerator.relative_path(media, nil)
    StorageWrapper.delete(storage, original_path)

    # Delete conversions
    media.generated_conversions
    |> Map.keys()
    |> Enum.each(fn conversion ->
      conversion_path = PathGenerator.relative_path(media, conversion)
      StorageWrapper.delete(storage, conversion_path)
    end)

    # Delete responsive image variants and poster frames.
    # Values may be:
    #   - %{"variants" => [...], "placeholder" => ...}  (responsive images)
    #   - %{"path" => "...", "url" => "..."}             (poster frame)
    Enum.each(media.responsive_images, fn
      {_key, %{"variants" => variants}} when is_list(variants) ->
        Enum.each(variants, fn
          %{"path" => path} when is_binary(path) -> StorageWrapper.delete(storage, path)
          _ -> :ok
        end)

      {_key, %{"path" => path}} when is_binary(path) ->
        StorageWrapper.delete(storage, path)

      _ ->
        :ok
    end)

    :ok
  end

  @doc """
  Convert a `MediaItem` to a `Media` struct.
  """
  @spec from_media_item(MediaItem.t()) :: t()
  def from_media_item(%MediaItem{} = item) do
    struct(__MODULE__, Map.from_struct(item))
  end

  @doc """
  Convert a `Media` struct to a `MediaItem`.
  """
  @spec to_media_item(t()) :: MediaItem.t()
  def to_media_item(%__MODULE__{} = media) do
    struct(MediaItem, Map.from_struct(media))
  end

  # Private helpers

  defp build_srcset(media, sizes) do
    Enum.map_join(sizes, ", ", fn %{"width" => width, "path" => path} ->
      url = UrlGenerator.url_for_path(media, path)
      "#{url} #{width}w"
    end)
  end
end
