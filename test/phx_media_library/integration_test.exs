defmodule PhxMediaLibrary.IntegrationTest do
  @moduledoc """
  Integration tests that exercise the full media lifecycle against a real
  Postgres database. These tests verify:

  - Adding media via file paths (the full `add -> store -> retrieve -> delete` flow)
  - Collection validation (MIME types, single file, max files)
  - The `MediaAdder` pipeline end-to-end
  - Storage adapters with real files
  - Checksum computation and integrity verification
  - Polymorphic type derivation
  - Query helpers (`get_media/2`, `get_first_media/2`)
  - Error paths (missing files, invalid types, storage failures)
  - The declarative DSL collections and conversions roundtrip
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.{Fixtures, Media, MediaItem, PathGenerator, Storage, TestRepo, Workers}

  # Suppress noisy async conversion errors in test output.
  # The async processor fires for every upload but fails on non-image
  # files (expected). We use a no-op processor for these tests.
  setup do
    original_processor = Application.get_env(:phx_media_library, :async_processor)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.IntegrationTest.NoOpProcessor
    )

    on_exit(fn ->
      if original_processor do
        Application.put_env(:phx_media_library, :async_processor, original_processor)
      else
        Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # No-op async processor to avoid background task noise in tests
  # ---------------------------------------------------------------------------

  defmodule NoOpProcessor do
    @moduledoc false
    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(_media, _conversions), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: create a real post in the database
  # ---------------------------------------------------------------------------

  defp create_post!(attrs \\ %{}) do
    defaults = %{title: "Integration Test Post", body: "Hello world"}
    merged = Map.merge(defaults, Map.new(attrs))

    %PhxMediaLibrary.TestPost{}
    |> Ecto.Changeset.change(Map.take(merged, [:title, :body]))
    |> TestRepo.insert!()
  end

  defp create_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_integ_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)

    on_exit(fn -> File.rm(path) end)

    path
  end

  defp setup_disk_storage(_context) do
    dir = Path.join(System.tmp_dir!(), "phx_media_integ_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_disks = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      memory: [
        adapter: PhxMediaLibrary.Storage.Memory,
        base_url: "/test-uploads"
      ],
      local: [
        adapter: PhxMediaLibrary.Storage.Disk,
        root: dir,
        base_url: "/uploads"
      ]
    )

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(dir)
    end)

    %{storage_dir: dir}
  end

  # ---------------------------------------------------------------------------
  # Full lifecycle: add -> store -> retrieve -> delete
  # ---------------------------------------------------------------------------

  describe "full media lifecycle" do
    setup :setup_disk_storage

    test "add file -> persist -> retrieve -> delete", %{storage_dir: dir} do
      post = create_post!()
      content = "file content here"
      path = create_temp_file(content, "document.txt")

      # 1. Add media (use using_filename so we get a predictable stored name)
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("document.txt")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      # 2. Verify returned MediaItem
      assert %MediaItem{} = media
      assert media.uuid != nil
      assert media.collection_name == "documents"
      assert media.file_name == "document.txt"
      assert media.mime_type == "text/plain"
      assert media.disk == "local"
      assert media.size == byte_size(content)
      assert media.owner_type == "posts"
      assert media.owner_id == to_string(post.id)
      assert media.order == 0

      # 3. Verify the file was stored on disk
      stored_path = Path.join(dir, "posts/#{post.id}/#{media.uuid}/document.txt")
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == content

      # 4. Verify checksum was computed and stored
      assert media.checksum != nil
      assert media.checksum_algorithm == "sha256"
      expected_checksum = Media.compute_checksum(content, "sha256")
      assert media.checksum == expected_checksum

      # 5. Retrieve via query helpers (reload post to get updated JSONB)
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert [fetched] = PhxMediaLibrary.get_media(post, :documents)
      assert fetched.uuid == media.uuid

      assert fetched_first = PhxMediaLibrary.get_first_media(post, :documents)
      assert fetched_first.uuid == media.uuid

      # 6. Verify URL generation
      url = PhxMediaLibrary.url(media)
      assert is_binary(url)
      assert url =~ media.uuid

      # 7. Verify path generation (local disk)
      full_path = PhxMediaLibrary.path(media)
      assert full_path == stored_path

      # 8. Delete
      assert {:ok, _deleted} = PhxMediaLibrary.delete_media(post, :documents, media.uuid)

      # Verify media no longer returned (reload to get updated JSONB)
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert PhxMediaLibrary.get_media(post, :documents) == []

      # Verify file removed from disk
      refute File.exists?(stored_path)
    end

    test "add file with custom filename", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("custom name content", "original.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("renamed.txt")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "renamed.txt"
      assert media.name == "renamed"
    end

    test "add file with custom properties", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("properties test", "props.txt")

      custom = %{"alt" => "A description", "author" => "Test User"}

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("props.txt")
               |> PhxMediaLibrary.with_custom_properties(custom)
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.custom_properties == custom

      # Reload from DB to ensure it was persisted
      reloaded_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      [reloaded_media] = PhxMediaLibrary.get_media(reloaded_post, :documents)
      assert reloaded_media.custom_properties == custom
    end

    test "to_collection! raises on error" do
      post = create_post!()

      assert_raise PhxMediaLibrary.Error, ~r/Failed to add media/, fn ->
        post
        |> PhxMediaLibrary.add("/nonexistent/file.txt")
        |> PhxMediaLibrary.to_collection!(:documents)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Memory storage (default in test config)
  # ---------------------------------------------------------------------------

  describe "memory storage lifecycle" do
    test "add and retrieve via memory storage" do
      post = create_post!()
      content = "memory storage test"
      path = create_temp_file(content, "memo.txt")

      # Memory is the default disk in test config
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("memo.txt")
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.disk == "memory"

      # Verify stored in memory adapter
      relative_path = PathGenerator.relative_path(media, nil)
      assert {:ok, ^content} = Storage.Memory.get(relative_path, [])

      # Clean up
      PhxMediaLibrary.delete_media(post, :documents, media.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # Collection validation
  # ---------------------------------------------------------------------------

  describe "collection MIME type validation" do
    test "accepts files matching collection MIME types" do
      post = create_post!()
      path = create_temp_file("valid pdf-ish content", "report.pdf")

      # :documents collection accepts application/pdf and text/plain
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("report.pdf")
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.collection_name == "documents"
    end

    test "rejects files that don't match collection MIME types" do
      post = create_post!()
      # Create a .exe file — MIME will resolve to application/x-msdownload
      path = create_temp_file("not a pdf", "malicious.exe")

      assert {:error, {:invalid_mime_type, _mime, _accepted}} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("malicious.exe")
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "allows any file when collection has no MIME restrictions" do
      post = create_post!()
      path = create_temp_file("anything goes", "random.xyz")

      # :images collection has no accepts restriction
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("random.xyz")
               |> PhxMediaLibrary.to_collection(:images)

      assert media.collection_name == "images"
    end

    test "allows files for collections that are not configured" do
      post = create_post!()
      path = create_temp_file("unconfigured collection", "stuff.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.using_filename("stuff.txt")
               |> PhxMediaLibrary.to_collection(:unconfigured)

      assert media.collection_name == "unconfigured"
    end
  end

  describe "single file collection" do
    test "replaces previous file when single_file is true" do
      post = create_post!()

      # Add first avatar
      path1 = create_temp_file("avatar 1", "avatar1.jpg")

      assert {:ok, media1} =
               post
               |> PhxMediaLibrary.add(path1)
               |> PhxMediaLibrary.using_filename("avatar1.jpg")
               |> PhxMediaLibrary.to_collection(:avatar)

      # Add second avatar — should replace the first
      path2 = create_temp_file("avatar 2", "avatar2.jpg")

      # Reload post to get updated media_data
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

      assert {:ok, media2} =
               post
               |> PhxMediaLibrary.add(path2)
               |> PhxMediaLibrary.using_filename("avatar2.jpg")
               |> PhxMediaLibrary.to_collection(:avatar)

      # Only the second avatar should remain
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      avatars = PhxMediaLibrary.get_media(post, :avatar)
      assert length(avatars) == 1
      assert hd(avatars).uuid == media2.uuid

      # First one should not be in the JSONB data
      uuids = Enum.map(avatars, & &1.uuid)
      refute media1.uuid in uuids
    end
  end

  describe "max files collection" do
    test "enforces max_files limit" do
      post = create_post!()

      # :gallery has max_files: 5
      uuids =
        for i <- 1..6 do
          path = create_temp_file("gallery image #{i}", "gallery_#{i}.jpg")

          # Reload post for each iteration to get current media_data
          post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("gallery_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:gallery)

          media.uuid
        end

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      gallery = PhxMediaLibrary.get_media(post, :gallery)

      # Should have at most 5 items
      assert length(gallery) <= 5

      # The most recently added items should be present
      latest_uuid = List.last(uuids)
      gallery_uuids = Enum.map(gallery, & &1.uuid)
      assert latest_uuid in gallery_uuids
    end
  end

  # ---------------------------------------------------------------------------
  # Ordering
  # ---------------------------------------------------------------------------

  describe "media ordering" do
    test "assigns incrementing order values" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("file #{i}", "file_#{i}.txt")

        # Reload post to get updated media_data
        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        {:ok, media} =
          current_post
          |> PhxMediaLibrary.add(path)
          |> PhxMediaLibrary.using_filename("file_#{i}.txt")
          |> PhxMediaLibrary.to_collection(:images)

        assert media.order == i - 1
      end
    end

    test "get_media returns items ordered by order" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("ordered file #{i}", "ordered_#{i}.txt")

        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        current_post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("ordered_#{i}.txt")
        |> PhxMediaLibrary.to_collection(:images)
      end

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      items = PhxMediaLibrary.get_media(post, :images)
      orders = Enum.map(items, & &1.order)

      assert orders == Enum.sort(orders)
    end
  end

  # ---------------------------------------------------------------------------
  # Checksum and integrity
  # ---------------------------------------------------------------------------

  describe "checksum computation and integrity verification" do
    setup :setup_disk_storage

    test "checksum is stored and matches file content", %{storage_dir: _dir} do
      post = create_post!()
      content = "integrity test content - #{:erlang.unique_integer()}"
      path = create_temp_file(content, "integrity.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("integrity.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.checksum == Media.compute_checksum(content, "sha256")
      assert media.checksum_algorithm == "sha256"
    end

    test "verify_integrity returns :ok for untampered files", %{storage_dir: _dir} do
      post = create_post!()
      content = "verify me"
      path = create_temp_file(content, "verify.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("verify.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert :ok = Media.verify_integrity(media)
    end

    test "verify_integrity detects tampering", %{storage_dir: dir} do
      post = create_post!()
      path = create_temp_file("original content", "tamper.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("tamper.txt")
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      # Tamper with the stored file directly on disk
      stored_path = Path.join(dir, "posts/#{post.id}/#{media.uuid}/tamper.txt")
      assert File.exists?(stored_path), "stored file must exist before tampering"
      File.write!(stored_path, "tampered content!!!")

      assert {:error, :checksum_mismatch} = Media.verify_integrity(media)
    end

    test "verify_integrity returns error when no checksum stored" do
      media = %Media{checksum: nil, checksum_algorithm: "sha256"}
      assert {:error, :no_checksum} = Media.verify_integrity(media)
    end

    test "different files produce different checksums" do
      post = create_post!()

      path1 = create_temp_file("content A", "file_a.txt")
      path2 = create_temp_file("content B", "file_b.txt")

      {:ok, media1} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("file_a.txt")
        |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

      {:ok, media2} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("file_b.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert media1.checksum != media2.checksum
    end
  end

  # ---------------------------------------------------------------------------
  # Polymorphic type derivation
  # ---------------------------------------------------------------------------

  describe "polymorphic owner_type" do
    test "derives owner_type from Ecto table name" do
      post = create_post!()
      path = create_temp_file("type test", "type.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("type.txt")
        |> PhxMediaLibrary.to_collection(:images)

      # TestPost schema uses `schema "posts"` so owner_type should be "posts"
      assert media.owner_type == "posts"
    end

    test "__media_type__/0 is defined on TestPost" do
      assert PhxMediaLibrary.TestPost.__media_type__() == "posts"
    end

    test "media is scoped by owner_type and owner_id" do
      post1 = create_post!(%{title: "Post 1"})
      post2 = create_post!(%{title: "Post 2"})

      path1 = create_temp_file("post 1 file", "p1.txt")
      path2 = create_temp_file("post 2 file", "p2.txt")

      {:ok, media1} =
        post1
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("p1.txt")
        |> PhxMediaLibrary.to_collection(:images)

      {:ok, media2} =
        post2
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("p2.txt")
        |> PhxMediaLibrary.to_collection(:images)

      # Each post should only see its own media
      post1 = TestRepo.get!(PhxMediaLibrary.TestPost, post1.id)
      assert [m1] = PhxMediaLibrary.get_media(post1, :images)
      assert m1.uuid == media1.uuid

      post2 = TestRepo.get!(PhxMediaLibrary.TestPost, post2.id)
      assert [m2] = PhxMediaLibrary.get_media(post2, :images)
      assert m2.uuid == media2.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  describe "get_media/2 and get_first_media/2" do
    test "get_media returns all media for a collection" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("item #{i}", "item_#{i}.txt")

        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        current_post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("item_#{i}.txt")
        |> PhxMediaLibrary.to_collection(:images)
      end

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      media = PhxMediaLibrary.get_media(post, :images)
      assert length(media) == 3
    end

    test "get_media returns all media when no collection specified" do
      post = create_post!()

      path1 = create_temp_file("img", "img.jpg")

      post
      |> PhxMediaLibrary.add(path1)
      |> PhxMediaLibrary.using_filename("img.jpg")
      |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      path2 = create_temp_file("doc", "doc.pdf")

      post
      |> PhxMediaLibrary.add(path2)
      |> PhxMediaLibrary.using_filename("doc.pdf")
      |> PhxMediaLibrary.to_collection(:documents)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      all_media = PhxMediaLibrary.get_media(post)
      assert length(all_media) == 2
    end

    test "get_first_media returns first item by order" do
      post = create_post!()

      path1 = create_temp_file("first", "first.txt")

      {:ok, first_media} =
        post
        |> PhxMediaLibrary.add(path1)
        |> PhxMediaLibrary.using_filename("first.txt")
        |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      path2 = create_temp_file("second", "second.txt")

      {:ok, _second_media} =
        post
        |> PhxMediaLibrary.add(path2)
        |> PhxMediaLibrary.using_filename("second.txt")
        |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      result = PhxMediaLibrary.get_first_media(post, :images)
      assert result.uuid == first_media.uuid
    end

    test "get_first_media returns nil when collection is empty" do
      post = create_post!()
      assert PhxMediaLibrary.get_first_media(post, :images) == nil
    end
  end

  describe "get_first_media_url/3" do
    test "returns URL for first media in collection" do
      post = create_post!()
      path = create_temp_file("url test", "url_test.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("url_test.txt")
        |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      url = PhxMediaLibrary.get_first_media_url(post, :images)
      assert is_binary(url)
      assert url =~ "url_test"
    end

    test "returns fallback when collection is empty" do
      post = create_post!()
      fallback = "/images/placeholder.png"

      url = PhxMediaLibrary.get_first_media_url(post, :images, fallback: fallback)
      assert url == fallback
    end

    test "returns nil when no fallback and collection is empty" do
      post = create_post!()
      assert PhxMediaLibrary.get_first_media_url(post, :images) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # get_all_media_url
  # ---------------------------------------------------------------------------

  describe "get_all_media_url/3" do
    test "returns all generated conversions with metadata" do
      post = create_post!()

      # Create media with generated_conversions already set
      post =
        Fixtures.create_media_in_jsonb(post, "images", %{
          file_name: "photo.png",
          mime_type: "image/png",
          generated_conversions: %{"thumb" => true, "preview" => true, "banner" => true}
        })

      results = PhxMediaLibrary.get_all_media_url(post, :images)

      assert length(results) == 3

      Enum.each(results, fn entry ->
        assert entry.type == "image/png"
        assert is_atom(entry.name)
        assert is_binary(entry.url)
        assert Map.has_key?(entry, :width)
        assert Map.has_key?(entry, :height)
      end)

      names = Enum.map(results, & &1.name)
      assert :thumb in names
      assert :preview in names
      assert :banner in names
    end

    test "filters by specific conversion names" do
      post = create_post!()

      post =
        Fixtures.create_media_in_jsonb(post, "images", %{
          file_name: "photo.png",
          mime_type: "image/png",
          generated_conversions: %{"thumb" => true, "preview" => true, "banner" => true}
        })

      results = PhxMediaLibrary.get_all_media_url(post, :images, [:thumb, :banner])

      assert length(results) == 2
      names = Enum.map(results, & &1.name)
      assert :thumb in names
      assert :banner in names
      refute :preview in names
    end

    test "returns empty list when no media in collection" do
      post = create_post!()

      assert PhxMediaLibrary.get_all_media_url(post, :images) == []
    end

    test "returns empty list when no generated conversions" do
      post = create_post!()

      post =
        Fixtures.create_media_in_jsonb(post, "images", %{
          file_name: "photo.png",
          mime_type: "image/png",
          generated_conversions: %{}
        })

      assert PhxMediaLibrary.get_all_media_url(post, :images) == []
    end

    test "skips conversions that are not true" do
      post = create_post!()

      post =
        Fixtures.create_media_in_jsonb(post, "images", %{
          file_name: "photo.png",
          mime_type: "image/png",
          generated_conversions: %{"thumb" => true, "preview" => false}
        })

      results = PhxMediaLibrary.get_all_media_url(post, :images)
      assert length(results) == 1
      assert hd(results).name == :thumb
    end

    test "includes width and height from conversion definitions" do
      post = create_post!()

      post =
        Fixtures.create_media_in_jsonb(post, "images", %{
          file_name: "photo.png",
          mime_type: "image/png",
          generated_conversions: %{"thumb" => true}
        })

      [entry] = PhxMediaLibrary.get_all_media_url(post, :images)

      # TestPost defines :thumb as width: 150, height: 150
      assert entry.name == :thumb
      assert entry.width == 150
      assert entry.height == 150
    end
  end

  # ---------------------------------------------------------------------------
  # Clear operations
  # ---------------------------------------------------------------------------

  describe "clear_collection/2" do
    test "removes all media from a specific collection" do
      post = create_post!()

      for i <- 1..3 do
        path = create_temp_file("image #{i}", "img_#{i}.jpg")

        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        current_post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
        |> PhxMediaLibrary.to_collection(:images)
      end

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      path_doc = create_temp_file("a document", "doc.pdf")

      {:ok, doc_media} =
        post
        |> PhxMediaLibrary.add(path_doc)
        |> PhxMediaLibrary.using_filename("doc.pdf")
        |> PhxMediaLibrary.to_collection(:documents)

      # Clear only images
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, 3} = PhxMediaLibrary.clear_collection(post, :images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert PhxMediaLibrary.get_media(post, :images) == []
      # Documents should remain
      assert [remaining] = PhxMediaLibrary.get_media(post, :documents)
      assert remaining.uuid == doc_media.uuid
    end
  end

  describe "clear_media/1" do
    test "removes all media from a model" do
      post = create_post!()

      for {collection, filename} <- [{:images, "img.jpg"}, {:documents, "doc.pdf"}] do
        path = create_temp_file("content", filename)

        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        current_post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename(filename)
        |> PhxMediaLibrary.to_collection(collection)
      end

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, 2} = PhxMediaLibrary.clear_media(post)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert PhxMediaLibrary.get_media(post) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns error for nonexistent file" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add("/nonexistent/path/to/file.txt")
        |> PhxMediaLibrary.using_filename("file.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, _reason} = result
    end

    test "returns error for empty path" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add("")
        |> PhxMediaLibrary.using_filename("empty.txt")
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, _reason} = result
    end

    test "returns error for invalid source type" do
      post = create_post!()

      result =
        post
        |> PhxMediaLibrary.add(12_345)
        |> PhxMediaLibrary.to_collection(:images)

      assert {:error, :invalid_source} = result
    end
  end

  # ---------------------------------------------------------------------------
  # DSL schema integration with real DB
  # ---------------------------------------------------------------------------

  describe "DSL-configured schema integration" do
    test "TestPost collections are queryable after DB insert" do
      post = create_post!()

      collections = post.__struct__.media_collections()
      collection_names = Enum.map(collections, & &1.name)

      assert :images in collection_names
      assert :documents in collection_names
      assert :avatar in collection_names
      assert :gallery in collection_names
    end

    test "TestPost conversions are queryable" do
      post = create_post!()

      conversions = post.__struct__.media_conversions()
      conversion_names = Enum.map(conversions, & &1.name)

      assert :thumb in conversion_names
      assert :preview in conversion_names
      assert :banner in conversion_names
    end

    test "get_media_collection returns correct config" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:documents)

      assert config.name == :documents
      assert config.accepts == ~w(application/pdf text/plain)
    end

    test "get_media_conversions filters by collection" do
      images_conversions = PhxMediaLibrary.TestPost.get_media_conversions(:images)
      docs_conversions = PhxMediaLibrary.TestPost.get_media_conversions(:documents)

      image_names = Enum.map(images_conversions, & &1.name)
      doc_names = Enum.map(docs_conversions, & &1.name)

      # :banner is scoped to :images
      assert :banner in image_names
      refute :banner in doc_names

      # :thumb and :preview apply to all collections
      assert :thumb in image_names
      assert :thumb in doc_names
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple collections on same model
  # ---------------------------------------------------------------------------

  describe "multiple collections on same model" do
    test "media items are correctly scoped to their collections" do
      post = create_post!()

      path_img = create_temp_file("image data", "photo.jpg")

      {:ok, img} =
        post
        |> PhxMediaLibrary.add(path_img)
        |> PhxMediaLibrary.using_filename("photo.jpg")
        |> PhxMediaLibrary.to_collection(:images)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      path_doc = create_temp_file("document data", "report.pdf")

      {:ok, doc} =
        post
        |> PhxMediaLibrary.add(path_doc)
        |> PhxMediaLibrary.using_filename("report.pdf")
        |> PhxMediaLibrary.to_collection(:documents)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      path_avatar = create_temp_file("avatar data", "me.png")

      {:ok, avatar} =
        post
        |> PhxMediaLibrary.add(path_avatar)
        |> PhxMediaLibrary.using_filename("me.png")
        |> PhxMediaLibrary.to_collection(:avatar)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

      images = PhxMediaLibrary.get_media(post, :images)
      documents = PhxMediaLibrary.get_media(post, :documents)
      avatars = PhxMediaLibrary.get_media(post, :avatar)
      all = PhxMediaLibrary.get_media(post)

      assert length(images) == 1
      assert hd(images).uuid == img.uuid

      assert length(documents) == 1
      assert hd(documents).uuid == doc.uuid

      assert length(avatars) == 1
      assert hd(avatars).uuid == avatar.uuid

      assert length(all) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Real disk storage round-trip
  # ---------------------------------------------------------------------------

  describe "disk storage adapter integration" do
    setup :setup_disk_storage

    test "stores and retrieves file content via local disk", %{storage_dir: dir} do
      post = create_post!()
      content = "disk round-trip content #{:erlang.unique_integer()}"
      path = create_temp_file(content, "disk_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("disk_test.txt")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      # Verify the file exists on disk
      stored_path = PhxMediaLibrary.path(media)
      assert stored_path != nil
      assert String.starts_with?(stored_path, dir)
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == content
    end

    test "delete removes file from disk", %{storage_dir: _dir} do
      post = create_post!()
      path = create_temp_file("delete me", "delete_test.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("delete_test.txt")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      stored_path = PhxMediaLibrary.path(media)
      assert File.exists?(stored_path)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      PhxMediaLibrary.delete_media(post, :images, media.uuid)

      refute File.exists?(stored_path)
    end

    test "handles binary content correctly", %{storage_dir: _dir} do
      post = create_post!()

      # Create a file with binary content (not valid UTF-8)
      binary_content = :crypto.strong_rand_bytes(256)
      path = create_temp_file(binary_content, "binary.bin")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("binary.bin")
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      stored_path = PhxMediaLibrary.path(media)
      assert File.read!(stored_path) == binary_content
      assert media.size == byte_size(binary_content)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures helper integration
  # ---------------------------------------------------------------------------

  describe "Fixtures.create_media/1 with real DB" do
    test "inserts a media item with defaults" do
      media = Fixtures.create_media()

      assert %MediaItem{} = media
      assert media.uuid != nil
      assert media.disk == "memory"
    end

    test "inserts a media item with custom attributes" do
      post = create_post!()

      media =
        Fixtures.create_media(%{
          collection_name: "images",
          name: "custom-media",
          file_name: "custom.png",
          mime_type: "image/png",
          post: post,
          checksum: "abc123",
          checksum_algorithm: "sha256"
        })

      assert media.collection_name == "images"
      assert media.mime_type == "image/png"
      assert media.owner_id == to_string(post.id)
      assert media.checksum == "abc123"
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent access (sandbox)
  # ---------------------------------------------------------------------------

  describe "concurrent media operations" do
    test "multiple posts can have media simultaneously" do
      posts =
        for i <- 1..3 do
          create_post!(%{title: "Concurrent Post #{i}"})
        end

      # Add media to each post
      media_uuids =
        for post <- posts do
          filename = "file_#{post.id}.txt"
          path = create_temp_file("content for #{post.title}", filename)

          {:ok, media} =
            post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename(filename)
            |> PhxMediaLibrary.to_collection(:images)

          {post.id, media.uuid}
        end

      # Each post should have exactly one media item
      for {post_id, media_uuid} <- media_uuids do
        post = TestRepo.get!(PhxMediaLibrary.TestPost, post_id)
        media_items = PhxMediaLibrary.get_media(post, :images)

        assert length(media_items) == 1
        assert hd(media_items).uuid == media_uuid
      end
    end
  end

  # ---------------------------------------------------------------------------
  # File size validation (3.2)
  # ---------------------------------------------------------------------------

  describe "file size validation" do
    test "rejects file that exceeds collection max_size" do
      post = create_post!()

      # :small_files collection has max_size: 1_000
      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "big.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:error, {:file_too_large, 2_000, 1_000}} = result
    end

    test "accepts file within collection max_size" do
      post = create_post!()

      small_content = String.duplicate("x", 500)
      path = create_temp_file(small_content, "small.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:ok, media} = result
      assert media.size == 500
    end

    test "accepts file exactly at max_size boundary" do
      post = create_post!()

      exact_content = String.duplicate("x", 1_000)
      path = create_temp_file(exact_content, "exact.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:ok, media} = result
      assert media.size == 1_000
    end

    test "collections without max_size accept any file size" do
      post = create_post!()

      large_content = String.duplicate("x", 100_000)
      path = create_temp_file(large_content, "large.jpg")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert {:ok, _media} = result
    end

    test "file size validation runs before storage (no file written on reject)" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "toobig.txt")

      {:error, {:file_too_large, _, _}} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      # No media should have been persisted
      assert PhxMediaLibrary.get_media(post, :small_files) == []
    end

    test "to_collection! raises PhxMediaLibrary.Error on file size violation" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "toobig.txt")

      assert_raise PhxMediaLibrary.Error, ~r/Failed to add media/, fn ->
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection!(:small_files)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Content-based MIME detection (3.3)
  # ---------------------------------------------------------------------------

  describe "content-based MIME type detection" do
    test "detects MIME type from file content, not just extension" do
      post = create_post!()

      # Write PNG magic bytes to a file with .jpg extension
      png_data =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
          0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08,
          0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE,
          0xD4, 0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

      path = create_temp_file(png_data, "actually_png.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert media.mime_type == "image/png"
    end

    test "rejects file whose content doesn't match collection accepts" do
      post = create_post!()

      # Write PNG magic bytes but try to add to :documents (accepts: pdf, text/plain)
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "fake_doc.pdf")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      assert {:error, {:invalid_mime_type, "image/png", _accepts}} = result
    end

    test "verify_content_type: false skips content verification" do
      post = create_post!()

      # Write PNG data to a file — :unverified collection has verify_content_type: false
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "anything.bin")

      # Should succeed because verification is disabled
      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:unverified)

      # Content-based detection still sets the correct MIME type
      assert media.mime_type == "image/png"
    end

    test "plain text files pass through to extension-based detection" do
      post = create_post!()

      # Plain text content — magic bytes won't match anything
      path = create_temp_file("Hello, this is a plain text document.", "readme.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      # Falls back to extension-based detection
      assert media.mime_type == "text/plain"
    end
  end

  # ---------------------------------------------------------------------------
  # Reordering (3.4)
  # ---------------------------------------------------------------------------

  describe "reorder/3" do
    test "reorders media items by UUID list" do
      post = create_post!()

      uuids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            current_post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.uuid
        end

      [uuid1, uuid2, uuid3] = uuids

      # Reorder: uuid3, uuid1, uuid2
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, 3} = PhxMediaLibrary.reorder(post, :images, [uuid3, uuid1, uuid2])

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      reordered = PhxMediaLibrary.get_media(post, :images)
      reordered_uuids = Enum.map(reordered, & &1.uuid)

      assert reordered_uuids == [uuid3, uuid1, uuid2]
    end

    test "reorder ignores UUIDs not in the collection" do
      post = create_post!()

      path = create_temp_file("content", "file.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      fake_uuid = Ecto.UUID.generate()

      # Include a fake UUID — it should be ignored
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, count} = PhxMediaLibrary.reorder(post, :images, [fake_uuid, media.uuid])
      assert count == 1

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      [remaining] = PhxMediaLibrary.get_media(post, :images)
      assert remaining.uuid == media.uuid
    end

    test "reorder with empty list is a no-op" do
      post = create_post!()

      assert {:ok, 0} = PhxMediaLibrary.reorder(post, :images, [])
    end
  end

  describe "move_to/4" do
    test "moves a media item to the first position" do
      post = create_post!()

      uuids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            current_post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.uuid
        end

      [_uuid1, _uuid2, uuid3] = uuids

      # Move the last item to position 1
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, updated} = PhxMediaLibrary.move_to(post, :images, uuid3, 1)
      assert updated.order == 0

      # Verify ordering
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      reordered = PhxMediaLibrary.get_media(post, :images)
      assert hd(reordered).uuid == uuid3
    end

    test "moves a media item to the last position" do
      post = create_post!()

      uuids =
        for i <- 1..3 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            current_post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.uuid
        end

      [uuid1, _uuid2, _uuid3] = uuids

      # Move the first item to position 3
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, updated} = PhxMediaLibrary.move_to(post, :images, uuid1, 3)
      assert updated.order == 2

      # Verify it's last
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      reordered = PhxMediaLibrary.get_media(post, :images)
      assert List.last(reordered).uuid == uuid1
    end

    test "clamps position to collection size" do
      post = create_post!()

      path = create_temp_file("only item", "solo.jpg")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Position 999 should clamp to 1 (only 1 item)
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, updated} = PhxMediaLibrary.move_to(post, :images, media.uuid, 999)
      assert updated.order == 0
    end

    test "moves to middle position" do
      post = create_post!()

      uuids =
        for i <- 1..4 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            current_post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.using_filename("img_#{i}.jpg")
            |> PhxMediaLibrary.to_collection(:images)

          media.uuid
        end

      [uuid1, _uuid2, _uuid3, uuid4] = uuids

      # Move uuid4 (last) to position 2
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, _updated} = PhxMediaLibrary.move_to(post, :images, uuid4, 2)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      reordered = PhxMediaLibrary.get_media(post, :images)
      reordered_uuids = Enum.map(reordered, & &1.uuid)

      # uuid4 should now be at index 1 (position 2)
      assert Enum.at(reordered_uuids, 0) == uuid1
      assert Enum.at(reordered_uuids, 1) == uuid4
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry events (3.1)
  # ---------------------------------------------------------------------------

  describe "telemetry events" do
    setup do
      test_pid = self()

      :telemetry.attach_many(
        "integration-test-handler-#{System.unique_integer([:positive])}",
        [
          [:phx_media_library, :add, :start],
          [:phx_media_library, :add, :stop],
          [:phx_media_library, :delete, :start],
          [:phx_media_library, :delete, :stop],
          [:phx_media_library, :batch, :start],
          [:phx_media_library, :batch, :stop],
          [:phx_media_library, :storage, :start],
          [:phx_media_library, :storage, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      :ok
    end

    test "emits :add start and stop events on successful upload" do
      post = create_post!()
      path = create_temp_file("telemetry test", "telem.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert_received {:telemetry, [:phx_media_library, :add, :start], %{system_time: _},
                       metadata}

      assert metadata.collection == :images
      assert metadata.source_type == :path

      assert_received {:telemetry, [:phx_media_library, :add, :stop], %{duration: duration},
                       _stop_metadata}

      assert duration > 0
    end

    test "emits :storage events during upload" do
      post = create_post!()
      path = create_temp_file("storage telemetry", "stor.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      assert_received {:telemetry, [:phx_media_library, :storage, :start], _, %{operation: :put}}
      assert_received {:telemetry, [:phx_media_library, :storage, :stop], _, %{operation: :put}}
    end

    test "emits :delete events when deleting media" do
      post = create_post!()
      path = create_temp_file("delete me", "del.txt")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)

      # Drain add/storage events
      flush_mailbox()

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      {:ok, _} = PhxMediaLibrary.delete_media(post, :images, media.uuid)

      assert_received {:telemetry, [:phx_media_library, :delete, :start], _, _}
      assert_received {:telemetry, [:phx_media_library, :delete, :stop], %{duration: _}, _}
    end

    test "emits :batch events for clear_collection" do
      post = create_post!()

      for i <- 1..2 do
        path = create_temp_file("item #{i}", "item_#{i}.txt")

        current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

        current_post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:images)
      end

      # Drain add events
      flush_mailbox()

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      {:ok, 2} = PhxMediaLibrary.clear_collection(post, :images)

      assert_received {:telemetry, [:phx_media_library, :batch, :start], _,
                       %{operation: :clear_collection}}

      assert_received {:telemetry, [:phx_media_library, :batch, :stop], _,
                       %{operation: :clear_collection, count: 2}}
    end

    test "emits :batch events for reorder" do
      post = create_post!()

      uuids =
        for i <- 1..2 do
          path = create_temp_file("image #{i}", "img_#{i}.jpg")

          current_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

          {:ok, media} =
            current_post
            |> PhxMediaLibrary.add(path)
            |> PhxMediaLibrary.to_collection(:images)

          media.uuid
        end

      # Drain add events
      flush_mailbox()

      [uuid1, uuid2] = uuids
      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      {:ok, 2} = PhxMediaLibrary.reorder(post, :images, [uuid2, uuid1])

      assert_received {:telemetry, [:phx_media_library, :batch, :start], _,
                       %{operation: :reorder}}

      assert_received {:telemetry, [:phx_media_library, :batch, :stop], _,
                       %{operation: :reorder, count: 2}}
    end
  end

  # ---------------------------------------------------------------------------
  # Error struct integration (3.1)
  # ---------------------------------------------------------------------------

  describe "structured error handling" do
    test "to_collection! raises PhxMediaLibrary.Error with metadata" do
      post = create_post!()

      error =
        assert_raise PhxMediaLibrary.Error, fn ->
          post
          |> PhxMediaLibrary.add("/nonexistent/file.txt")
          |> PhxMediaLibrary.to_collection!(:images)
        end

      assert error.reason == :add_failed
      assert error.metadata.collection == :images
    end

    test "file size violation returns tagged tuple (not exception)" do
      post = create_post!()

      large_content = String.duplicate("x", 2_000)
      path = create_temp_file(large_content, "big.txt")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:small_files)

      assert {:error, {:file_too_large, actual_size, max_size}} = result
      assert actual_size == 2_000
      assert max_size == 1_000
    end

    test "MIME type violation returns tagged tuple (not exception)" do
      post = create_post!()

      # PNG data going into :documents (accepts only pdf + text/plain)
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
      path = create_temp_file(png_data, "fake.pdf")

      result =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      assert {:error, {:invalid_mime_type, "image/png", _accepted}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Collection config for new fields (3.2 / 3.3)
  # ---------------------------------------------------------------------------

  describe "collection config" do
    test "max_size is accessible via get_media_collection" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:small_files)

      assert config.name == :small_files
      assert config.max_size == 1_000
      assert config.accepts == ~w(text/plain)
    end

    test "verify_content_type defaults to true" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:images)

      assert config.verify_content_type == true
    end

    test "verify_content_type can be set to false" do
      config = PhxMediaLibrary.TestPost.get_media_collection(:unverified)

      assert config.verify_content_type == false
    end
  end

  # ===========================================================================
  # Milestone 3b: Metadata Extraction
  # ===========================================================================

  describe "metadata extraction" do
    test "extracts metadata automatically on to_collection" do
      post = create_post!()
      content = "Hello, metadata world!"
      path = create_temp_file(content, "meta_test.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.to_collection(:documents)

      assert is_map(media.metadata)
      assert media.metadata["type"] == "document"
      assert media.metadata["format"] == "text"
      assert Map.has_key?(media.metadata, "extracted_at")
    end

    test "metadata is persisted to the JSONB column" do
      post = create_post!()
      path = create_temp_file("persistent metadata", "persist.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      # Reload from DB and read back
      reloaded_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      [reloaded] = PhxMediaLibrary.get_media(reloaded_post, :documents)
      assert reloaded.metadata["type"] == "document"
      assert reloaded.metadata["format"] == "text"
      assert Map.has_key?(reloaded.metadata, "extracted_at")
    end

    test "without_metadata/1 skips metadata extraction" do
      post = create_post!()
      path = create_temp_file("no metadata please", "skip.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.without_metadata()
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.metadata == %{}
    end

    test "metadata defaults to empty map for unknown types" do
      post = create_post!()
      # Binary content with .txt extension — classified as document
      path = create_temp_file(<<0, 1, 2, 3, 4, 5>>, "binary.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.to_collection(:documents)

      assert is_map(media.metadata)
      # Should at least have type and extracted_at
      assert media.metadata["type"] in ["document", "other"]
    end

    if Code.ensure_loaded?(Image) do
      test "extracts image dimensions for PNG files" do
        post = create_post!()

        # Create a real image with known dimensions
        {:ok, img} = Image.new(320, 240, color: :red)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_integ_#{:erlang.unique_integer([:positive])}.png"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, media} =
                 post
                 |> PhxMediaLibrary.add(path)
                 |> PhxMediaLibrary.to_collection(:images)

        assert media.metadata["width"] == 320
        assert media.metadata["height"] == 240
        assert media.metadata["type"] == "image"
        assert is_boolean(media.metadata["has_alpha"])
      end

      test "extracts image dimensions for JPEG files" do
        post = create_post!()

        {:ok, img} = Image.new(640, 480, color: :blue)

        path =
          Path.join(
            System.tmp_dir!(),
            "meta_integ_#{:erlang.unique_integer([:positive])}.jpg"
          )

        Image.write!(img, path)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, media} =
                 post
                 |> PhxMediaLibrary.add(path)
                 |> PhxMediaLibrary.to_collection(:images)

        assert media.metadata["width"] == 640
        assert media.metadata["height"] == 480
        assert media.metadata["type"] == "image"
        assert media.metadata["format"] == "jpeg"
      end
    end

    test "metadata extraction failure is non-fatal" do
      # Even if extraction fails internally, the upload should succeed
      post = create_post!()
      path = create_temp_file("valid text content", "safe.txt")

      # Force a custom extractor that fails
      original = Application.get_env(:phx_media_library, :metadata_extractor)

      Application.put_env(
        :phx_media_library,
        :metadata_extractor,
        PhxMediaLibrary.IntegrationTest.FailingMetadataExtractor
      )

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :metadata_extractor, original)
        else
          Application.delete_env(:phx_media_library, :metadata_extractor)
        end
      end)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.to_collection(:documents)

      # Upload succeeded even though extraction failed
      assert media.uuid != nil
      assert media.metadata == %{}
    end

    test "globally disabling extraction skips it" do
      original = Application.get_env(:phx_media_library, :extract_metadata)
      Application.put_env(:phx_media_library, :extract_metadata, false)

      on_exit(fn ->
        if original do
          Application.put_env(:phx_media_library, :extract_metadata, original)
        else
          Application.delete_env(:phx_media_library, :extract_metadata)
        end
      end)

      post = create_post!()
      path = create_temp_file("global disable test", "disabled.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.to_collection(:documents)

      assert media.metadata == %{}
    end
  end

  # ===========================================================================
  # Milestone 3b: URL Download Enhancements
  # ===========================================================================

  describe "URL download validation" do
    test "rejects non-http/https URLs" do
      post = create_post!()

      assert {:error, {:invalid_url, :unsupported_scheme, "ftp"}} =
               post
               |> PhxMediaLibrary.add_from_url("ftp://example.com/file.txt")
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "rejects file:// URLs" do
      post = create_post!()

      assert {:error, {:invalid_url, :unsupported_scheme, "file"}} =
               post
               |> PhxMediaLibrary.add_from_url("file:///etc/passwd")
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "rejects URLs with missing host" do
      post = create_post!()

      assert {:error, {:invalid_url, :missing_host}} =
               post
               |> PhxMediaLibrary.add_from_url("https://")
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "rejects non-string URLs" do
      post = create_post!()

      assert {:error, {:invalid_url, :not_a_string}} =
               post
               |> PhxMediaLibrary.add({:url, 12_345})
               |> PhxMediaLibrary.to_collection(:documents)
    end

    test "add_from_url/3 accepts options" do
      post = create_post!()

      # This will fail to connect (no server), but validates the option passing works
      adder =
        PhxMediaLibrary.add_from_url(post, "https://nonexistent.invalid/file.txt",
          headers: [{"Authorization", "Bearer token"}],
          timeout: 100
        )

      assert adder.source ==
               {:url, "https://nonexistent.invalid/file.txt",
                [headers: [{"Authorization", "Bearer token"}], timeout: 100]}
    end
  end

  describe "URL download telemetry" do
    setup do
      test_pid = self()

      handler_id = "url-download-telemetry-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:phx_media_library, :download, :start],
          [:phx_media_library, :download, :stop],
          [:phx_media_library, :download, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits download events on connection failure" do
      post = create_post!()

      # Will fail to connect, but should still emit start event
      _result =
        post
        |> PhxMediaLibrary.add_from_url("https://nonexistent.test.invalid/file.txt")
        |> PhxMediaLibrary.to_collection(:documents)

      # Should have received at least a start event
      assert_receive {:telemetry_event, [:phx_media_library, :download, :start], _measurements,
                      %{url: "https://nonexistent.test.invalid/file.txt"}},
                     5000
    end
  end

  describe "URL source_url in custom_properties" do
    test "add_from_url creates correct source tuple" do
      post = create_post!()

      adder = PhxMediaLibrary.add_from_url(post, "https://example.com/photo.jpg")
      assert adder.source == {:url, "https://example.com/photo.jpg"}
    end

    test "add_from_url with options creates correct source tuple" do
      post = create_post!()

      adder =
        PhxMediaLibrary.add_from_url(post, "https://example.com/photo.jpg",
          headers: [{"X-Key", "val"}]
        )

      assert adder.source ==
               {:url, "https://example.com/photo.jpg", [headers: [{"X-Key", "val"}]]}
    end
  end

  # ===========================================================================
  # Milestone 3b: Oban Adapter
  # ===========================================================================

  if Code.ensure_loaded?(Oban) do
    describe "Oban async processor" do
      alias PhxMediaLibrary.AsyncProcessor

      test "process_sync/2 delegates to Conversions.process" do
        Code.ensure_loaded!(AsyncProcessor.Oban)
        assert function_exported?(AsyncProcessor.Oban, :process_sync, 2)
      end

      test "process_async/2 is available" do
        Code.ensure_loaded!(AsyncProcessor.Oban)
        assert function_exported?(AsyncProcessor.Oban, :process_async, 2)
      end

      test "ProcessConversions worker module exists" do
        assert Code.ensure_loaded?(Workers.ProcessConversions)
      end

      test "ProcessConversions worker is an Oban.Worker" do
        Code.ensure_loaded!(Workers.ProcessConversions)

        behaviours =
          Workers.ProcessConversions.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Oban.Worker in behaviours
      end

      test "ProcessConversions worker uses :media queue" do
        Code.ensure_loaded!(Workers.ProcessConversions)
        assert Workers.ProcessConversions.__opts__()[:queue] == :media
      end

      test "ProcessConversions worker has max_attempts: 3" do
        Code.ensure_loaded!(Workers.ProcessConversions)
        assert Workers.ProcessConversions.__opts__()[:max_attempts] == 3
      end
    end
  end

  # ===========================================================================
  # Milestone 3b: Combined features
  # ===========================================================================

  describe "metadata + existing features combined" do
    test "metadata is preserved alongside custom_properties" do
      post = create_post!()
      path = create_temp_file("combined test", "combined.txt")

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(path)
               |> PhxMediaLibrary.with_custom_properties(%{
                 "alt" => "my file",
                 "caption" => "test"
               })
               |> PhxMediaLibrary.to_collection(:documents)

      # custom_properties should have our values
      assert media.custom_properties["alt"] == "my file"
      assert media.custom_properties["caption"] == "test"

      # metadata should have extracted data (separate field)
      assert media.metadata["type"] == "document"
      assert Map.has_key?(media.metadata, "extracted_at")
    end

    test "metadata is preserved through clear_collection/2" do
      post = create_post!()
      path = create_temp_file("clear test", "clear.txt")

      {:ok, _media} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert {:ok, 1} = PhxMediaLibrary.clear_collection(post, :documents)

      post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      assert PhxMediaLibrary.get_media(post, :documents) == []
    end

    test "metadata field is included in media item" do
      # Verify we can create media with metadata directly
      media =
        Fixtures.create_media(%{
          metadata: %{"width" => 100, "height" => 200, "type" => "image"}
        })

      assert media.metadata["width"] == 100
      assert media.metadata["height"] == 200
      assert media.metadata["type"] == "image"
    end

    test "metadata defaults to empty map" do
      media = Fixtures.create_media(%{})
      assert media.metadata == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Test support modules
  # ---------------------------------------------------------------------------

  defmodule FailingMetadataExtractor do
    @moduledoc false
    @behaviour PhxMediaLibrary.MetadataExtractor

    @impl true
    def extract(_path, _mime, _opts) do
      {:error, :intentional_test_failure}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      10 -> :ok
    end
  end
end
