defmodule PhxMediaLibrary.UrlGenerator do
  @moduledoc """
  Generates URLs for media files.

  Accepts any struct or map with the required fields (`disk`, plus
  whatever `PathGenerator` needs for path resolution).
  """

  alias PhxMediaLibrary.{Config, PathGenerator, StorageWrapper}

  @doc """
  Generate a URL for a media item.
  """
  @spec url(map(), atom() | nil, keyword()) :: String.t()
  def url(media, conversion \\ nil, opts \\ []) do
    storage = Config.storage_adapter(media.disk)
    relative_path = PathGenerator.relative_path(media, conversion)

    StorageWrapper.url(storage, relative_path, opts)
  end

  @doc """
  Generate a URL for a specific path (used for responsive images).
  """
  @spec url_for_path(map(), String.t(), keyword()) :: String.t()
  def url_for_path(media, path, opts \\ []) do
    storage = Config.storage_adapter(media.disk)
    StorageWrapper.url(storage, path, opts)
  end
end
