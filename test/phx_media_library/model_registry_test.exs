defmodule PhxMediaLibrary.ModelRegistryTest do
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.{ModelRegistry, TestPost}

  setup do
    original = Application.get_env(:phx_media_library, :model_registry, %{})
    on_exit(fn -> Application.put_env(:phx_media_library, :model_registry, original) end)
    :ok
  end

  describe "all_models/0" do
    test "returns only the explicit registry values when configured" do
      Application.put_env(:phx_media_library, :model_registry, %{
        "posts" => TestPost
      })

      assert ModelRegistry.all_models() == [TestPost]
    end

    test "scans loaded modules when no explicit registry is configured" do
      Application.put_env(:phx_media_library, :model_registry, %{})
      Code.ensure_loaded(TestPost)

      models = ModelRegistry.all_models()

      assert TestPost in models
      assert length(models) == length(Enum.uniq(models))
    end

    test "treats an empty registry the same as no registry (falls back to scan)" do
      Application.put_env(:phx_media_library, :model_registry, %{})

      assert TestPost in ModelRegistry.all_models()
    end
  end
end
