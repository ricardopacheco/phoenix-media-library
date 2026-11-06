defmodule PhxMediaLibrary.ConversionsProcessTest do
  @moduledoc """
  Tests for PhxMediaLibrary.Conversions, focusing on the fetch_source
  pipeline that downloads remote files before image processing.
  """

  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.AsyncProcessor.Oban, as: ObanProcessor
  alias PhxMediaLibrary.{Conversion, Conversions, MediaData, Storage.Memory, TestRepo}

  @moduletag :db

  setup do
    Memory.clear()
    :ok
  end

  describe "process/2 with remote storage (Memory adapter)" do
    test "downloads file from storage, processes conversions, and uploads results" do
      # Create a real image and store it in Memory storage
      image_path = create_temp_image(width: 200, height: 200)
      image_content = File.read!(image_path)

      post = create_test_post()
      uuid = Ecto.UUID.generate()
      owner_type = "posts"
      storage_path = "#{owner_type}/#{post.id}/#{uuid}/photo.png"

      # Store the original image in Memory storage
      :ok = Memory.put(storage_path, image_content, [])

      # Create a media item in JSONB pointing to the stored file
      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "photo.png",
          mime_type: "image/png",
          disk: "memory",
          size: byte_size(image_content)
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [
        Conversion.new(:thumb, width: 150, height: 150, fit: :cover)
      ]

      assert :ok = Conversions.process(context, conversions)

      # Verify conversion file was uploaded to Memory storage
      conversion_path = "#{owner_type}/#{post.id}/#{uuid}/photo_thumb.png"
      assert {:ok, conversion_content} = Memory.get(conversion_path)
      assert byte_size(conversion_content) > 0

      # Verify generated_conversions was updated in JSONB
      fresh_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      data = fresh_post.media_data

      item =
        MediaData.get_item(data, "images", uuid,
          owner_type: owner_type,
          owner_id: to_string(post.id)
        )

      assert item.generated_conversions["thumb"] == true

      # Cleanup
      File.rm(image_path)
    end

    test "processes multiple conversions in a single call" do
      image_path = create_temp_image(width: 400, height: 400)
      image_content = File.read!(image_path)

      post = create_test_post()
      uuid = Ecto.UUID.generate()
      owner_type = "posts"
      storage_path = "#{owner_type}/#{post.id}/#{uuid}/photo.png"

      :ok = Memory.put(storage_path, image_content, [])

      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "photo.png",
          mime_type: "image/png",
          disk: "memory",
          size: byte_size(image_content)
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [
        Conversion.new(:thumb, width: 150, height: 150, fit: :cover),
        Conversion.new(:small, width: 50, height: 50, fit: :cover)
      ]

      assert :ok = Conversions.process(context, conversions)

      # Both conversions should exist in storage
      assert {:ok, _} = Memory.get("#{owner_type}/#{post.id}/#{uuid}/photo_thumb.png")
      assert {:ok, _} = Memory.get("#{owner_type}/#{post.id}/#{uuid}/photo_small.png")

      # Both should be marked in JSONB
      fresh_post = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

      item =
        MediaData.get_item(fresh_post.media_data, "images", uuid,
          owner_type: owner_type,
          owner_id: to_string(post.id)
        )

      assert item.generated_conversions["thumb"] == true
      assert item.generated_conversions["small"] == true

      File.rm(image_path)
    end

    test "returns error when file does not exist in remote storage" do
      post = create_test_post()
      uuid = Ecto.UUID.generate()

      # Create media item but do NOT store the file in Memory
      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "missing.png",
          mime_type: "image/png",
          disk: "memory",
          size: 1024
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [Conversion.new(:thumb, width: 150, height: 150, fit: :cover)]

      assert {:error, :not_found} = Conversions.process(context, conversions)
    end

    test "cleans up temp file after processing" do
      image_path = create_temp_image(width: 100, height: 100)
      image_content = File.read!(image_path)

      post = create_test_post()
      uuid = Ecto.UUID.generate()
      owner_type = "posts"
      storage_path = "#{owner_type}/#{post.id}/#{uuid}/photo.png"

      :ok = Memory.put(storage_path, image_content, [])

      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "photo.png",
          mime_type: "image/png",
          disk: "memory",
          size: byte_size(image_content)
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [Conversion.new(:thumb, width: 150, height: 150, fit: :cover)]

      assert :ok = Conversions.process(context, conversions)

      # Verify no leftover temp files matching our pattern
      tmp_dir = System.tmp_dir!()

      temp_files =
        tmp_dir
        |> File.ls!()
        |> Enum.filter(
          &(String.starts_with?(&1, "phx_media_conversion_") and String.contains?(&1, "photo.png"))
        )

      assert temp_files == []

      File.rm(image_path)
    end

    test "returns error when media item does not exist in JSONB" do
      post = create_test_post()

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: Ecto.UUID.generate()
      }

      conversions = [Conversion.new(:thumb, width: 150, height: 150, fit: :cover)]

      assert {:error, :media_item_not_found} = Conversions.process(context, conversions)
    end

    test "returns error when the owner record was deleted before processing" do
      post = create_test_post()
      uuid = Ecto.UUID.generate()
      create_media_in_jsonb(post, "images", %{uuid: uuid, file_name: "photo.png"})
      TestRepo.delete!(post)

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [Conversion.new(:thumb, width: 150, height: 150, fit: :cover)]

      assert {:error, :owner_not_found} = Conversions.process(context, conversions)
    end
  end

  describe "process/2 failures" do
    setup do
      original = Application.get_env(:phx_media_library, :image_processor)

      Application.put_env(
        :phx_media_library,
        :image_processor,
        PhxMediaLibrary.FailingImageProcessor
      )

      on_exit(fn ->
        if original,
          do: Application.put_env(:phx_media_library, :image_processor, original),
          else: Application.delete_env(:phx_media_library, :image_processor)
      end)

      image_path = create_temp_image(width: 60, height: 60)
      on_exit(fn -> File.rm(image_path) end)

      post = create_test_post()
      uuid = Ecto.UUID.generate()
      :ok = Memory.put("posts/#{post.id}/#{uuid}/photo.png", File.read!(image_path), [])

      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "photo.png",
          mime_type: "image/png",
          disk: "memory"
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      {:ok, post: post, uuid: uuid, context: context}
    end

    test "are reported, and the conversions that succeeded are recorded", %{
      post: post,
      uuid: uuid,
      context: context
    } do
      conversions = [Conversion.new(:thumb, width: 20), Conversion.new(:broken, width: 20)]

      assert {:error, {:conversions_failed, [{:error, {:broken, {:error, :broken_on_purpose}}}]}} =
               Conversions.process(context, conversions)

      item =
        MediaData.get_item(
          TestRepo.get!(PhxMediaLibrary.TestPost, post.id).media_data,
          "images",
          uuid,
          owner_type: "posts",
          owner_id: to_string(post.id)
        )

      assert item.generated_conversions == %{"thumb" => true}
    end

    test "leave no temporary files behind", %{context: context} do
      temp_files = fn ->
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&(&1 =~ "phx_media_conversion_" and &1 =~ "photo"))
      end

      before = temp_files.()
      assert {:error, _} = Conversions.process(context, [Conversion.new(:broken, width: 20)])
      assert temp_files.() -- before == []
    end

    test "make the Oban job return an error so it is retried", %{context: context} do
      conversions = [Conversion.new(:broken, width: 20)]

      assert {:error, {:conversions_failed, _}} =
               ObanProcessor.process_sync(context, conversions)
    end
  end

  describe "process/2 with local disk storage" do
    test "uses local path directly without downloading" do
      image_path = create_temp_image(width: 200, height: 200)
      image_content = File.read!(image_path)

      post = create_test_post()
      uuid = Ecto.UUID.generate()
      owner_type = "posts"

      # Store file on local disk
      disk_root = "priv/static/uploads"
      relative_path = "#{owner_type}/#{post.id}/#{uuid}/photo.png"
      full_path = Path.join(disk_root, relative_path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, image_content)

      post =
        create_media_in_jsonb(post, "images", %{
          uuid: uuid,
          file_name: "photo.png",
          mime_type: "image/png",
          disk: "local",
          size: byte_size(image_content)
        })

      context = %{
        owner_module: PhxMediaLibrary.TestPost,
        owner_id: post.id,
        collection_name: "images",
        item_uuid: uuid
      }

      conversions = [Conversion.new(:thumb, width: 150, height: 150, fit: :cover)]

      assert :ok = Conversions.process(context, conversions)

      # Verify conversion was created on local disk
      conversion_full_path =
        Path.join(disk_root, "#{owner_type}/#{post.id}/#{uuid}/photo_thumb.png")

      assert File.exists?(conversion_full_path)

      # Cleanup
      File.rm_rf!(Path.join(disk_root, owner_type))
      File.rm(image_path)
    end
  end
end
