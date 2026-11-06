defmodule PhxMediaLibrary.ResponsiveImagesTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, PathGenerator, TestPost, TestRepo}

  setup do
    root = Path.join(System.tmp_dir!(), "phx_media_resp_#{:erlang.unique_integer([:positive])}")
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

  defp put_env(key, value) do
    original = Application.fetch_env(:phx_media_library, key)
    Application.put_env(:phx_media_library, key, value)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:phx_media_library, key, value)
        :error -> Application.delete_env(:phx_media_library, key)
      end
    end)
  end

  defp temp_image(format \\ :jpg, width \\ 1000) do
    path = create_temp_image(format: format, width: width, height: div(width, 2))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stored_item(post, collection) do
    [item] = TestPost |> TestRepo.get!(post.id) |> PhxMediaLibrary.get_media(collection)
    item
  end

  defp variant_paths(item, key \\ "original") do
    item.responsive_images
    |> get_in([key, "variants"])
    |> Kernel.||([])
    |> Enum.map(& &1["path"])
  end

  defp widths(item, key \\ "original") do
    item.responsive_images
    |> get_in([key, "variants"])
    |> Kernel.||([])
    |> Enum.map(& &1["width"])
    |> Enum.sort()
  end

  defp add(post, collection, opts \\ []) do
    adder = PhxMediaLibrary.add(post, Keyword.get(opts, :image, temp_image()))

    adder =
      if opts[:responsive], do: PhxMediaLibrary.with_responsive_images(adder), else: adder

    PhxMediaLibrary.to_collection(adder, collection, disk: :local)
  end

  describe "generation on upload" do
    test "a collection with responsive: [widths: ...] opts in, with its widths", %{post: post} do
      assert {:ok, media} = add(post, :responsive_plain)

      # 1000px wide image: both widths are narrower, plus the full size
      assert widths(media) == [160, 320, 1000]
      assert widths(stored_item(post, :responsive_plain)) == [160, 320, 1000]
    end

    test "a collection without responsive: makes none unless the upload asks", %{post: post} do
      assert {:ok, media} = add(post, :images)
      assert media.responsive_images == %{}
    end

    test "with_responsive_images/1 uses the global widths", %{post: post} do
      # test config: responsive_images: [enabled: true, widths: [320, 640, 960]]
      assert {:ok, media} = add(post, :images, responsive: true)
      assert widths(media) == [320, 640, 960, 1000]
    end

    test "with_responsive_images/1 works without a global enabled: true", %{post: post} do
      put_env(:responsive_images, widths: [320])

      assert {:ok, media} = add(post, :images, responsive: true)
      assert widths(media) == [320, 1000]
    end

    test "a global enabled: false blocks with_responsive_images/1", %{post: post} do
      put_env(:responsive_images, enabled: false, widths: [320])

      assert {:ok, media} = add(post, :images, responsive: true)
      assert media.responsive_images == %{}
    end

    test "a collection's responsive: false blocks with_responsive_images/1", %{post: post} do
      assert {:ok, media} = add(post, :responsive_off, responsive: true)
      assert media.responsive_images == %{}
    end
  end

  describe "conversions" do
    test "get variants with the collection's widths", %{post: post} do
      assert {:ok, _media} = add(post, :responsive_plain)

      # :preview is width: 800 — only the collection widths narrower than it
      assert widths(stored_item(post, :responsive_plain), "preview") == [160, 320, 800]
    end

    test "get none when the collection says responsive: false", %{post: post} do
      assert {:ok, _media} = add(post, :responsive_off)

      item = stored_item(post, :responsive_off)
      assert item.generated_conversions["preview"] == true
      refute Map.has_key?(item.responsive_images, "preview")
    end
  end

  describe "owned paths" do
    test "include every variant", %{root: root, post: post} do
      assert {:ok, _media} = add(post, :responsive_plain)
      item = stored_item(post, :responsive_plain)

      for path <- variant_paths(item) ++ variant_paths(item, "preview") do
        assert path in Media.owned_paths(item)
        assert File.exists?(Path.join(root, path))
      end
    end
  end

  describe "variant paths follow the configured path generator" do
    for generator <- [
          PhxMediaLibrary.PathGenerator.Tenant,
          PhxMediaLibrary.PathGenerator.DateBased
        ] do
      @generator generator

      test "#{inspect(generator)}: variants sit in responsive/ beside the original", %{
        root: root,
        post: post
      } do
        put_env(:path_generator, @generator)

        assert {:ok, media} =
                 post
                 |> PhxMediaLibrary.add(temp_image())
                 |> PhxMediaLibrary.with_responsive_images()
                 |> PhxMediaLibrary.to_collection(:images, disk: :local)

        original_dir = media |> PathGenerator.relative_path(nil) |> Path.dirname()
        [_ | _] = variants = media |> variant_paths() |> Enum.filter(&(&1 =~ "/responsive/"))

        for path <- variants do
          assert Path.dirname(path) == Path.join(original_dir, "responsive")
          assert File.exists?(Path.join(root, path))
        end
      end
    end
  end
end
