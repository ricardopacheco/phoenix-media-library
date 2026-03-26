defmodule PhxMediaLibrary.JsonbEdgeCasesTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.Fixtures

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_post!, do: Fixtures.create_test_post()

  defp add_media!(post, collection, filename) do
    path = Fixtures.create_temp_file("content", filename)
    current = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

    {:ok, item} =
      current
      |> PhxMediaLibrary.add(path)
      |> PhxMediaLibrary.using_filename(filename)
      |> PhxMediaLibrary.to_collection(collection)

    item
  end

  defp reload(post), do: TestRepo.get!(PhxMediaLibrary.TestPost, post.id)

  # ---------------------------------------------------------------------------
  # 1. Multiple collections on same model
  # ---------------------------------------------------------------------------

  describe "multiple collections" do
    test "collections are independent" do
      post = create_post!()
      _img = add_media!(post, :images, "photo.jpg")
      _doc = add_media!(post, :documents, "report.pdf")
      _av = add_media!(post, :avatar, "me.png")

      post = reload(post)
      assert length(PhxMediaLibrary.get_media(post, :images)) == 1
      assert length(PhxMediaLibrary.get_media(post, :documents)) == 1
      assert length(PhxMediaLibrary.get_media(post, :avatar)) == 1
    end

    test "delete from one collection does not affect others" do
      post = create_post!()
      img = add_media!(post, :images, "photo.jpg")
      _doc = add_media!(post, :documents, "report.pdf")

      post = reload(post)
      {:ok, _} = PhxMediaLibrary.delete_media(post, :images, img.uuid)

      post = reload(post)
      assert PhxMediaLibrary.get_media(post, :images) == []
      assert length(PhxMediaLibrary.get_media(post, :documents)) == 1
    end

    test "clear_collection does not affect others" do
      post = create_post!()
      _img = add_media!(post, :images, "photo.jpg")
      _doc = add_media!(post, :documents, "report.pdf")

      post = reload(post)
      {:ok, 1} = PhxMediaLibrary.clear_collection(post, :images)

      post = reload(post)
      assert PhxMediaLibrary.get_media(post, :images) == []
      assert length(PhxMediaLibrary.get_media(post, :documents)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Order consistency
  # ---------------------------------------------------------------------------

  describe "order consistency" do
    test "items get sequential 0-based orders" do
      post = create_post!()

      for i <- 0..4 do
        item = add_media!(post, :images, "file_#{i}.txt")
        assert item.order == i
      end
    end

    test "reorder updates order fields" do
      post = create_post!()
      uuids = for i <- 1..3, do: add_media!(post, :images, "f#{i}.txt").uuid

      [u1, u2, u3] = uuids
      post = reload(post)
      {:ok, _} = PhxMediaLibrary.reorder(post, :images, [u3, u1, u2])

      post = reload(post)
      items = PhxMediaLibrary.get_media(post, :images)
      orders = Enum.map(items, &{&1.uuid, &1.order})

      assert {u3, 0} in orders
      assert {u1, 1} in orders
      assert {u2, 2} in orders
    end

    test "delete from middle leaves remaining items" do
      post = create_post!()
      uuids = for i <- 1..3, do: add_media!(post, :images, "f#{i}.txt").uuid

      [_u1, u2, _u3] = uuids
      post = reload(post)
      {:ok, _} = PhxMediaLibrary.delete_media(post, :images, u2)

      post = reload(post)
      items = PhxMediaLibrary.get_media(post, :images)
      assert length(items) == 2
      remaining_uuids = Enum.map(items, & &1.uuid)
      refute u2 in remaining_uuids
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Empty / nil media_data handling
  # ---------------------------------------------------------------------------

  describe "empty media_data" do
    test "get_media returns empty list for fresh post" do
      post = create_post!()
      assert PhxMediaLibrary.get_media(post) == []
      assert PhxMediaLibrary.get_media(post, :images) == []
    end

    test "get_first_media returns nil for empty collection" do
      post = create_post!()
      assert PhxMediaLibrary.get_first_media(post, :images) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 4. JSONB data integrity after multiple operations
  # ---------------------------------------------------------------------------

  describe "data integrity" do
    test "add, delete middle, add more maintains correct state" do
      post = create_post!()
      u1 = add_media!(post, :images, "a.txt").uuid
      u2 = add_media!(post, :images, "b.txt").uuid
      u3 = add_media!(post, :images, "c.txt").uuid

      # Delete middle item
      post = reload(post)
      {:ok, _} = PhxMediaLibrary.delete_media(post, :images, u2)

      # Add 2 more
      u4 = add_media!(post, :images, "d.txt").uuid
      u5 = add_media!(post, :images, "e.txt").uuid

      post = reload(post)
      items = PhxMediaLibrary.get_media(post, :images)
      assert length(items) == 4

      item_uuids = Enum.map(items, & &1.uuid)
      assert u1 in item_uuids
      refute u2 in item_uuids
      assert u3 in item_uuids
      assert u4 in item_uuids
      assert u5 in item_uuids
    end
  end

  # ---------------------------------------------------------------------------
  # 5. delete_media returns correct item
  # ---------------------------------------------------------------------------

  describe "delete_media return value" do
    test "returns the deleted item with its properties" do
      post = create_post!()

      path = Fixtures.create_temp_file("hello", "special.txt")

      {:ok, item} =
        post
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.using_filename("special.txt")
        |> PhxMediaLibrary.with_custom_properties(%{"tag" => "important"})
        |> PhxMediaLibrary.to_collection(:documents)

      post = reload(post)
      {:ok, deleted} = PhxMediaLibrary.delete_media(post, :documents, item.uuid)

      assert deleted.uuid == item.uuid
      assert deleted.file_name == "special.txt"
      assert deleted.custom_properties == %{"tag" => "important"}
    end

    test "returns error for non-existent uuid" do
      post = create_post!()
      assert {:error, :not_found} = PhxMediaLibrary.delete_media(post, :images, "fake-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # 6. get_first_media_url with fallback
  # ---------------------------------------------------------------------------

  describe "get_first_media_url fallback" do
    test "returns fallback for empty collection" do
      post = create_post!()
      url = PhxMediaLibrary.get_first_media_url(post, :images, fallback: "/default.png")
      assert url == "/default.png"
    end

    test "ignores fallback when collection has items" do
      post = create_post!()
      _item = add_media!(post, :images, "photo.jpg")

      post = reload(post)
      url = PhxMediaLibrary.get_first_media_url(post, :images, fallback: "/default.png")
      refute url == "/default.png"
      assert is_binary(url)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. get_media returns all items across collections
  # ---------------------------------------------------------------------------

  describe "get_media without collection" do
    test "returns items from all collections" do
      post = create_post!()
      _img = add_media!(post, :images, "photo.jpg")
      _doc = add_media!(post, :documents, "report.pdf")

      post = reload(post)
      all = PhxMediaLibrary.get_media(post)
      assert length(all) == 2
    end
  end
end
