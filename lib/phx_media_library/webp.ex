defmodule PhxMediaLibrary.Webp do
  @moduledoc """
  WebP derivatives for uploaded images.

  When a collection opts in (`collection :photos, webp: true`, or globally via
  `config :phx_media_library, :webp`), raster uploads (JPEG, PNG, HEIC/HEIF,
  TIFF, BMP) are transcoded to WebP and stored beside the original
  (`…/photo.jpg` → `…/photo.webp`). The WebP path is recorded in the item's
  `custom_properties["webp"]`, and URL helpers (`PhxMediaLibrary.url/2`,
  `<.media_img>`, …) serve it instead of the original. Named conversions are
  unaffected.

  ## Settings

  See `PhxMediaLibrary.Config.resolve_webp/1`:

    * `:quality` — WebP quality, 1–100 (default `82`)
    * `:keep_original` — `true` (default) keeps the source file. `false`
      deletes it once the upload's conversions have been generated from it —
      conversions always read the original, so they run synchronously first
      and the deletion is the last step. The item's `file_name` and
      `mime_type` keep describing the source.

  WebP needs the optional `:image` library (libvips); without it the feature
  is a no-op. Any encoding or storage failure leaves the upload as it was,
  serving the original.

  ## Example

      media_collections do
        collection :photos, webp: true
        collection :hero, webp: [quality: 90, keep_original: false]
      end

  > #### GIF {: .info}
  >
  > GIFs are left alone (unlike upstream): transcoding an animated GIF would
  > keep only its first frame.
  """

  alias PhxMediaLibrary.{Config, Helpers, StorageWrapper}

  require Logger

  # Raster formats libvips decodes into WebP. Excludes SVG (vector), WebP
  # (already WebP) and GIF (animation would be lost). HEIC/HEIF cover iPhone
  # uploads.
  @convertible ~w(image/jpeg image/png image/heic image/heif image/tiff image/bmp)

  @doc """
  Whether a MIME type can be transcoded to WebP.

  ## Examples

      iex> PhxMediaLibrary.Webp.convertible?("image/jpeg")
      true

      iex> PhxMediaLibrary.Webp.convertible?("image/gif")
      false

  """
  @spec convertible?(String.t() | nil) :: boolean()
  def convertible?(mime) when is_binary(mime), do: mime in @convertible
  def convertible?(_), do: false

  @doc """
  Resolve the effective WebP settings for a model's collection: the
  collection's `webp:` override merged over the global config.

  ## Examples

      PhxMediaLibrary.Webp.settings(post, :photos)
      #=> [enabled: true, quality: 82, keep_original: true]

  """
  @spec settings(struct(), atom() | String.t()) :: keyword()
  def settings(model, collection_name) do
    override =
      case Helpers.collection_config(model, collection_name) do
        %PhxMediaLibrary.Collection{webp: webp} -> webp
        _ -> nil
      end

    Config.resolve_webp(override)
  end

  @doc """
  The storage path of an item's WebP derivative, or `nil` when it has none.

  ## Examples

      iex> PhxMediaLibrary.Webp.path(%{custom_properties: %{"webp" => "posts/1/abc/photo.webp"}})
      "posts/1/abc/photo.webp"

      iex> PhxMediaLibrary.Webp.path(%{custom_properties: %{}})
      nil

  """
  @spec path(map()) :: String.t() | nil
  def path(%{custom_properties: %{"webp" => path}}) when is_binary(path), do: path
  def path(_item), do: nil

  @doc """
  Whether the item's WebP derivative is present in `storage`.

  Maintenance tasks use it to tell a lost original from one deliberately
  replaced by its WebP (`keep_original: false`): such items are still served.
  """
  @spec stored?(map(), StorageWrapper.t()) :: boolean()
  def stored?(item, storage) do
    case path(item) do
      nil -> false
      webp_path -> StorageWrapper.exists?(storage, webp_path)
    end
  end

  @doc """
  Transcode `source_path` (a local file) to WebP and store it beside the
  original, at `original_storage_path` with a `.webp` extension.

  Returns the item with `custom_properties["webp"]` set to the stored path;
  the caller persists it. On any processor or storage error, logs a warning
  and returns the item unchanged, so the original keeps being served.
  """
  @spec generate(map(), String.t(), keyword(), StorageWrapper.t(), String.t()) :: map()
  def generate(item, source_path, settings, storage, original_storage_path) do
    quality = Keyword.get(settings, :quality, 82)
    webp_path = Path.rootname(original_storage_path) <> ".webp"

    # libvips picks the encoder from the destination extension, so the temp
    # file must end in `.webp`.
    tmp =
      Path.join(System.tmp_dir!(), "phx_media_webp_#{System.unique_integer([:positive])}.webp")

    processor = Config.image_processor()

    result =
      with {:ok, image} <- processor.open(source_path),
           {:ok, _} <- processor.save(image, tmp, format: :webp, quality: quality),
           {:ok, content} <- File.read(tmp) do
        StorageWrapper.put(storage, webp_path, content)
      end

    _ = File.rm(tmp)

    case result do
      :ok ->
        %{item | custom_properties: Map.put(item.custom_properties || %{}, "webp", webp_path)}

      error ->
        Logger.warning(
          "[PhxMediaLibrary] WebP generation failed for #{item.file_name} " <>
            "(uuid=#{item.uuid}): #{inspect(error)}"
        )

        item
    end
  end
end
