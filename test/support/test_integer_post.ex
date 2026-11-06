defmodule PhxMediaLibrary.TestIntegerPost do
  @moduledoc """
  A test schema with the default integer (`bigserial`) primary key.

  `PhxMediaLibrary.TestPost` uses UUIDs; this schema verifies that media
  works the same for parents whose primary key is an integer, since the
  owner id only ever reaches paths and JSONB lookups as a string.
  """

  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "integer_posts" do
    field(:title, :string)
    field(:media_data, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def media_collections do
    [
      collection(:images),
      collection(:documents, accepts: ~w(text/plain))
    ]
  end

  def media_conversions do
    [
      conversion(:thumb, width: 50, height: 50, fit: :cover, collections: [:images])
    ]
  end
end
