defmodule PhxMediaLibrary.UploadHardeningTest do
  @moduledoc """
  Upload hardening (upstream 0.8.4): untrusted filenames, content-type
  verification, image pixel limits and cleanup when an upload fails.
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{PathGenerator, TestPost, TestRepo}

  setup do
    base = Path.join(System.tmp_dir!(), "phx_media_hard_#{:erlang.unique_integer([:positive])}")
    root = Path.join(base, "media")
    File.mkdir_p!(root)

    original_disks = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      local: [adapter: PhxMediaLibrary.Storage.Disk, root: root, base_url: "/uploads"]
    )

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(base)
    end)

    {:ok, base: base, root: root, post: create_test_post()}
  end

  defp text_file(content \\ "hello") do
    path = create_temp_file(content, "upload.txt")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp files_under(dir) do
    dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
  end

  describe "untrusted filenames" do
    test "an upload's client filename can't escape the media directory", %{
      base: base,
      root: root,
      post: post
    } do
      upload = %{path: text_file(), filename: "../../../evil.txt"}

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "evil.txt"
      refute File.exists?(Path.join(base, "evil.txt"))
      assert [stored] = files_under(base)
      assert String.starts_with?(stored, root <> "/")
    end

    test "using_filename/2 is sanitized too", %{root: root, post: post} do
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(text_file())
               |> PhxMediaLibrary.using_filename("..\\..\\notes.txt")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "notes.txt"
      assert File.exists?(Path.join(root, PathGenerator.relative_path(media, nil)))
    end

    test "leading dots are dropped", %{post: post} do
      upload = %{path: text_file(), filename: ".htaccess.txt"}

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "htaccess.txt"
    end

    test "deleting the media stays inside the media directory", %{base: base, post: post} do
      # deep enough to climb out of {root}/posts/{id}/{uuid}/
      upload = %{path: text_file(), filename: "../../../../keep.txt"}
      sibling = Path.join(base, "keep.txt")
      File.write!(sibling, "untouched")

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(upload)
        |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      post = TestRepo.get!(TestPost, post.id)
      assert {:ok, _} = PhxMediaLibrary.delete_media(post, :documents, media.uuid)
      assert File.read!(sibling) == "untouched"
    end
  end
end
