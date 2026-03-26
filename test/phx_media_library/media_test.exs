defmodule PhxMediaLibrary.MediaTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Media

  describe "has_conversion?/2" do
    test "returns true when conversion exists" do
      media = %Media{generated_conversions: %{"thumb" => true, "preview" => true}}

      assert Media.has_conversion?(media, :thumb)
      assert Media.has_conversion?(media, "thumb")
      assert Media.has_conversion?(media, :preview)
    end

    test "returns false when conversion does not exist" do
      media = %Media{generated_conversions: %{"thumb" => true}}

      refute Media.has_conversion?(media, :preview)
      refute Media.has_conversion?(media, :banner)
    end

    test "returns false when generated_conversions is empty" do
      media = %Media{generated_conversions: %{}}

      refute Media.has_conversion?(media, :thumb)
    end

    test "returns false when conversion value is false" do
      media = %Media{generated_conversions: %{"thumb" => false}}

      refute Media.has_conversion?(media, :thumb)
    end
  end

  describe "url/2" do
    test "generates URL for media" do
      media = %Media{
        uuid: "test-uuid-123",
        disk: "memory",
        collection_name: "images",
        name: "test-image",
        file_name: "test-image.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      url = Media.url(media)
      assert is_binary(url)
      assert url =~ "test-uuid-123"
    end

    test "generates URL for conversion" do
      media = %Media{
        uuid: "test-uuid-123",
        disk: "memory",
        collection_name: "images",
        name: "test-image",
        file_name: "test-image.jpg",
        mime_type: "image/jpeg",
        size: 1024,
        generated_conversions: %{"thumb" => true},
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      url = Media.url(media, :thumb)
      assert is_binary(url)
      assert url =~ "thumb"
    end
  end

  describe "srcset/2" do
    test "returns nil when no responsive images exist" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        responsive_images: %{},
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      assert Media.srcset(media) == nil
    end

    test "returns nil when conversion has no responsive images" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        responsive_images: %{
          "original" => [%{"width" => 320, "path" => "path/320.jpg"}]
        },
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      assert Media.srcset(media, :thumb) == nil
    end

    test "returns srcset string for original" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        responsive_images: %{
          "original" => [
            %{"width" => 320, "path" => "images/uuid/responsive/test-320.jpg"},
            %{"width" => 640, "path" => "images/uuid/responsive/test-640.jpg"}
          ]
        },
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      srcset = Media.srcset(media)
      assert is_binary(srcset)
      assert srcset =~ "320w"
      assert srcset =~ "640w"
    end

    test "returns srcset string for conversion" do
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        collection_name: "images",
        name: "test",
        file_name: "test.jpg",
        responsive_images: %{
          "thumb" => [
            %{"width" => 150, "path" => "images/uuid/responsive/thumb-150.jpg"},
            %{"width" => 300, "path" => "images/uuid/responsive/thumb-300.jpg"}
          ]
        },
        owner_type: "posts",
        owner_id: Ecto.UUID.generate()
      }

      srcset = Media.srcset(media, :thumb)
      assert is_binary(srcset)
      assert srcset =~ "150w"
      assert srcset =~ "300w"
    end
  end

  describe "struct" do
    test "has correct struct keys" do
      media = %Media{}

      assert Map.has_key?(media, :uuid)
      assert Map.has_key?(media, :collection_name)
      assert Map.has_key?(media, :name)
      assert Map.has_key?(media, :file_name)
      assert Map.has_key?(media, :mime_type)
      assert Map.has_key?(media, :disk)
      assert Map.has_key?(media, :size)
      assert Map.has_key?(media, :custom_properties)
      assert Map.has_key?(media, :generated_conversions)
      assert Map.has_key?(media, :responsive_images)
      assert Map.has_key?(media, :order)
      assert Map.has_key?(media, :owner_type)
      assert Map.has_key?(media, :owner_id)
      assert Map.has_key?(media, :checksum)
      assert Map.has_key?(media, :checksum_algorithm)
      assert Map.has_key?(media, :metadata)
      assert Map.has_key?(media, :inserted_at)
    end

    test "has default values" do
      media = %Media{}

      assert media.custom_properties == %{}
      assert media.generated_conversions == %{}
      assert media.responsive_images == %{}
      assert media.metadata == %{}
      assert media.checksum_algorithm == "sha256"
    end
  end

  describe "compute_checksum/2" do
    test "computes SHA-256 checksum by default" do
      content = "hello world"
      checksum = Media.compute_checksum(content)

      # known SHA-256 of "hello world"
      expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
      assert checksum == expected
    end

    test "computes SHA-256 checksum explicitly" do
      content = "test content"
      checksum = Media.compute_checksum(content, "sha256")

      assert is_binary(checksum)
      assert String.length(checksum) == 64
      assert String.match?(checksum, ~r/^[0-9a-f]+$/)
    end

    test "computes MD5 checksum" do
      content = "hello world"
      checksum = Media.compute_checksum(content, "md5")

      # known MD5 of "hello world"
      expected = "5eb63bbbe01eeed093cb22bb8f5acdc3"
      assert checksum == expected
    end

    test "computes SHA-1 checksum" do
      content = "hello world"
      checksum = Media.compute_checksum(content, "sha1")

      # known SHA-1 of "hello world"
      expected = "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed"
      assert checksum == expected
    end

    test "raises for unsupported algorithm" do
      assert_raise RuntimeError, ~r/Unsupported checksum algorithm/, fn ->
        Media.compute_checksum("data", "sha512")
      end
    end

    test "different content produces different checksums" do
      checksum_a = Media.compute_checksum("content A")
      checksum_b = Media.compute_checksum("content B")

      refute checksum_a == checksum_b
    end

    test "same content always produces the same checksum" do
      content = "reproducible"
      checksum_1 = Media.compute_checksum(content)
      checksum_2 = Media.compute_checksum(content)

      assert checksum_1 == checksum_2
    end

    test "handles empty binary" do
      checksum = Media.compute_checksum("")
      assert is_binary(checksum)
      assert String.length(checksum) == 64
    end

    test "handles large binary" do
      content = :crypto.strong_rand_bytes(1_000_000)
      checksum = Media.compute_checksum(content)

      assert is_binary(checksum)
      assert String.length(checksum) == 64
    end
  end

  describe "verify_integrity/1" do
    test "returns error when no checksum is stored" do
      media = %Media{checksum: nil, checksum_algorithm: "sha256"}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end

    test "returns error when no algorithm is stored" do
      media = %Media{checksum: "abc", checksum_algorithm: nil}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end
  end

  describe "delete_files/1" do
    test "accepts a Media struct" do
      # Basic smoke test - just ensure it doesn't crash with a valid struct
      media = %Media{
        uuid: "test-uuid",
        disk: "memory",
        owner_type: "posts",
        owner_id: "1",
        file_name: "test.jpg",
        generated_conversions: %{},
        responsive_images: %{}
      }

      assert :ok = Media.delete_files(media)
    end
  end

  describe "from_media_item/1 and to_media_item/1" do
    test "converts MediaItem to Media and back" do
      item = %PhxMediaLibrary.MediaItem{
        uuid: "test-uuid",
        name: "photo",
        file_name: "photo.jpg",
        mime_type: "image/jpeg",
        disk: "memory",
        size: 1024,
        owner_type: "posts",
        owner_id: "123"
      }

      media = Media.from_media_item(item)
      assert %Media{} = media
      assert media.uuid == "test-uuid"
      assert media.owner_type == "posts"

      back = Media.to_media_item(media)
      assert %PhxMediaLibrary.MediaItem{} = back
      assert back.uuid == "test-uuid"
    end
  end
end
