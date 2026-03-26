defmodule PhxMediaLibrary.PathGenerator do
  @moduledoc """
  Generates storage paths for media files.

  The default path structure is:
  `{owner_type}/{owner_id}/{uuid}/{filename}`

  Accepts any struct or map with the required fields (`owner_type`,
  `owner_id`, `uuid`, `file_name`, `disk`).
  """

  alias PhxMediaLibrary.Config

  @doc """
  Generate a path for new media (before it has been persisted).
  """
  def for_new_media(attrs) do
    parts = [
      to_string(attrs.owner_type),
      to_string(attrs.owner_id),
      attrs.uuid,
      attrs.file_name
    ]

    Path.join(parts)
  end

  @doc """
  Generate the relative storage path for a media item.
  """
  @spec relative_path(map(), atom() | String.t() | nil) :: String.t()
  def relative_path(media, conversion \\ nil) do
    base_path =
      Path.join([
        to_string(media.owner_type),
        to_string(media.owner_id),
        media.uuid
      ])

    filename = conversion_filename(media.file_name, conversion)
    Path.join(base_path, filename)
  end

  @doc """
  Get the full filesystem path (for local storage).
  """
  @spec full_path(map(), atom() | nil) :: String.t() | nil
  def full_path(media, conversion) do
    storage = Config.storage_adapter(media.disk)
    relative = relative_path(media, conversion)

    # Ensure the adapter module is loaded before checking for the optional
    # path/2 callback. function_exported?/3 does not auto-load modules.
    Code.ensure_loaded(storage.adapter)

    if function_exported?(storage.adapter, :path, 2) do
      storage.adapter.path(relative, storage.config)
    else
      nil
    end
  end

  defp conversion_filename(file_name, nil) do
    file_name
  end

  defp conversion_filename(file_name, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
