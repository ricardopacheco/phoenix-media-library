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
