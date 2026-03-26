defmodule PhxMediaLibrary.MediaItem do
  @moduledoc """
  A plain struct representing a single media entry within a JSONB column.

  Unlike `PhxMediaLibrary.Media` (which is an Ecto schema backed by a database
  table), `MediaItem` is a lightweight struct that lives inside a JSONB column
  on the parent schema. Each parent record (e.g., a Post) stores its media as
  a map of collections, where each collection contains a list of serialized
  `MediaItem` entries.

  ## Fields

  Serialized fields (stored in JSONB):

  - `uuid` - Unique identifier for this media item
  - `name` - Sanitized filename without extension
  - `file_name` - Original filename
  - `mime_type` - MIME type of the file
  - `disk` - Storage backend name (e.g., "local", "s3")
  - `size` - File size in bytes
  - `checksum` - Hash of the file contents
  - `checksum_algorithm` - Algorithm used for the checksum (default: "sha256")
  - `order` - Position in the collection (0-based)
  - `custom_properties` - User-defined metadata
  - `metadata` - Automatically extracted file metadata (dimensions, EXIF, etc.)
  - `generated_conversions` - Map of conversion names to completion status
  - `responsive_images` - Data for responsive image srcset
  - `inserted_at` - ISO 8601 timestamp of when the item was added

  Virtual fields (NOT serialized, populated at read time):

  - `collection_name` - The collection this item belongs to (derived from the JSONB key)
  - `owner_type` - The parent schema's table name, used for path generation
  - `owner_id` - The parent record's ID, used for path generation

  ## Example

      %MediaItem{
        uuid: "a1b2c3d4",
        name: "photo",
        file_name: "photo.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 123_456,
        generated_conversions: %{"thumb" => true},
        collection_name: "images",
        owner_type: "posts",
        owner_id: "550e8400-e29b-41d4-a716-446655440000"
      }
  """

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          name: String.t() | nil,
          file_name: String.t() | nil,
          mime_type: String.t() | nil,
          disk: String.t() | nil,
          size: non_neg_integer() | nil,
          checksum: String.t() | nil,
          checksum_algorithm: String.t(),
          order: non_neg_integer() | nil,
          custom_properties: map(),
          metadata: map(),
          generated_conversions: map(),
          responsive_images: map(),
          inserted_at: String.t() | nil,
          collection_name: String.t() | nil,
          owner_type: String.t() | nil,
          owner_id: String.t() | nil
        }

  defstruct [
    :uuid,
    :name,
    :file_name,
    :mime_type,
    :disk,
    :size,
    :checksum,
    :order,
    :inserted_at,
    :collection_name,
    :owner_type,
    :owner_id,
    checksum_algorithm: "sha256",
    custom_properties: %{},
    metadata: %{},
    generated_conversions: %{},
    responsive_images: %{}
  ]

  @serialized_fields ~w(uuid name file_name mime_type disk size checksum checksum_algorithm order custom_properties metadata generated_conversions responsive_images inserted_at)a

  @doc """
  Creates a new `MediaItem` from a keyword list or map.

  ## Examples

      iex> MediaItem.new(uuid: "abc", file_name: "photo.jpg", mime_type: "image/jpeg")
      %MediaItem{uuid: "abc", file_name: "photo.jpg", mime_type: "image/jpeg"}
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Enum.map(fn
        {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
        {key, value} when is_atom(key) -> {key, value}
      end)

    struct(__MODULE__, attrs)
  end

  @doc """
  Serializes a `MediaItem` to a JSON-compatible map with string keys.

  Virtual fields (`collection_name`, `owner_type`, `owner_id`) are excluded
  since they are derived from context at read time.

  ## Examples

      iex> item = %MediaItem{uuid: "abc", file_name: "photo.jpg", disk: "local", size: 1024}
      iex> MediaItem.to_map(item)
      %{"uuid" => "abc", "file_name" => "photo.jpg", "disk" => "local", "size" => 1024,
        "checksum_algorithm" => "sha256", "custom_properties" => %{},
        "metadata" => %{}, "generated_conversions" => %{}, "responsive_images" => %{}}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = item) do
    @serialized_fields
    |> Enum.reduce(%{}, fn field, acc ->
      value = Map.get(item, field)

      if is_nil(value) do
        acc
      else
        Map.put(acc, Atom.to_string(field), value)
      end
    end)
  end

  @doc """
  Deserializes a `MediaItem` from a JSON-compatible map with string keys.

  ## Examples

      iex> MediaItem.from_map(%{"uuid" => "abc", "file_name" => "photo.jpg"})
      %MediaItem{uuid: "abc", file_name: "photo.jpg"}
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    from_map(map, [])
  end

  @doc """
  Deserializes a `MediaItem` from a JSON-compatible map, populating virtual
  fields from the provided options.

  ## Options

  - `:owner_type` - The parent schema's table name
  - `:owner_id` - The parent record's ID
  - `:collection_name` - The collection this item belongs to

  ## Examples

      iex> MediaItem.from_map(
      ...>   %{"uuid" => "abc", "file_name" => "photo.jpg"},
      ...>   owner_type: "posts", owner_id: "123", collection_name: "images"
      ...> )
      %MediaItem{uuid: "abc", file_name: "photo.jpg", owner_type: "posts", owner_id: "123", collection_name: "images"}
  """
  @spec from_map(map(), keyword()) :: t()
  def from_map(map, opts) when is_map(map) and is_list(opts) do
    attrs =
      map
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_binary(key) ->
          atom_key = safe_to_atom(key)

          if atom_key do
            Map.put(acc, atom_key, value)
          else
            acc
          end

        _, acc ->
          acc
      end)
      |> Map.merge(%{
        collection_name: Keyword.get(opts, :collection_name),
        owner_type: Keyword.get(opts, :owner_type),
        owner_id: Keyword.get(opts, :owner_id)
      })
      |> reject_nil_virtual_fields()

    struct(__MODULE__, attrs)
  end

  @doc """
  Checks whether a conversion has been generated for this media item.

  ## Examples

      iex> item = %MediaItem{generated_conversions: %{"thumb" => true, "preview" => false}}
      iex> MediaItem.has_conversion?(item, :thumb)
      true
      iex> MediaItem.has_conversion?(item, :preview)
      false
      iex> MediaItem.has_conversion?(item, :banner)
      false
  """
  @spec has_conversion?(t(), atom() | String.t()) :: boolean()
  def has_conversion?(%__MODULE__{generated_conversions: conversions}, name) do
    Map.get(conversions, to_string(name), false) == true
  end

  # Private helpers

  @known_fields MapSet.new(
                  ~w(uuid name file_name mime_type disk size checksum checksum_algorithm order custom_properties metadata generated_conversions responsive_images inserted_at)
                )

  defp safe_to_atom(key) when is_binary(key) do
    if MapSet.member?(@known_fields, key) do
      String.to_existing_atom(key)
    else
      nil
    end
  end

  defp reject_nil_virtual_fields(attrs) do
    Enum.reject(attrs, fn
      {:collection_name, nil} -> true
      {:owner_type, nil} -> true
      {:owner_id, nil} -> true
      _ -> false
    end)
    |> Map.new()
  end
end
