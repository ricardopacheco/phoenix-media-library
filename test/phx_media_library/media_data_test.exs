defmodule PhxMediaLibrary.MediaDataTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{MediaData, MediaItem}

  @sample_item_map %{
    "uuid" => "item-1",
    "name" => "photo",
    "file_name" => "photo.jpg",
    "mime_type" => "image/jpeg",
    "disk" => "local",
    "size" => 1024,
    "order" => 0,
    "checksum_algorithm" => "sha256",
    "custom_properties" => %{},
    "metadata" => %{},
    "generated_conversions" => %{},
    "responsive_images" => %{}
  }

  @sample_data %{
    "images" => [
      @sample_item_map,
      %{@sample_item_map | "uuid" => "item-2", "file_name" => "banner.png", "order" => 1}
    ],
    "avatar" => [
      %{@sample_item_map | "uuid" => "item-3", "file_name" => "me.jpg", "order" => 0}
    ]
  }

  describe "get_collection/2" do
    test "returns items for existing collection" do
      items = MediaData.get_collection(@sample_data, :images)

      assert length(items) == 2
      assert [%MediaItem{uuid: "item-1"}, %MediaItem{uuid: "item-2"}] = items
    end

    test "returns empty list for missing collection" do
      assert [] == MediaData.get_collection(@sample_data, :documents)
    end

    test "returns empty list for empty data" do
      assert [] == MediaData.get_collection(%{}, :images)
    end

    test "accepts string collection name" do
      items = MediaData.get_collection(@sample_data, "images")
      assert length(items) == 2
    end
  end

  describe "get_collection/3 with owner context" do
    test "populates virtual fields on all items" do
      items =
        MediaData.get_collection(@sample_data, :images,
          owner_type: "posts",
          owner_id: "post-123"
        )

      for item <- items do
        assert item.owner_type == "posts"
        assert item.owner_id == "post-123"
        assert item.collection_name == "images"
      end
    end
  end

  describe "get_item/3" do
    test "finds item by UUID" do
      item = MediaData.get_item(@sample_data, :images, "item-1")

      assert %MediaItem{uuid: "item-1", file_name: "photo.jpg"} = item
    end

    test "returns nil for missing UUID" do
      assert is_nil(MediaData.get_item(@sample_data, :images, "missing"))
    end

    test "returns nil for missing collection" do
      assert is_nil(MediaData.get_item(@sample_data, :documents, "item-1"))
    end
  end

  describe "get_item/4 with owner context" do
    test "populates virtual fields" do
      item =
        MediaData.get_item(@sample_data, :images, "item-1",
          owner_type: "posts",
          owner_id: "post-123"
        )

      assert item.owner_type == "posts"
      assert item.owner_id == "post-123"
      assert item.collection_name == "images"
    end
  end

  describe "put_item/3" do
    test "adds to empty data" do
      item = %MediaItem{uuid: "new-1", file_name: "doc.pdf", disk: "local", size: 2048}
      data = MediaData.put_item(%{}, :documents, item)

      assert length(data["documents"]) == 1
      assert hd(data["documents"])["uuid"] == "new-1"
    end

    test "appends to existing collection" do
      item = %MediaItem{uuid: "new-1", file_name: "new.jpg", disk: "local", size: 512}
      data = MediaData.put_item(@sample_data, :images, item)

      assert length(data["images"]) == 3
      assert List.last(data["images"])["uuid"] == "new-1"
    end

    test "creates new collection key" do
      item = %MediaItem{uuid: "new-1", file_name: "doc.pdf", disk: "local", size: 2048}
      data = MediaData.put_item(@sample_data, :documents, item)

      assert Map.has_key?(data, "documents")
      assert length(data["documents"]) == 1
      # Other collections untouched
      assert length(data["images"]) == 2
      assert length(data["avatar"]) == 1
    end

    test "serializes the item properly" do
      item = %MediaItem{
        uuid: "new-1",
        file_name: "photo.jpg",
        disk: "local",
        size: 1024,
        custom_properties: %{"alt" => "sunset"},
        collection_name: "images",
        owner_type: "posts",
        owner_id: "123"
      }

      data = MediaData.put_item(%{}, :images, item)
      stored = hd(data["images"])

      assert stored["uuid"] == "new-1"
      assert stored["custom_properties"] == %{"alt" => "sunset"}
      # Virtual fields not serialized
      refute Map.has_key?(stored, "collection_name")
      refute Map.has_key?(stored, "owner_type")
      refute Map.has_key?(stored, "owner_id")
    end
  end

  describe "remove_item/3" do
    test "removes existing item and returns it" do
      {removed, updated} = MediaData.remove_item(@sample_data, :images, "item-1")

      assert %MediaItem{uuid: "item-1"} = removed
      assert length(updated["images"]) == 1
      assert hd(updated["images"])["uuid"] == "item-2"
    end

    test "returns nil for missing UUID" do
      {removed, updated} = MediaData.remove_item(@sample_data, :images, "missing")

      assert is_nil(removed)
      assert updated == @sample_data
    end

    test "returns nil for missing collection" do
      {removed, updated} = MediaData.remove_item(@sample_data, :documents, "item-1")

      assert is_nil(removed)
      assert updated == @sample_data
    end

    test "does not affect other collections" do
      {_removed, updated} = MediaData.remove_item(@sample_data, :images, "item-1")

      assert length(updated["avatar"]) == 1
    end
  end

  describe "remove_item/4 with owner context" do
    test "populates virtual fields on removed item" do
      {removed, _updated} =
        MediaData.remove_item(@sample_data, :images, "item-1",
          owner_type: "posts",
          owner_id: "post-123"
        )

      assert removed.owner_type == "posts"
      assert removed.owner_id == "post-123"
      assert removed.collection_name == "images"
    end
  end

  describe "update_item/4" do
    test "updates matching item" do
      updated =
        MediaData.update_item(@sample_data, :images, "item-1", fn item ->
          %{item | generated_conversions: %{"thumb" => true}}
        end)

      [first, second] = updated["images"]
      assert first["generated_conversions"] == %{"thumb" => true}
      # Other item untouched
      assert second["generated_conversions"] == %{}
    end

    test "returns data unchanged for missing UUID" do
      updated =
        MediaData.update_item(@sample_data, :images, "missing", fn item ->
          %{item | size: 0}
        end)

      assert updated == @sample_data
    end

    test "returns data unchanged for missing collection" do
      updated =
        MediaData.update_item(@sample_data, :documents, "item-1", fn item ->
          %{item | size: 0}
        end)

      assert updated == @sample_data
    end

    test "does not affect other collections" do
      updated =
        MediaData.update_item(@sample_data, :images, "item-1", fn item ->
          %{item | custom_properties: %{"edited" => true}}
        end)

      assert updated["avatar"] == @sample_data["avatar"]
    end
  end

  describe "reorder/3" do
    test "reorders by UUID list and updates order field" do
      reordered = MediaData.reorder(@sample_data, :images, ["item-2", "item-1"])

      uuids = Enum.map(reordered["images"], & &1["uuid"])
      orders = Enum.map(reordered["images"], & &1["order"])

      assert uuids == ["item-2", "item-1"]
      assert orders == [0, 1]
    end

    test "appends unlisted items at the end" do
      data = %{
        "images" => [
          %{@sample_item_map | "uuid" => "a", "order" => 0},
          %{@sample_item_map | "uuid" => "b", "order" => 1},
          %{@sample_item_map | "uuid" => "c", "order" => 2}
        ]
      }

      reordered = MediaData.reorder(data, :images, ["c", "a"])

      uuids = Enum.map(reordered["images"], & &1["uuid"])
      orders = Enum.map(reordered["images"], & &1["order"])

      assert uuids == ["c", "a", "b"]
      assert orders == [0, 1, 2]
    end

    test "ignores UUIDs not in the collection" do
      reordered = MediaData.reorder(@sample_data, :images, ["item-2", "missing", "item-1"])

      uuids = Enum.map(reordered["images"], & &1["uuid"])
      assert uuids == ["item-2", "item-1"]
    end

    test "handles empty UUID list" do
      reordered = MediaData.reorder(@sample_data, :images, [])

      uuids = Enum.map(reordered["images"], & &1["uuid"])
      orders = Enum.map(reordered["images"], & &1["order"])

      assert uuids == ["item-1", "item-2"]
      assert orders == [0, 1]
    end

    test "does not affect other collections" do
      reordered = MediaData.reorder(@sample_data, :images, ["item-2", "item-1"])

      assert reordered["avatar"] == @sample_data["avatar"]
    end
  end

  describe "all_items/1" do
    test "returns flat list of all items" do
      items = MediaData.all_items(@sample_data)

      assert length(items) == 3
      uuids = Enum.map(items, & &1.uuid) |> Enum.sort()
      assert uuids == ["item-1", "item-2", "item-3"]
    end

    test "returns empty list for empty data" do
      assert [] == MediaData.all_items(%{})
    end

    test "skips empty collections" do
      data = %{"images" => [@sample_item_map], "empty" => []}
      items = MediaData.all_items(data)

      assert length(items) == 1
    end
  end

  describe "all_items/2 with owner context" do
    test "populates owner fields and collection_name" do
      items = MediaData.all_items(@sample_data, owner_type: "posts", owner_id: "post-123")

      for item <- items do
        assert item.owner_type == "posts"
        assert item.owner_id == "post-123"
        assert item.collection_name in ["images", "avatar"]
      end
    end
  end

  describe "collection_names/1" do
    test "returns sorted collection names" do
      assert MediaData.collection_names(@sample_data) == ["avatar", "images"]
    end

    test "returns empty list for empty data" do
      assert MediaData.collection_names(%{}) == []
    end
  end

  describe "count/2" do
    test "returns count for existing collection" do
      assert MediaData.count(@sample_data, :images) == 2
      assert MediaData.count(@sample_data, :avatar) == 1
    end

    test "returns 0 for missing collection" do
      assert MediaData.count(@sample_data, :documents) == 0
    end

    test "returns 0 for empty data" do
      assert MediaData.count(%{}, :images) == 0
    end
  end

  describe "empty?/1" do
    test "returns true for empty map" do
      assert MediaData.empty?(%{})
    end

    test "returns true when all collections are empty" do
      assert MediaData.empty?(%{"images" => [], "docs" => []})
    end

    test "returns false when any collection has items" do
      refute MediaData.empty?(@sample_data)
    end
  end

  describe "empty?/2" do
    test "returns true for missing collection" do
      assert MediaData.empty?(@sample_data, :documents)
    end

    test "returns true for empty collection" do
      assert MediaData.empty?(%{"images" => []}, :images)
    end

    test "returns false for non-empty collection" do
      refute MediaData.empty?(@sample_data, :images)
    end
  end
end
