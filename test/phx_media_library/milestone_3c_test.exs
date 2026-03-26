defmodule PhxMediaLibrary.Milestone3cTest do
  @moduledoc """
  Tests for Milestone 3c — Streaming Uploads and Presigned Upload API.

  Soft delete tests have been removed as media-level soft deletes no longer
  exist in the JSONB approach.

  Split into two major describe blocks matching the sub-milestones:
    3.6 — Streaming Upload Support
    3.7 — Direct S3 Upload (Presigned URLs)
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.Config
  alias PhxMediaLibrary.PathGenerator
  alias PhxMediaLibrary.Storage
  alias PhxMediaLibrary.StorageWrapper

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_post!(attrs \\ %{}) do
    default = %{title: "Test Post"}
    merged = Map.merge(default, attrs)

    %PhxMediaLibrary.TestPost{}
    |> Ecto.Changeset.change(Map.take(merged, [:title]))
    |> TestRepo.insert!()
  end

  defp create_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "m3c_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp setup_disk_storage(_context) do
    dir = Path.join(System.tmp_dir!(), "phx_media_m3c_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_disks = Application.get_env(:phx_media_library, :disks)
    original_default_disk = Application.get_env(:phx_media_library, :default_disk)

    Application.put_env(:phx_media_library, :disks,
      local: [
        adapter: Storage.Disk,
        root: dir,
        base_url: "/test-uploads"
      ],
      memory: [
        adapter: Storage.Memory,
        base_url: "/test-uploads"
      ]
    )

    Application.put_env(:phx_media_library, :default_disk, :local)
    Storage.Memory.clear()

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)

      if original_default_disk do
        Application.put_env(:phx_media_library, :default_disk, original_default_disk)
      else
        Application.delete_env(:phx_media_library, :default_disk)
      end

      File.rm_rf!(dir)
    end)

    %{storage_dir: dir}
  end

  defp add_media_to_post!(post, collection, filename, content) do
    path = create_temp_file(content, filename)

    {:ok, media} =
      post
      |> PhxMediaLibrary.add(path)
      |> PhxMediaLibrary.to_collection(collection)

    media
  end

  # =========================================================================
  # 3.6 — Streaming Upload Support
  # =========================================================================

  describe "streaming: file is not loaded entirely into memory" do
    setup [:setup_disk_storage]

    test "adds media successfully with streaming pipeline" do
      post = create_post!()
      content = String.duplicate("streaming test data\n", 1000)
      path = create_temp_file(content, "stream_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert String.ends_with?(media.file_name, "stream_test.txt")
      assert media.size == byte_size(content)
    end

    test "checksum is correctly computed during streaming" do
      post = create_post!()
      content = "checksum test content for streaming"
      path = create_temp_file(content, "checksum_stream.txt")

      expected_checksum =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.checksum == expected_checksum
      assert media.checksum_algorithm == "sha256"
    end

    test "checksum matches verify_integrity for streamed upload" do
      post = create_post!()
      content = "integrity check streaming"
      path = create_temp_file(content, "integrity_stream.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert :ok = PhxMediaLibrary.verify_integrity(media)
    end

    test "large file is handled correctly" do
      post = create_post!()
      # Create a ~500KB file (larger than the 64KB stream chunk size)
      content = :crypto.strong_rand_bytes(500_000)
      path = create_temp_file(content, "large_file.bin")

      expected_checksum =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.size == 500_000
      assert media.checksum == expected_checksum
      assert :ok = PhxMediaLibrary.verify_integrity(media)
    end

    test "empty file is handled correctly" do
      post = create_post!()
      path = create_temp_file("", "empty.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      expected_checksum =
        :crypto.hash(:sha256, "")
        |> Base.encode16(case: :lower)

      assert media.size == 0
      assert media.checksum == expected_checksum
    end

    test "stored file content matches original for streamed upload" do
      post = create_post!()
      content = "verify stored content matches original"
      path = create_temp_file(content, "verify_content.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      storage = Config.storage_adapter(media.disk)
      storage_path = PathGenerator.relative_path(media, nil)
      {:ok, stored_content} = StorageWrapper.get(storage, storage_path)

      assert stored_content == content
    end

    test "multiple sequential uploads produce correct checksums" do
      post = create_post!()

      results =
        for i <- 1..5 do
          content = "file number #{i} with unique content #{:rand.uniform(1_000_000)}"
          path = create_temp_file(content, "multi_#{i}.txt")

          expected =
            :crypto.hash(:sha256, content)
            |> Base.encode16(case: :lower)

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.to_collection(:images)

          {media.checksum, expected}
        end

      for {actual, expected} <- results do
        assert actual == expected
      end
    end
  end

  describe "streaming: MIME detection uses header bytes only" do
    setup [:setup_disk_storage]

    test "detects PNG from header bytes without reading entire file" do
      post = create_post!()
      # Create a PNG-like file: valid PNG header + large body
      png_header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

      body = :crypto.strong_rand_bytes(100_000)
      content = png_header <> body
      path = create_temp_file(content, "test.png")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/png"
    end

    test "detects JPEG from header bytes" do
      post = create_post!()
      jpeg_header = <<0xFF, 0xD8, 0xFF, 0xE0>>
      content = jpeg_header <> :crypto.strong_rand_bytes(50_000)
      path = create_temp_file(content, "test.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/jpeg"
    end

    test "falls back to extension when content doesn't match known signatures" do
      post = create_post!()
      content = "just plain text content"
      path = create_temp_file(content, "readme.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "text/plain"
    end
  end

  describe "streaming: with memory storage adapter" do
    setup [:setup_disk_storage]

    test "streams to memory storage correctly" do
      Storage.Memory.clear()
      Application.put_env(:phx_media_library, :default_disk, :memory)

      post = create_post!()
      content = String.duplicate("memory stream ", 5000)
      path = create_temp_file(content, "mem_stream.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Verify content was stored
      storage = Config.storage_adapter("memory")
      storage_path = PathGenerator.relative_path(media, nil)
      {:ok, stored} = StorageWrapper.get(storage, storage_path)

      assert stored == content

      # Reset immediately so subsequent tests aren't affected
      Application.put_env(:phx_media_library, :default_disk, :local)
    end
  end

  describe "streaming: metadata extraction still works" do
    setup [:setup_disk_storage]

    test "metadata is extracted alongside streaming" do
      post = create_post!()
      content = "metadata test"
      path = create_temp_file(content, "meta.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Metadata should be populated (at minimum, extracted_at)
      assert is_map(media.metadata)
    end

    test "without_metadata still works with streaming" do
      post = create_post!()
      content = "no metadata test"
      path = create_temp_file(content, "nometa.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.without_metadata()
        |> PhxMediaLibrary.to_collection(:images)

      assert media.metadata == %{}
    end
  end

  # =========================================================================
  # 3.7 — Direct S3 Upload (Presigned URLs)
  # =========================================================================

  describe "presigned uploads: presigned_upload_url/3" do
    setup [:setup_disk_storage]

    test "returns :not_supported for local disk adapter" do
      post = create_post!()

      result =
        PhxMediaLibrary.presigned_upload_url(post, :images, filename: "photo.jpg")

      assert {:error, :not_supported} = result
    end

    test "returns :not_supported for memory adapter" do
      Application.put_env(:phx_media_library, :default_disk, :memory)

      post = create_post!()

      result =
        PhxMediaLibrary.presigned_upload_url(post, :images, filename: "photo.jpg")

      assert {:error, :not_supported} = result
    after
      Application.put_env(:phx_media_library, :default_disk, :local)
    end

    test "raises when :filename option is missing" do
      post = create_post!()

      assert_raise KeyError, ~r/key :filename not found/, fn ->
        PhxMediaLibrary.presigned_upload_url(post, :images, [])
      end
    end
  end

  describe "presigned uploads: complete_external_upload/4" do
    setup [:setup_disk_storage]

    test "creates a media record from external upload metadata" do
      post = create_post!()

      # Simulate a completed external upload — the file is already in storage,
      # we just need to create the record.
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/photo.jpg"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 45_000
        )

      assert media.file_name == "photo.jpg"
      assert media.mime_type == "image/jpeg"
      assert media.size == 45_000
      assert media.collection_name == "images"
      assert media.owner_id == to_string(post.id)
    end

    test "stores custom properties" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/doc.pdf"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "doc.pdf",
          content_type: "application/pdf",
          size: 100_000,
          custom_properties: %{"description" => "My document"}
        )

      assert media.custom_properties == %{"description" => "My document"}
    end

    test "stores pre-computed checksum" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/hashed.txt"
      checksum = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "hashed.txt",
          content_type: "text/plain",
          size: 42,
          checksum: checksum,
          checksum_algorithm: "sha256"
        )

      assert media.checksum == checksum
      assert media.checksum_algorithm == "sha256"
    end

    test "creates record without checksum when not provided" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/nochecksum.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "nochecksum.txt",
          content_type: "text/plain",
          size: 10
        )

      assert is_nil(media.checksum)
    end

    test "extracts UUID from storage path" do
      post = create_post!()
      uuid = Ecto.UUID.generate()
      storage_path = "posts/#{post.id}/#{uuid}/photo.jpg"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 1000
        )

      assert media.uuid == uuid
    end

    test "assigns correct order" do
      post = create_post!()
      _m1 = add_media_to_post!(post, :images, "first.txt", "first")

      # Reload to get updated JSONB
      post = PhxMediaLibrary.TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/second.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "second.txt",
          content_type: "text/plain",
          size: 100
        )

      assert media.order == 1
    end

    test "metadata defaults to empty map" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/test.txt"

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          content_type: "text/plain",
          size: 5
        )

      assert media.metadata == %{}
    end

    test "raises when required options are missing" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/test.txt"

      assert_raise KeyError, ~r/key :filename not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          content_type: "text/plain",
          size: 5
        )
      end

      assert_raise KeyError, ~r/key :content_type not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          size: 5
        )
      end

      assert_raise KeyError, ~r/key :size not found/, fn ->
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "test.txt",
          content_type: "text/plain"
        )
      end
    end

    test "emits telemetry events" do
      post = create_post!()
      storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/telem.txt"

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-external-add-#{inspect(ref)}",
        [:phx_media_library, :add, :stop],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, :add_stop, metadata})
        end,
        nil
      )

      {:ok, _media} =
        PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
          filename: "telem.txt",
          content_type: "text/plain",
          size: 10
        )

      assert_receive {:telemetry, :add_stop, metadata}
      assert metadata.collection == :images
      assert metadata.source_type == :external
    after
      :telemetry.detach("test-external-add-#{inspect(make_ref())}")
    end
  end

  # =========================================================================
  # Storage behaviour: presigned_upload_url callback
  # =========================================================================

  describe "storage behaviour: presigned_upload_url/3 optional callback" do
    test "Disk adapter does not export presigned_upload_url/3" do
      Code.ensure_loaded(Storage.Disk)
      refute function_exported?(Storage.Disk, :presigned_upload_url, 3)
    end

    test "Memory adapter does not export presigned_upload_url/3" do
      Code.ensure_loaded(Storage.Memory)
      refute function_exported?(Storage.Memory, :presigned_upload_url, 3)
    end

    test "S3 adapter exports presigned_upload_url/3" do
      Code.ensure_loaded(Storage.S3)
      assert function_exported?(Storage.S3, :presigned_upload_url, 3)
    end
  end

  describe "storage wrapper: presigned_upload_url/3" do
    test "returns {:error, :not_supported} for adapters without the callback" do
      storage = %StorageWrapper{
        adapter: Storage.Memory,
        config: [base_url: "/test"]
      }

      assert {:error, :not_supported} =
               StorageWrapper.presigned_upload_url(storage, "test/path.txt")
    end
  end
end
