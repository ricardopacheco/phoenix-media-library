defmodule Mix.Tasks.PhxMediaLibrary.CleanTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias Mix.Tasks.PhxMediaLibrary.Clean
  alias PhxMediaLibrary.{Fixtures, Media, MediaData, TestPost}

  setup do
    root = Path.join(System.tmp_dir!(), "phx_media_clean_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)

    original_shell = Mix.shell()
    original_disks = Application.get_env(:phx_media_library, :disks)

    Mix.shell(Mix.Shell.Process)

    Application.put_env(:phx_media_library, :disks,
      local: [adapter: PhxMediaLibrary.Storage.Disk, root: root, base_url: "/uploads"]
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp run(args), do: Clean.run(["--model", "PhxMediaLibrary.TestPost", "--disk", "local" | args])

  defp drain_output do
    receive do
      {:mix_shell, _, [msg]} -> msg <> "\n" <> drain_output()
    after
      0 -> ""
    end
  end

  # An item that owns every kind of derived file, with all of them on disk.
  defp create_item_with_every_file(root) do
    post = Fixtures.create_test_post()
    uuid = Ecto.UUID.generate()
    base = "posts/#{post.id}/#{uuid}"

    post =
      Fixtures.create_media_in_jsonb(post, "images", %{
        uuid: uuid,
        file_name: "photo.jpg",
        disk: "local",
        generated_conversions: %{"thumb" => true},
        custom_properties: %{"webp" => "#{base}/photo.webp"},
        responsive_images: %{
          "original" => %{
            "variants" => [%{"width" => 320, "path" => "#{base}/responsive/photo_320.jpg"}],
            "placeholder" => %{"data_uri" => "data:image/jpeg;base64,AAAA"}
          },
          "poster" => %{"path" => "#{base}/poster.jpg", "url" => "/uploads/#{base}/poster.jpg"},
          "blurhash" => "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"
        }
      })

    [item] =
      MediaData.get_collection(post.media_data, "images",
        owner_type: TestPost.__media_type__(),
        owner_id: to_string(post.id)
      )

    paths = Media.owned_paths(item)

    for path <- paths do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "x")
    end

    paths
  end

  defp write_file(root, path) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "x")
    full
  end

  test "counts the blurhash, poster, WebP and variants as owned (no crash)", %{root: root} do
    owned = create_item_with_every_file(root)
    assert length(owned) == 5

    run([])
    output = drain_output()

    assert output =~ "No orphaned files found"
    assert output =~ "No missing files found"
  end

  test "dry run lists orphans without deleting them", %{root: root} do
    create_item_with_every_file(root)
    orphan = write_file(root, "posts/stale/old.jpg")

    run([])
    output = drain_output()

    assert output =~ "Found 1 orphaned file(s)"
    assert output =~ "posts/stale/old.jpg"
    assert File.exists?(orphan)
  end

  test "--force deletes only orphaned files", %{root: root} do
    owned = create_item_with_every_file(root)
    orphan = write_file(root, "posts/stale/old.jpg")

    run(["--force"])
    _ = drain_output()

    refute File.exists?(orphan)

    for path <- owned do
      assert File.exists?(Path.join(root, path)), "expected owned file to survive: #{path}"
    end
  end

  test "reports an item with neither its original nor its WebP", %{root: root} do
    [original | _] = owned = create_item_with_every_file(root)
    webp = Enum.find(owned, &String.ends_with?(&1, ".webp"))
    File.rm!(Path.join(root, original))
    File.rm!(Path.join(root, webp))

    run([])
    output = drain_output()

    assert output =~ "Found 1 missing file(s)"
    assert output =~ "photo.jpg"
  end

  test "an original replaced by its WebP is not reported missing", %{root: root} do
    post = Fixtures.create_test_post()
    uuid = Ecto.UUID.generate()
    webp_path = "posts/#{post.id}/#{uuid}/photo.webp"

    Fixtures.create_media_in_jsonb(post, "images", %{
      uuid: uuid,
      file_name: "photo.jpg",
      disk: "local",
      custom_properties: %{"webp" => webp_path}
    })

    # keep_original: false — only the WebP is on disk
    write_file(root, webp_path)

    run([])
    output = drain_output()

    assert output =~ "No missing files found"
    assert output =~ "No orphaned files found"
  end

  test "a disk with files but no media items doesn't crash", %{root: root} do
    write_file(root, "posts/stale/old.jpg")

    run([])
    output = drain_output()

    assert output =~ "Found 1 orphaned file(s)"
    assert output =~ "No missing files found"
  end
end
