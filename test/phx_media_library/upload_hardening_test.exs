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

  describe "content-type verification" do
    defp png_named(name) do
      png = create_temp_image(format: :png, width: 10, height: 10)
      path = Path.join(Path.dirname(png), "#{System.unique_integer([:positive])}_#{name}")
      File.rename!(png, path)
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "image bytes named .html are refused", %{post: post} do
      upload = %{path: png_named("x.html"), filename: "page.html"}

      assert {:error, {:content_type_mismatch, "image/png", "text/html"}} =
               post
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert TestPost |> TestRepo.get!(post.id) |> PhxMediaLibrary.get_media(:images) == []
    end

    test "a PNG saved as .jpg is fine (same family)", %{post: post} do
      upload = %{path: png_named("x.jpg"), filename: "photo.jpg"}

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert media.mime_type == "image/png"
    end

    test "verify_content_type: false opts out", %{post: post} do
      upload = %{path: png_named("x.html"), filename: "page.html"}

      assert {:ok, _media} =
               post
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:unverified, disk: :local)
    end
  end

  describe "remote downloads" do
    # A public IP literal: no DNS lookup, passes the private-network check.
    # Requests never leave the process — Req's `plug:` option answers them.
    @public "http://93.184.215.14"

    defp serving(body, opts \\ []) do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, body) end
      Keyword.put(opts, :req_options, plug: plug)
    end

    test "are stored, with the source URL recorded", %{post: post} do
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add_from_url(
                 @public <> "/files/notes.txt",
                 serving("remote text")
               )
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)

      assert media.file_name == "notes.txt"
      assert media.size == byte_size("remote text")
      assert media.custom_properties["source_url"] == @public <> "/files/notes.txt"
    end

    test "private hosts are refused", %{post: post} do
      assert {:error, {:invalid_url, :private_address, "169.254.169.254"}} =
               post
               |> PhxMediaLibrary.add_from_url("http://169.254.169.254/latest/meta-data")
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)
    end

    test "allow_private_hosts: true lets an intranet URL through", %{post: post} do
      assert {:ok, _media} =
               post
               |> PhxMediaLibrary.add_from_url(
                 "http://10.0.0.5/a.txt",
                 serving("intranet", allow_private_hosts: true)
               )
               |> PhxMediaLibrary.to_collection(:documents, disk: :local)
    end

    test "the download stops at the collection's max_size", %{post: post} do
      # :small_files has max_size: 1_000
      assert {:error, {:file_too_large, _, 1_000}} =
               post
               |> PhxMediaLibrary.add_from_url(
                 @public <> "/big.txt",
                 serving(String.duplicate("a", 5_000))
               )
               |> PhxMediaLibrary.to_collection(:small_files, disk: :local)
    end
  end

  describe "image pixel limit" do
    # A 66-byte PNG whose header declares 40000 x 40000 pixels (1.6 GP):
    # decoding it would take gigabytes; reading the header takes nothing.
    defp pixel_flood do
      chunk = fn type, data ->
        <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
      end

      png =
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
          chunk.("IHDR", <<40_000::32, 40_000::32, 8, 2, 0, 0, 0>>) <>
          chunk.("IDAT", :zlib.compress(<<0>>)) <> chunk.("IEND", "")

      path = create_temp_file(png, "flood.png")
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp image(width, height) do
      path = create_temp_image(format: :png, width: width, height: height)
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp put_max_image_pixels(value) do
      original = Application.fetch_env(:phx_media_library, :max_image_pixels)
      Application.put_env(:phx_media_library, :max_image_pixels, value)

      on_exit(fn ->
        case original do
          {:ok, v} -> Application.put_env(:phx_media_library, :max_image_pixels, v)
          :error -> Application.delete_env(:phx_media_library, :max_image_pixels)
        end
      end)
    end

    test "a pixel flood is refused by the default 100 megapixel limit", %{post: post} do
      assert {:error, {:image_too_large, 1_600_000_000, 100_000_000}} =
               post
               |> PhxMediaLibrary.add(pixel_flood())
               |> PhxMediaLibrary.to_collection(:images, disk: :local)
    end

    test "a collection's max_pixels applies", %{post: post} do
      assert {:error, {:image_too_large, 10_000, 2_500}} =
               post
               |> PhxMediaLibrary.add(image(100, 100))
               |> PhxMediaLibrary.to_collection(:pixel_capped, disk: :local)

      assert {:ok, _} =
               post
               |> PhxMediaLibrary.add(image(50, 50))
               |> PhxMediaLibrary.to_collection(:pixel_capped, disk: :local)
    end

    test "the global max_image_pixels applies to collections without one", %{post: post} do
      put_max_image_pixels(1_000)

      assert {:error, {:image_too_large, 10_000, 1_000}} =
               post
               |> PhxMediaLibrary.add(image(100, 100))
               |> PhxMediaLibrary.to_collection(:images, disk: :local)
    end

    test ":infinity disables the check", %{post: post} do
      put_max_image_pixels(1_000)

      assert {:ok, _} =
               post
               |> PhxMediaLibrary.add(image(100, 100))
               |> PhxMediaLibrary.to_collection(:pixel_unlimited, disk: :local)
    end

    test "the error reads as a validation message" do
      error =
        PhxMediaLibrary.ValidationError.exception(
          reason: :image_too_large,
          value: 1_600_000_000,
          constraint: 100_000_000
        )

      assert error.message ==
               "Image is too large (1600.0 megapixels, maximum allowed is 100.0 megapixels)"
    end
  end

  describe "cleanup when an upload fails" do
    defp download_temps do
      System.tmp_dir!()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "phx_media_download_"))
    end

    test "a downloaded temp file is removed when validation fails", %{post: post} do
      png = File.read!(create_temp_image(format: :png, width: 10, height: 10))
      before = download_temps()

      # PNG bytes served as page.html: the content-type check refuses them
      opts = [req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 200, png) end]]

      assert {:error, {:content_type_mismatch, _, _}} =
               post
               |> PhxMediaLibrary.add_from_url("http://93.184.215.14/page.html", opts)
               |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert download_temps() -- before == []
    end

    test "stored files are removed when the JSONB write fails", %{root: root, post: post} do
      # The parent disappears mid-upload: storing works, the write raises.
      TestRepo.delete!(post)

      assert_raise Ecto.NoResultsError, fn ->
        post
        |> PhxMediaLibrary.add(create_temp_image(format: :jpg, width: 20, height: 20))
        |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)
      end

      assert files_under(root) == []
    end
  end
end
