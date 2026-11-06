defmodule PhxMediaLibrary.HelpersTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.{Collection, Helpers, TestPost}

  @post %TestPost{id: Ecto.UUID.generate()}

  describe "collection_config/2" do
    test "finds a collection by atom or string name" do
      assert %Collection{name: :avatar, single_file: true} =
               Helpers.collection_config(@post, :avatar)

      assert %Collection{name: :avatar} = Helpers.collection_config(@post, "avatar")
    end

    test "returns nil for an unknown name, without creating an atom" do
      name = "no_such_collection_#{System.unique_integer([:positive])}"

      assert Helpers.collection_config(@post, name) == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "conversions/2" do
    test "returns the conversions that apply to a collection" do
      names = @post |> Helpers.conversions(:images) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:banner, :preview, :thumb]

      names = @post |> Helpers.conversions(:documents) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:preview, :thumb]
    end
  end

  describe "next_order/2" do
    test "counts the items already in the collection" do
      post = %{@post | media_data: %{"images" => [%{"uuid" => "a"}, %{"uuid" => "b"}]}}

      assert Helpers.next_order(post, :images) == 2
      assert Helpers.next_order(post, :documents) == 0
    end
  end
end
