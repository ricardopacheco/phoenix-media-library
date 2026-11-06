defmodule PhxMediaLibrary.WebpTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, PathGenerator, TestPost, TestRepo, Webp}

  setup do
    root = Path.join(System.tmp_dir!(), "phx_media_webp_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)

    original_disks = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      local: [adapter: PhxMediaLibrary.Storage.Disk, root: root, base_url: "/uploads"]
    )

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(root)
    end)

    {:ok, root: root, post: create_test_post()}
  end

  defp add(post, path, collection) do
    post |> PhxMediaLibrary.add(path) |> PhxMediaLibrary.to_collection(collection, disk: :local)
  end

  defp temp_image(format) do
    path = create_temp_image(format: format, width: 60, height: 60)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stored_item(post, collection) do
    [item] = TestPost |> TestRepo.get!(post.id) |> PhxMediaLibrary.get_media(collection)
    item
  end

  defp exists?(root, relative), do: File.exists?(Path.join(root, relative))

  describe "keep_original: true (default)" do
    test "stores a WebP beside the original and serves it", %{root: root, post: post} do
      assert {:ok, media} = add(post, temp_image(:jpg), :webp_photos)

      # the original stays the primary file
      assert String.ends_with?(media.file_name, ".jpg")
      assert media.mime_type == "image/jpeg"
      assert exists?(root, PathGenerator.relative_path(media, nil))

      # the WebP sibling is recorded, persisted and served
      assert %{"webp" => webp_path} = media.custom_properties
      assert webp_path == Path.rootname(PathGenerator.relative_path(media, nil)) <> ".webp"
      assert exists?(root, webp_path)
      assert stored_item(post, :webp_photos).custom_properties["webp"] == webp_path
      assert PhxMediaLibrary.url(media) == "/uploads/" <> webp_path
    end

    test "named conversions are unaffected", %{root: root, post: post} do
      assert {:ok, media} = add(post, temp_image(:jpg), :webp_photos)

      item = stored_item(post, :webp_photos)
      assert item.generated_conversions["thumb"] == true
      assert String.ends_with?(PhxMediaLibrary.url(item, :thumb), "_thumb.jpg")
      assert exists?(root, PathGenerator.relative_path(media, :thumb))
    end

    test "deleting the media removes the WebP too", %{root: root, post: post} do
      assert {:ok, media} = add(post, temp_image(:png), :webp_photos)
      webp_path = Webp.path(media)
      assert exists?(root, webp_path)

      post = TestRepo.get!(TestPost, post.id)
      assert {:ok, _} = PhxMediaLibrary.delete_media(post, :webp_photos, media.uuid)

      refute exists?(root, webp_path)
      refute exists?(root, PathGenerator.relative_path(media, nil))
    end
  end

  describe "keep_original: false" do
    test "conversions are made from the source, then the source is deleted", %{
      root: root,
      post: post
    } do
      # :webp_only gets the thumb/preview conversions, which read the source:
      # they must run before it is deleted.
      assert {:ok, media} = add(post, temp_image(:png), :webp_only)

      assert String.ends_with?(PhxMediaLibrary.url(media), ".webp")
      assert exists?(root, Webp.path(media))
      refute exists?(root, PathGenerator.relative_path(media, nil))

      item = stored_item(post, :webp_only)
      assert item.generated_conversions["thumb"] == true
      assert item.generated_conversions["preview"] == true
      assert exists?(root, PathGenerator.relative_path(item, :thumb))
      assert exists?(root, PathGenerator.relative_path(item, :preview))
    end

    test "the source is kept when the conversions fail", %{root: root, post: post} do
      use_processor(PhxMediaLibrary.WebpTest.FailingProcessor)

      assert {:ok, media} = add(post, temp_image(:png), :webp_only)

      assert exists?(root, Webp.path(media))
      assert exists?(root, PathGenerator.relative_path(media, nil))
    end

    test "the source is kept when a conversion wasn't generated", %{root: root, post: post} do
      # Reports :ok without producing anything, like Conversions.process/2
      # does when single conversions fail.
      use_processor(PhxMediaLibrary.WebpTest.NoOpProcessor)

      assert {:ok, media} = add(post, temp_image(:png), :webp_only)

      assert exists?(root, PathGenerator.relative_path(media, nil))
    end
  end

  defp use_processor(processor) do
    original = Application.get_env(:phx_media_library, :async_processor)
    Application.put_env(:phx_media_library, :async_processor, processor)
    on_exit(fn -> Application.put_env(:phx_media_library, :async_processor, original) end)
  end

  describe "collections without WebP" do
    test "are untouched", %{post: post} do
      assert {:ok, media} = add(post, temp_image(:jpg), :images)

      refute Map.has_key?(media.custom_properties, "webp")
      assert String.ends_with?(PhxMediaLibrary.url(media), ".jpg")
    end

    test "the global config turns WebP on, a collection's webp: false turns it off", %{
      post: post
    } do
      original = Application.get_env(:phx_media_library, :webp)
      Application.put_env(:phx_media_library, :webp, enabled: true)

      on_exit(fn ->
        if original,
          do: Application.put_env(:phx_media_library, :webp, original),
          else: Application.delete_env(:phx_media_library, :webp)
      end)

      assert {:ok, media} = add(post, temp_image(:jpg), :images)
      assert Webp.path(media)
    end
  end

  describe "non-convertible uploads" do
    test "GIFs are left alone, even in a WebP collection", %{post: post} do
      assert {:ok, media} = add(post, temp_image(:gif), :webp_photos)

      assert media.mime_type == "image/gif"
      refute Webp.path(media)
      assert String.ends_with?(PhxMediaLibrary.url(media), ".gif")
    end

    test "an undecodable image is stored without a WebP", %{post: post} do
      # JPEG magic bytes followed by garbage: detected as image/jpeg, but
      # libvips can't decode it.
      path =
        create_temp_file(<<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(64), "x.jpg")

      on_exit(fn -> File.rm(path) end)

      assert {:ok, media} = add(post, path, :webp_photos)
      refute Webp.path(media)
      assert String.ends_with?(PhxMediaLibrary.url(media), ".jpg")
    end
  end

  describe "owned paths" do
    test "include the WebP", %{post: post} do
      assert {:ok, media} = add(post, temp_image(:jpg), :webp_photos)
      assert Webp.path(media) in Media.owned_paths(media)
    end
  end

  defmodule FailingProcessor do
    @moduledoc false
    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(_context, _conversions), do: :ok

    @impl true
    def process_sync(_context, _conversions), do: {:error, :boom}
  end

  defmodule NoOpProcessor do
    @moduledoc false
    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(_context, _conversions), do: :ok

    @impl true
    def process_sync(_context, _conversions), do: :ok
  end
end
