defmodule PhxMediaLibrary.PathGenerator.Default do
  @moduledoc """
  Default path generator for PhxMediaLibrary.

  Produces paths in the following format:

  - Original file: `{owner_type}/{owner_id}/{uuid}/{filename}`
  - Conversion:    `{owner_type}/{owner_id}/{uuid}/{base}_{conversion}{ext}`

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   owner_type: "posts",
      ...>   owner_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Default.relative_path(media, nil)
      "posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Default.relative_path(media, :thumb)
      "posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.Default

  This is the default, so explicit configuration is only needed when
  switching back from a different generator.
  """

  @behaviour PhxMediaLibrary.PathGenerator

  @impl true
  @doc """
  Generate the relative storage path for a media item.

  Produces `{owner_type}/{owner_id}/{uuid}/{filename}` for the original
  file and `{owner_type}/{owner_id}/{uuid}/{base}_{conversion}{ext}` for
  conversions.
  """
  @spec relative_path(map(), atom() | String.t() | nil) :: String.t()
  def relative_path(media, conversion \\ nil) do
    base_path =
      Path.join([
        to_string(media.owner_type),
        to_string(media.owner_id),
        media.uuid
      ])

    filename = conversion_filename(media, conversion)
    Path.join(base_path, filename)
  end

  @impl true
  @doc """
  Generate a storage path for new media (before it has been persisted).

  Produces `{owner_type}/{owner_id}/{uuid}/{filename}`.
  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    parts = [
      to_string(attrs.owner_type),
      to_string(attrs.owner_id),
      attrs.uuid,
      attrs.file_name
    ]

    Path.join(parts)
  end

  # Private helpers

  defp conversion_filename(%{file_name: file_name}, nil), do: file_name

  defp conversion_filename(%{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
