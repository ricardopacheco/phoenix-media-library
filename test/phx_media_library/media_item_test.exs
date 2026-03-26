defmodule PhxMediaLibrary.MediaItemTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.MediaItem

  describe "struct defaults" do
    test "has sensible defaults" do
      item = %MediaItem{}

      assert item.checksum_algorithm == "sha256"
      assert item.custom_properties == %{}
      assert item.metadata == %{}
      assert item.generated_conversions == %{}
      assert item.responsive_images == %{}
      assert is_nil(item.uuid)
      assert is_nil(item.collection_name)
      assert is_nil(item.owner_type)
      assert is_nil(item.owner_id)
    end
  end

  describe "new/1" do
    test "creates from keyword list" do
      item = MediaItem.new(uuid: "abc", file_name: "photo.jpg", mime_type: "image/jpeg")

      assert item.uuid == "abc"
      assert item.file_name == "photo.jpg"
      assert item.mime_type == "image/jpeg"
    end

    test "creates from atom-keyed map" do
      item = MediaItem.new(%{uuid: "abc", file_name: "photo.jpg", size: 1024})

      assert item.uuid == "abc"
      assert item.file_name == "photo.jpg"
      assert item.size == 1024
    end

    test "creates from string-keyed map" do
      item = MediaItem.new(%{"uuid" => "abc", "file_name" => "photo.jpg"})

      assert item.uuid == "abc"
      assert item.file_name == "photo.jpg"
    end

    test "preserves defaults for unspecified fields" do
      item = MediaItem.new(uuid: "abc")

      assert item.checksum_algorithm == "sha256"
      assert item.custom_properties == %{}
    end
  end

  describe "to_map/1" do
    test "serializes to string-keyed map" do
      item = %MediaItem{
        uuid: "abc",
        name: "photo",
        file_name: "photo.jpg",
        mime_type: "image/jpeg",
        disk: "local",
        size: 1024,
        checksum: "deadbeef",
        checksum_algorithm: "sha256",
        order: 0,
        custom_properties: %{"alt" => "A photo"},
        metadata: %{"width" => 800},
        generated_conversions: %{"thumb" => true},
        responsive_images: %{},
        inserted_at: "2024-01-01T00:00:00Z"
      }

      map = MediaItem.to_map(item)

      assert map["uuid"] == "abc"
      assert map["name"] == "photo"
      assert map["file_name"] == "photo.jpg"
      assert map["mime_type"] == "image/jpeg"
      assert map["disk"] == "local"
      assert map["size"] == 1024
      assert map["checksum"] == "deadbeef"
      assert map["checksum_algorithm"] == "sha256"
      assert map["order"] == 0
      assert map["custom_properties"] == %{"alt" => "A photo"}
      assert map["metadata"] == %{"width" => 800}
      assert map["generated_conversions"] == %{"thumb" => true}
      assert map["responsive_images"] == %{}
      assert map["inserted_at"] == "2024-01-01T00:00:00Z"
    end

    test "excludes virtual fields" do
      item = %MediaItem{
        uuid: "abc",
        collection_name: "images",
        owner_type: "posts",
        owner_id: "123"
      }

      map = MediaItem.to_map(item)

      refute Map.has_key?(map, "collection_name")
      refute Map.has_key?(map, "owner_type")
      refute Map.has_key?(map, "owner_id")
    end

    test "excludes nil fields" do
      item = %MediaItem{uuid: "abc", disk: "local"}

      map = MediaItem.to_map(item)

      assert Map.has_key?(map, "uuid")
      assert Map.has_key?(map, "disk")
      refute Map.has_key?(map, "name")
      refute Map.has_key?(map, "file_name")
      refute Map.has_key?(map, "size")
      refute Map.has_key?(map, "checksum")
      # Default values are included
      assert Map.has_key?(map, "checksum_algorithm")
      assert Map.has_key?(map, "custom_properties")
    end
  end

  describe "from_map/1" do
    test "deserializes from string-keyed map" do
      map = %{
        "uuid" => "abc",
        "file_name" => "photo.jpg",
        "mime_type" => "image/jpeg",
        "size" => 1024,
        "generated_conversions" => %{"thumb" => true}
      }

      item = MediaItem.from_map(map)

      assert item.uuid == "abc"
      assert item.file_name == "photo.jpg"
      assert item.mime_type == "image/jpeg"
      assert item.size == 1024
      assert item.generated_conversions == %{"thumb" => true}
    end

    test "ignores unknown keys" do
      map = %{"uuid" => "abc", "unknown_field" => "ignored"}

      item = MediaItem.from_map(map)

      assert item.uuid == "abc"
    end

    test "preserves defaults for missing keys" do
      item = MediaItem.from_map(%{"uuid" => "abc"})

      assert item.checksum_algorithm == "sha256"
      assert item.custom_properties == %{}
      assert item.metadata == %{}
    end
  end

  describe "from_map/2 with owner context" do
    test "populates virtual fields" do
      map = %{"uuid" => "abc", "file_name" => "photo.jpg"}

      item =
        MediaItem.from_map(map,
          owner_type: "posts",
          owner_id: "123",
          collection_name: "images"
        )

      assert item.uuid == "abc"
      assert item.owner_type == "posts"
      assert item.owner_id == "123"
      assert item.collection_name == "images"
    end

    test "partial owner context" do
      item = MediaItem.from_map(%{"uuid" => "abc"}, owner_type: "posts")

      assert item.owner_type == "posts"
      assert is_nil(item.owner_id)
      assert is_nil(item.collection_name)
    end

    test "empty opts behaves like from_map/1" do
      item = MediaItem.from_map(%{"uuid" => "abc"}, [])

      assert item.uuid == "abc"
      assert is_nil(item.owner_type)
    end
  end

  describe "round-trip serialization" do
    test "to_map then from_map preserves all serialized data" do
      original = %MediaItem{
        uuid: "abc123",
        name: "photo",
        file_name: "photo.jpg",
        mime_type: "image/jpeg",
        disk: "s3",
        size: 999_999,
        checksum: "deadbeef",
        checksum_algorithm: "sha256",
        order: 3,
        custom_properties: %{"alt" => "sunset", "credit" => "me"},
        metadata: %{"width" => 1920, "height" => 1080},
        generated_conversions: %{"thumb" => true, "preview" => false},
        responsive_images: %{
          "original" => %{
            "variants" => [%{"width" => 320, "path" => "posts/123/abc/photo_320w.jpg"}]
          }
        },
        inserted_at: "2024-06-15T10:30:00Z"
      }

      restored = original |> MediaItem.to_map() |> MediaItem.from_map()

      assert restored.uuid == original.uuid
      assert restored.name == original.name
      assert restored.file_name == original.file_name
      assert restored.mime_type == original.mime_type
      assert restored.disk == original.disk
      assert restored.size == original.size
      assert restored.checksum == original.checksum
      assert restored.checksum_algorithm == original.checksum_algorithm
      assert restored.order == original.order
      assert restored.custom_properties == original.custom_properties
      assert restored.metadata == original.metadata
      assert restored.generated_conversions == original.generated_conversions
      assert restored.responsive_images == original.responsive_images
      assert restored.inserted_at == original.inserted_at
    end

    test "virtual fields are lost in round-trip" do
      original = %MediaItem{
        uuid: "abc",
        collection_name: "images",
        owner_type: "posts",
        owner_id: "123"
      }

      restored = original |> MediaItem.to_map() |> MediaItem.from_map()

      assert is_nil(restored.collection_name)
      assert is_nil(restored.owner_type)
      assert is_nil(restored.owner_id)
    end
  end

  describe "has_conversion?/2" do
    test "returns true for completed conversions" do
      item = %MediaItem{generated_conversions: %{"thumb" => true, "preview" => true}}

      assert MediaItem.has_conversion?(item, :thumb)
      assert MediaItem.has_conversion?(item, "thumb")
    end

    test "returns false for incomplete conversions" do
      item = %MediaItem{generated_conversions: %{"thumb" => false}}

      refute MediaItem.has_conversion?(item, :thumb)
    end

    test "returns false for missing conversions" do
      item = %MediaItem{generated_conversions: %{"thumb" => true}}

      refute MediaItem.has_conversion?(item, :banner)
    end

    test "returns false for empty conversions" do
      item = %MediaItem{generated_conversions: %{}}

      refute MediaItem.has_conversion?(item, :thumb)
    end
  end
end
