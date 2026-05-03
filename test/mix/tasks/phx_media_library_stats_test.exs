defmodule Mix.Tasks.PhxMediaLibrary.StatsTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.Fixtures

  setup do
    original_shell = Mix.shell()
    original_registry = Application.get_env(:phx_media_library, :model_registry, %{})

    Mix.shell(Mix.Shell.Process)
    Application.put_env(:phx_media_library, :model_registry, %{
      "posts" => PhxMediaLibrary.TestPost
    })

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:phx_media_library, :model_registry, original_registry)
    end)

    :ok
  end

  defp run(args), do: Mix.Tasks.PhxMediaLibrary.Stats.run(args)

  defp drain_output do
    receive do
      {:mix_shell, _, [msg]} -> msg <> "\n" <> drain_output()
    after
      0 -> ""
    end
  end

  describe "run/1" do
    test "prints empty state when no media exists" do
      run([])
      output = drain_output()

      assert output =~ "PhxMediaLibrary Storage Stats"
      assert output =~ "No media records found."
    end

    test "aggregates a single collection across one model" do
      post = Fixtures.create_test_post()
      post = Fixtures.create_media_in_jsonb(post, "images", size: 1_000)
      _post = Fixtures.create_media_in_jsonb(post, "images", size: 2_500)

      run([])
      output = drain_output()

      assert output =~ "By Collection:"
      assert output =~ "posts"
      assert output =~ "images"
      # 1_000 + 2_500 = 3_500 bytes → "3.5 KB"
      assert output =~ "3.5 KB"
    end

    test "groups by disk across collections" do
      post = Fixtures.create_test_post()
      post = Fixtures.create_media_in_jsonb(post, "images", disk: "local", size: 100)
      _post = Fixtures.create_media_in_jsonb(post, "documents", disk: "memory", size: 200)

      run([])
      output = drain_output()

      assert output =~ "By Disk:"
      assert output =~ "local"
      assert output =~ "memory"
    end

    test "filters by --collection" do
      post = Fixtures.create_test_post()
      post = Fixtures.create_media_in_jsonb(post, "images", size: 1_000)
      _post = Fixtures.create_media_in_jsonb(post, "documents", size: 2_000)

      run(["--collection", "images"])
      output = drain_output()

      assert output =~ "images"
      refute output =~ "documents"
    end

    test "filters by --type" do
      post = Fixtures.create_test_post()
      _post = Fixtures.create_media_in_jsonb(post, "images", size: 1_000)

      run(["--type", "posts"])
      output_match = drain_output()

      run(["--type", "comments"])
      output_no_match = drain_output()

      assert output_match =~ "images"
      assert output_no_match =~ "No media records found."
    end

    test "accepts --include-trashed without effect (compat flag)" do
      post = Fixtures.create_test_post()
      _post = Fixtures.create_media_in_jsonb(post, "images", size: 1_000)

      run(["--include-trashed"])
      output = drain_output()

      assert output =~ "images"
    end
  end
end
