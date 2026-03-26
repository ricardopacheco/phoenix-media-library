defmodule PhxMediaLibrary.MediaData do
  @moduledoc """
  Manipulates the JSONB map structure that stores media items on a parent schema.

  The JSONB structure uses collection names as top-level keys, each mapping to
  an array of serialized `MediaItem` entries:

      %{
        "images" => [
          %{"uuid" => "a1b2", "file_name" => "photo.jpg", ...},
          %{"uuid" => "c3d4", "file_name" => "banner.png", ...}
        ],
        "avatar" => [
          %{"uuid" => "e5f6", "file_name" => "me.jpg", ...}
        ]
      }

  All functions in this module operate on plain maps (the raw JSONB data) and
  return plain maps. They do not interact with the database.
  """

  alias PhxMediaLibrary.MediaItem

  @type data :: map()
  @type collection_name :: atom() | String.t()
  @type uuid :: String.t()

  @doc """
  Returns all media items in a collection as `MediaItem` structs.

  Returns an empty list if the collection does not exist.

  ## Examples

      iex> data = %{"images" => [%{"uuid" => "abc", "file_name" => "photo.jpg"}]}
      iex> MediaData.get_collection(data, :images)
      [%MediaItem{uuid: "abc", file_name: "photo.jpg"}]

      iex> MediaData.get_collection(%{}, :images)
      []
  """
  @spec get_collection(data(), collection_name()) :: [MediaItem.t()]
  def get_collection(data, collection_name) do
    get_collection(data, collection_name, [])
  end

  @doc """
  Returns all media items in a collection, populating virtual fields from options.

  ## Options

  - `:owner_type` - The parent schema's table name
  - `:owner_id` - The parent record's ID

  ## Examples

      iex> data = %{"images" => [%{"uuid" => "abc", "file_name" => "photo.jpg"}]}
      iex> [item] = MediaData.get_collection(data, :images, owner_type: "posts", owner_id: "123")
      iex> item.owner_type
      "posts"
      iex> item.collection_name
      "images"
  """
  @spec get_collection(data(), collection_name(), keyword()) :: [MediaItem.t()]
  def get_collection(data, collection_name, opts) when is_map(data) and is_list(opts) do
    key = to_string(collection_name)
    opts = Keyword.put(opts, :collection_name, key)

    data
    |> Map.get(key, [])
    |> Enum.map(&MediaItem.from_map(&1, opts))
  end

  @doc """
  Finds a single media item by UUID within a collection.

  Returns `nil` if the collection or item does not exist.

  ## Examples

      iex> data = %{"images" => [%{"uuid" => "abc", "file_name" => "photo.jpg"}]}
      iex> MediaData.get_item(data, :images, "abc")
      %MediaItem{uuid: "abc", file_name: "photo.jpg"}

      iex> MediaData.get_item(data, :images, "missing")
      nil
  """
  @spec get_item(data(), collection_name(), uuid()) :: MediaItem.t() | nil
  def get_item(data, collection_name, uuid) do
    get_item(data, collection_name, uuid, [])
  end

  @doc """
  Finds a single media item by UUID, populating virtual fields from options.
  """
  @spec get_item(data(), collection_name(), uuid(), keyword()) :: MediaItem.t() | nil
  def get_item(data, collection_name, uuid, opts) when is_map(data) do
    key = to_string(collection_name)
    opts = Keyword.put(opts, :collection_name, key)

    data
    |> Map.get(key, [])
    |> Enum.find(&(&1["uuid"] == uuid))
    |> case do
      nil -> nil
      map -> MediaItem.from_map(map, opts)
    end
  end

  @doc """
  Appends a media item to a collection.

  The item is serialized via `MediaItem.to_map/1` before storage.
  Creates the collection key if it doesn't exist.

  ## Examples

      iex> item = %MediaItem{uuid: "abc", file_name: "photo.jpg", disk: "local", size: 1024}
      iex> MediaData.put_item(%{}, :images, item)
      %{"images" => [%{"uuid" => "abc", "file_name" => "photo.jpg", ...}]}
  """
  @spec put_item(data(), collection_name(), MediaItem.t()) :: data()
  def put_item(data, collection_name, %MediaItem{} = item) when is_map(data) do
    key = to_string(collection_name)
    existing = Map.get(data, key, [])
    serialized = MediaItem.to_map(item)
    Map.put(data, key, existing ++ [serialized])
  end

  @doc """
  Removes a media item by UUID from a collection.

  Returns a tuple of `{removed_item, updated_data}`. The removed item is
  returned as a `MediaItem` struct (useful for file cleanup). If the item
  is not found, returns `{nil, data}` unchanged.

  ## Examples

      iex> data = %{"images" => [%{"uuid" => "abc", "file_name" => "photo.jpg"}]}
      iex> {removed, updated} = MediaData.remove_item(data, :images, "abc")
      iex> removed.uuid
      "abc"
      iex> updated
      %{"images" => []}
  """
  @spec remove_item(data(), collection_name(), uuid()) :: {MediaItem.t() | nil, data()}
  def remove_item(data, collection_name, uuid) do
    remove_item(data, collection_name, uuid, [])
  end

  @doc """
  Removes a media item by UUID, populating virtual fields on the returned item.
  """
  @spec remove_item(data(), collection_name(), uuid(), keyword()) ::
          {MediaItem.t() | nil, data()}
  def remove_item(data, collection_name, uuid, opts) when is_map(data) do
    key = to_string(collection_name)
    opts = Keyword.put(opts, :collection_name, key)
    items = Map.get(data, key, [])

    case Enum.split_with(items, &(&1["uuid"] == uuid)) do
      {[], _rest} ->
        {nil, data}

      {[removed_map | _], rest} ->
        removed = MediaItem.from_map(removed_map, opts)
        {removed, Map.put(data, key, rest)}
    end
  end

  @doc """
  Updates a media item in-place by UUID within a collection.

  The `update_fn` receives a `MediaItem` struct and must return a `MediaItem`.
  The updated item is serialized back to the JSONB map.

  Returns the data unchanged if the item is not found.

  ## Examples

      iex> data = %{"images" => [%{"uuid" => "abc", "generated_conversions" => %{}}]}
      iex> updated = MediaData.update_item(data, :images, "abc", fn item ->
      ...>   %{item | generated_conversions: Map.put(item.generated_conversions, "thumb", true)}
      ...> end)
      iex> [item_map] = updated["images"]
      iex> item_map["generated_conversions"]
      %{"thumb" => true}
  """
  @spec update_item(data(), collection_name(), uuid(), (MediaItem.t() -> MediaItem.t())) ::
          data()
  def update_item(data, collection_name, uuid, update_fn)
      when is_map(data) and is_function(update_fn, 1) do
    key = to_string(collection_name)

    case Map.get(data, key) do
      nil ->
        data

      items when is_list(items) ->
        updated_items =
          Enum.map(items, fn item_map ->
            if item_map["uuid"] == uuid do
              item_map
              |> MediaItem.from_map()
              |> update_fn.()
              |> MediaItem.to_map()
            else
              item_map
            end
          end)

        Map.put(data, key, updated_items)
    end
  end

  @doc """
  Reorders items in a collection according to the given list of UUIDs.

  Items are sorted to match the order of `ordered_uuids`, and their `order`
  field is updated to reflect the new position (0-based). Items whose UUID
  is not in the list are appended at the end.

  ## Examples

      iex> data = %{"images" => [
      ...>   %{"uuid" => "a", "order" => 0},
      ...>   %{"uuid" => "b", "order" => 1},
      ...>   %{"uuid" => "c", "order" => 2}
      ...> ]}
      iex> reordered = MediaData.reorder(data, :images, ["c", "a", "b"])
      iex> Enum.map(reordered["images"], & &1["uuid"])
      ["c", "a", "b"]
      iex> Enum.map(reordered["images"], & &1["order"])
      [0, 1, 2]
  """
  @spec reorder(data(), collection_name(), [uuid()]) :: data()
  def reorder(data, collection_name, ordered_uuids)
      when is_map(data) and is_list(ordered_uuids) do
    key = to_string(collection_name)
    items = Map.get(data, key, [])
    items_by_uuid = Map.new(items, &{&1["uuid"], &1})

    {ordered, remaining_uuids} =
      Enum.reduce(ordered_uuids, {[], MapSet.new(Enum.map(items, & &1["uuid"]))}, fn uuid,
                                                                                     {acc,
                                                                                      remaining} ->
        case Map.get(items_by_uuid, uuid) do
          nil -> {acc, remaining}
          item -> {[item | acc], MapSet.delete(remaining, uuid)}
        end
      end)

    ordered = Enum.reverse(ordered)

    unordered =
      items
      |> Enum.filter(&MapSet.member?(remaining_uuids, &1["uuid"]))

    all_items =
      (ordered ++ unordered)
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> Map.put(item, "order", index) end)

    Map.put(data, key, all_items)
  end

  @doc """
  Returns a flat list of all media items across all collections.

  ## Examples

      iex> data = %{
      ...>   "images" => [%{"uuid" => "a"}],
      ...>   "docs" => [%{"uuid" => "b"}, %{"uuid" => "c"}]
      ...> }
      iex> length(MediaData.all_items(data))
      3
  """
  @spec all_items(data()) :: [MediaItem.t()]
  def all_items(data) do
    all_items(data, [])
  end

  @doc """
  Returns a flat list of all media items, populating virtual fields.
  """
  @spec all_items(data(), keyword()) :: [MediaItem.t()]
  def all_items(data, opts) when is_map(data) and is_list(opts) do
    Enum.flat_map(data, fn {collection_name, items} when is_list(items) ->
      item_opts = Keyword.put(opts, :collection_name, collection_name)
      Enum.map(items, &MediaItem.from_map(&1, item_opts))
    end)
  end

  @doc """
  Returns the list of collection names present in the data.

  ## Examples

      iex> MediaData.collection_names(%{"images" => [], "docs" => [%{"uuid" => "a"}]})
      ["docs", "images"]
  """
  @spec collection_names(data()) :: [String.t()]
  def collection_names(data) when is_map(data) do
    data |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the number of items in a collection.

  ## Examples

      iex> MediaData.count(%{"images" => [%{"uuid" => "a"}, %{"uuid" => "b"}]}, :images)
      2
      iex> MediaData.count(%{}, :images)
      0
  """
  @spec count(data(), collection_name()) :: non_neg_integer()
  def count(data, collection_name) when is_map(data) do
    data
    |> Map.get(to_string(collection_name), [])
    |> length()
  end

  @doc """
  Returns `true` if the data has no media items in any collection.

  ## Examples

      iex> MediaData.empty?(%{})
      true
      iex> MediaData.empty?(%{"images" => []})
      true
      iex> MediaData.empty?(%{"images" => [%{"uuid" => "a"}]})
      false
  """
  @spec empty?(data()) :: boolean()
  def empty?(data) when is_map(data) do
    Enum.all?(data, fn {_key, items} -> items == [] end)
  end

  @doc """
  Returns `true` if a specific collection has no items.

  ## Examples

      iex> MediaData.empty?(%{"images" => []}, :images)
      true
      iex> MediaData.empty?(%{}, :docs)
      true
  """
  @spec empty?(data(), collection_name()) :: boolean()
  def empty?(data, collection_name) when is_map(data) do
    data
    |> Map.get(to_string(collection_name), [])
    |> Enum.empty?()
  end
end
