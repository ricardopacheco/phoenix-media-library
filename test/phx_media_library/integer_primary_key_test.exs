defmodule PhxMediaLibrary.IntegerPrimaryKeyTest do
  @moduledoc """
  Media on parents whose primary key is an integer (`bigserial`).

  Upstream 0.7.0 added a `mediable_id_type` setting because its `media`
  table had a fixed-type `mediable_id` column. This fork stores media in the
  parent's own JSONB column and only ever uses the owner id as a string, so
  no setting is needed. These tests pin that down end to end.
  """

  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.{Fixtures, TestIntegerPost, TestRepo}
  alias PhxMediaLibrary.Workers.ProcessConversions

  defmodule NoOpProcessor do
    @moduledoc false
    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(_context, _conversions), do: :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "phx_media_int_pk_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_disks = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      local: [adapter: PhxMediaLibrary.Storage.Disk, root: dir, base_url: "/uploads"]
    )

    image_path = Fixtures.create_temp_image(width: 100, height: 100)

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original_disks)
      File.rm_rf!(dir)
      File.rm(image_path)
    end)

    post = TestRepo.insert!(%TestIntegerPost{title: "Integer PK"})

    {:ok, dir: dir, image_path: image_path, post: post}
  end

  test "add -> store -> convert -> retrieve -> delete", %{
    dir: dir,
    image_path: image_path,
    post: post
  } do
    assert is_integer(post.id)

    assert {:ok, media} =
             post
             |> PhxMediaLibrary.add(image_path)
             |> PhxMediaLibrary.using_filename("photo.png")
             |> PhxMediaLibrary.to_collection(:images, disk: :local)

    assert media.owner_type == "integer_posts"
    assert media.owner_id == Integer.to_string(post.id)

    original = Path.join(dir, "integer_posts/#{post.id}/#{media.uuid}/photo.png")
    assert File.exists?(original)
    assert PhxMediaLibrary.path(media) == original

    assert PhxMediaLibrary.url(media) ==
             "/uploads/integer_posts/#{post.id}/#{media.uuid}/photo.png"

    # The test suite's SyncProcessor runs conversions inline on add.
    post = TestRepo.get!(TestIntegerPost, post.id)
    assert [item] = PhxMediaLibrary.get_media(post, :images)
    assert item.uuid == media.uuid
    assert item.owner_id == Integer.to_string(post.id)
    assert item.generated_conversions["thumb"] == true

    thumb = PhxMediaLibrary.path(item, :thumb)
    assert thumb == Path.join(dir, "integer_posts/#{post.id}/#{media.uuid}/photo_thumb.png")
    assert File.exists?(thumb)

    assert {:ok, _deleted} = PhxMediaLibrary.delete_media(post, :images, media.uuid)

    post = TestRepo.get!(TestIntegerPost, post.id)
    assert PhxMediaLibrary.get_media(post, :images) == []
    refute File.exists?(original)
    refute File.exists?(thumb)
  end

  test "media of one integer-PK parent is not visible from another", %{post: post} do
    other = TestRepo.insert!(%TestIntegerPost{title: "Other"})
    path = Fixtures.create_temp_file("hello", "note.txt")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, _media} =
             post
             |> PhxMediaLibrary.add(path)
             |> PhxMediaLibrary.to_collection(:documents, disk: :local)

    assert [_] = post |> reload() |> PhxMediaLibrary.get_media(:documents)
    assert other |> reload() |> PhxMediaLibrary.get_media(:documents) == []
  end

  test "the Oban worker resolves a stringified integer owner id", %{
    image_path: image_path,
    post: post
  } do
    # Store the item without running conversions, then let the worker run
    # them from job args, where the owner id travels as a JSON string.
    original_processor = Application.get_env(:phx_media_library, :async_processor)
    Application.put_env(:phx_media_library, :async_processor, NoOpProcessor)

    on_exit(fn ->
      Application.put_env(:phx_media_library, :async_processor, original_processor)
    end)

    assert {:ok, media} =
             post
             |> PhxMediaLibrary.add(image_path)
             |> PhxMediaLibrary.to_collection(:images, disk: :local)

    assert [item] = post |> reload() |> PhxMediaLibrary.get_media(:images)
    assert item.generated_conversions == %{}

    Code.ensure_loaded!(TestIntegerPost)

    assert :ok ==
             Oban.Testing.perform_job(
               ProcessConversions,
               %{
                 "owner_module" => to_string(TestIntegerPost),
                 "owner_id" => Integer.to_string(post.id),
                 "collection_name" => "images",
                 "item_uuid" => media.uuid,
                 "conversions" => ["thumb"]
               },
               []
             )

    assert [item] = post |> reload() |> PhxMediaLibrary.get_media(:images)
    assert item.generated_conversions["thumb"] == true
    assert File.exists?(PhxMediaLibrary.path(item, :thumb))
  end

  defp reload(post), do: TestRepo.get!(TestIntegerPost, post.id)
end
