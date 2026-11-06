defmodule PhxMediaLibrary.Config do
  @moduledoc """
  Configuration helpers for PhxMediaLibrary.
  """

  alias PhxMediaLibrary.VideoProcessor.FFmpeg

  @doc """
  Get the configured Ecto repo.
  """
  def repo do
    Application.fetch_env!(:phx_media_library, :repo)
  end

  @doc """
  Get the default storage disk name.
  """
  def default_disk do
    Application.get_env(:phx_media_library, :default_disk, :local)
  end

  @doc """
  Get configuration for a specific disk.
  """
  def disk_config(disk_name) do
    disks = Application.get_env(:phx_media_library, :disks, default_disks())
    disk_key = resolve_disk_key(disk_name, disks)
    lookup_disk(disk_key, disks)
  end

  defp resolve_disk_key(name, _disks) when is_atom(name), do: name

  defp resolve_disk_key(name, disks) when is_binary(name) do
    # Try to find a matching atom key without creating new atoms.
    # This avoids the String.to_existing_atom crash when the atom
    # hasn't been referenced yet in the running system.
    Enum.find_value(disks, fn {k, _v} ->
      if Atom.to_string(k) == name, do: k
    end)
  end

  defp resolve_disk_key(_name, _disks), do: nil

  defp lookup_disk(nil, disks) do
    raise "Unknown disk: nil. Available disks: #{inspect(Keyword.keys(disks))}"
  end

  defp lookup_disk(key, disks) do
    case Keyword.get(disks, key) do
      nil ->
        raise "Unknown disk: #{inspect(key)}. Available disks: #{inspect(Keyword.keys(disks))}"

      config ->
        config
    end
  end

  @doc """
  Get the storage adapter module for a disk.
  """
  def storage_adapter(disk_name) do
    config = disk_config(disk_name)
    adapter = Keyword.fetch!(config, :adapter)

    # Return a wrapper that passes config to each call
    %PhxMediaLibrary.StorageWrapper{
      adapter: adapter,
      config: config
    }
  end

  @doc """
  Get the async processor module.

  Built-in processors:

    * `PhxMediaLibrary.AsyncProcessor.Task` (default) — background Task
    * `PhxMediaLibrary.AsyncProcessor.Oban` — persistent queue with retries
    * `PhxMediaLibrary.AsyncProcessor.Inline` — runs in the calling process
      (tests, scripts, small apps)

  ## Configuration

      config :phx_media_library, async_processor: PhxMediaLibrary.AsyncProcessor.Inline

  """
  @spec async_processor() :: module()
  def async_processor do
    Application.get_env(:phx_media_library, :async_processor, PhxMediaLibrary.AsyncProcessor.Task)
  end

  @doc """
  Get the configured path generator module.

  The path generator controls how storage paths are constructed for media
  files and conversions. Any module that implements the
  `PhxMediaLibrary.PathGenerator` behaviour can be used here.

  Built-in generators:

    * `PhxMediaLibrary.PathGenerator.Default` — `{type}/{id}/{uuid}/{filename}` (default)
    * `PhxMediaLibrary.PathGenerator.Flat` — `{uuid}/{filename}`
    * `PhxMediaLibrary.PathGenerator.DateBased` — `{year}/{month}/{day}/{type}/{id}/{uuid}/{filename}`
    * `PhxMediaLibrary.PathGenerator.Tenant` — `{tenant_id}/{type}/{id}/{uuid}/{filename}`

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.DateBased

  """
  def path_generator do
    Application.get_env(
      :phx_media_library,
      :path_generator,
      PhxMediaLibrary.PathGenerator.Default
    )
  end

  @doc """
  Get the image processor module.

  Defaults to `PhxMediaLibrary.ImageProcessor.Image` when the `:image`
  library is available, otherwise falls back to
  `PhxMediaLibrary.ImageProcessor.Null` which returns clear error messages
  guiding the developer to install an image processing library.
  """
  def image_processor do
    Application.get_env(
      :phx_media_library,
      :image_processor,
      default_image_processor()
    )
  end

  defp default_image_processor do
    if Code.ensure_loaded?(Image) do
      PhxMediaLibrary.ImageProcessor.Image
    else
      PhxMediaLibrary.ImageProcessor.Null
    end
  end

  @doc """
  Get the video processor module.

  Defaults to `PhxMediaLibrary.VideoProcessor.FFmpeg` when both `ffprobe`
  and `ffmpeg` executables are found on `$PATH`, otherwise falls back to
  `PhxMediaLibrary.VideoProcessor.Null`.

  When FFmpeg is available, video metadata (duration, dimensions, codec, fps)
  is extracted automatically on every video upload and a JPEG poster frame is
  stored alongside the video file.

  ## Configuration

      config :phx_media_library,
        video_processor: MyApp.CustomVideoProcessor

  """
  @spec video_processor() :: module()
  def video_processor do
    Application.get_env(
      :phx_media_library,
      :video_processor,
      default_video_processor()
    )
  end

  defp default_video_processor do
    if FFmpeg.available?() do
      FFmpeg
    else
      PhxMediaLibrary.VideoProcessor.Null
    end
  end

  @doc """
  Get responsive images configuration.
  """
  def responsive_images_config do
    Application.get_env(:phx_media_library, :responsive_images, [])
  end

  @doc """
  Check if responsive images are enabled globally.
  """
  def responsive_images_enabled? do
    Keyword.get(responsive_images_config(), :enabled, false)
  end

  @doc """
  Check if responsive images should be generated for a specific collection.

  Resolution order:
  1. If the collection has an explicit `:responsive` setting, use it.
  2. Otherwise, fall back to the global `responsive_images_enabled?()` setting.
  """
  def responsive_for_collection?(nil), do: responsive_images_enabled?()
  def responsive_for_collection?(%{responsive: nil}), do: responsive_images_enabled?()
  def responsive_for_collection?(%{responsive: value}) when is_boolean(value), do: value

  @doc """
  Get the widths to generate for responsive images.
  """
  def responsive_image_widths do
    Keyword.get(responsive_images_config(), :widths, [320, 640, 960, 1280, 1920])
  end

  @doc """
  Check if tiny placeholders should be generated.
  """
  def tiny_placeholders_enabled? do
    Keyword.get(responsive_images_config(), :tiny_placeholder, true)
  end

  # ── WebP ────────────────────────────────────────────────────────────────────

  @webp_defaults [enabled: false, quality: 82, keep_original: true]

  @doc """
  Get the global WebP configuration (`config :phx_media_library, :webp`).

  ## Configuration

      config :phx_media_library,
        webp: [enabled: false, quality: 82, keep_original: true]

  """
  @spec webp_config() :: keyword()
  def webp_config, do: Application.get_env(:phx_media_library, :webp, [])

  @doc """
  Resolve the effective WebP settings for a collection.

  Merges the collection's `webp:` override over the global `:webp` config over
  the library defaults (`enabled: false, quality: 82, keep_original: true`):

    * `nil` — inherit the global settings
    * `true` / `false` — force WebP on or off, keeping the other knobs
    * a keyword — merged over the global settings; implies `enabled: true`
      unless it says otherwise

  Returns a keyword with `:enabled`, `:quality` and `:keep_original`. WebP
  needs the optional `:image` library, so `:enabled` is forced to `false`
  when it isn't loaded.

  ## Examples

      iex> PhxMediaLibrary.Config.resolve_webp(false)[:enabled]
      false

      iex> PhxMediaLibrary.Config.resolve_webp(quality: 90)[:quality]
      90

  """
  @spec resolve_webp(PhxMediaLibrary.Collection.override()) :: keyword()
  def resolve_webp(override) do
    @webp_defaults
    |> Keyword.merge(webp_config())
    |> apply_override(override)
    |> require_image_lib()
  end

  defp apply_override(base, nil), do: base

  defp apply_override(base, enabled) when is_boolean(enabled),
    do: Keyword.put(base, :enabled, enabled)

  defp apply_override(base, overrides) when is_list(overrides),
    do: Keyword.merge(base, Keyword.put_new(overrides, :enabled, true))

  defp require_image_lib(settings) do
    if Keyword.get(settings, :enabled, false) and not Code.ensure_loaded?(Image) do
      Keyword.put(settings, :enabled, false)
    else
      settings
    end
  end

  @doc """
  Check if blurhash generation is enabled.

  Blurhash requires the `:image` library to be available. Even when enabled
  in config, this returns `false` if the library is not loaded.

  ## Configuration

      config :phx_media_library,
        responsive_images: [
          enabled: true,
          blurhash: true   # enable blurhash generation
        ]

  """
  def blurhash_enabled? do
    Keyword.get(responsive_images_config(), :blurhash, false) and
      Code.ensure_loaded?(Image)
  end

  @doc """
  Return the global HMAC secret key used for signing local-disk URLs.

  This can be overridden per-disk via the `:secret_key_base` key in the disk
  config. Returns `nil` when not configured.

  ## Configuration

      config :phx_media_library, secret_key_base: "long-random-secret"

  """
  def secret_key_base do
    Application.get_env(:phx_media_library, :secret_key_base)
  end

  @doc """
  Return the global base URL where `PhxMediaLibrary.Plug.MediaDownload` is
  mounted.

  This can be overridden per-disk via the `:download_base_url` key in the
  disk config. Returns `nil` when not configured.

  ## Configuration

      config :phx_media_library, download_base_url: "/media"

  """
  def download_base_url do
    Application.get_env(:phx_media_library, :download_base_url)
  end

  # Default disk configuration
  defp default_disks do
    [
      local: [
        adapter: PhxMediaLibrary.Storage.Disk,
        root: "priv/static/uploads",
        base_url: "/uploads"
      ]
    ]
  end
end
