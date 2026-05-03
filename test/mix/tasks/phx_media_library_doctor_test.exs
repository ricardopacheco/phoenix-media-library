defmodule Mix.Tasks.PhxMediaLibrary.DoctorTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.{Config, Fixtures, Helpers, MediaData, TestRepo}

  setup do
    original_shell = Mix.shell()
    original_registry = Application.get_env(:phx_media_library, :model_registry, %{})

    Mix.shell(Mix.Shell.Process)
    Application.put_env(:phx_media_library, :model_registry, %{
      "posts" => PhxMediaLibrary.TestPost
    })

    local_root = Keyword.fetch!(Config.disk_config(:local), :root)
    File.mkdir_p!(local_root)

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:phx_media_library, :model_registry, original_registry)
      File.rm_rf!(local_root)
    end)

    {:ok, local_root: local_root}
  end

  defp run(args), do: Mix.Tasks.PhxMediaLibrary.Doctor.run(args)

  defp drain_output do
    receive do
      {:mix_shell, _, [msg]} -> msg <> "\n" <> drain_output()
    after
      0 -> ""
    end
  end

  # Build a media item on the local disk and (optionally) create the file.
  defp create_local_media(post, collection, opts \\ []) do
    file_name = Keyword.get(opts, :file_name, "doc.txt")
    create_file? = Keyword.get(opts, :create_file, true)
    create_conversion_files? = Keyword.get(opts, :create_conversion_files, false)
    conversions = Keyword.get(opts, :generated_conversions, %{})

    post =
      Fixtures.create_media_in_jsonb(post, collection,
        disk: "local",
        file_name: file_name,
        size: 100,
        generated_conversions: conversions
      )

    if create_file? do
      column = post.__struct__.__media_column__()
      data = Map.get(post, column)

      [item | _] =
        MediaData.get_collection(data, collection,
          owner_type: post.__struct__.__media_type__(),
          owner_id: to_string(post.id)
        )

      full_path = PhxMediaLibrary.PathGenerator.full_path(item, nil)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "x")

      if create_conversion_files? do
        Enum.each(item.generated_conversions || %{}, fn {conversion, _} ->
          conv_path = PhxMediaLibrary.PathGenerator.full_path(item, conversion)
          File.mkdir_p!(Path.dirname(conv_path))
          File.write!(conv_path, "x")
        end)
      end
    end

    post
  end

  describe "run/1" do
    test "reports all files present when nothing is missing" do
      post = Fixtures.create_test_post()
      _post = create_local_media(post, "images")

      run([])
      output = drain_output()

      assert output =~ "PhxMediaLibrary Doctor"
      assert output =~ "All files present."
    end

    test "reports missing original files" do
      post = Fixtures.create_test_post()
      _post = create_local_media(post, "images", create_file: false)

      run([])
      output = drain_output()

      assert output =~ "missing original file"
      assert output =~ "doc.txt"
    end

    test "reports missing conversion files" do
      post = Fixtures.create_test_post()

      _post =
        create_local_media(post, "images",
          generated_conversions: %{"thumb" => true}
        )

      run([])
      output = drain_output()

      # Original is present, but no thumb file was created on disk
      assert output =~ "missing conversion file"
      assert output =~ "thumb"
    end

    test "skips file checks with --skip-files" do
      post = Fixtures.create_test_post()
      _post = create_local_media(post, "images", create_file: false)

      run(["--skip-files"])
      output = drain_output()

      assert output =~ "Skipping file existence checks"
      refute output =~ "missing original file"
    end

    test "filters by --type" do
      post = Fixtures.create_test_post()
      _post = create_local_media(post, "images", create_file: false)

      run(["--type", "comments"])
      output = drain_output()

      # No models match "comments", so no missing-file reports
      refute output =~ "missing original file"
      assert output =~ "No HasMedia schemas registered."
    end

    test "--fix removes missing-original items from JSONB after confirming" do
      post = Fixtures.create_test_post()
      _post = create_local_media(post, "images", create_file: false)

      # Pre-arm a "yes" response for the upcoming prompt.
      send(self(), {:mix_shell_input, :yes?, true})

      run(["--fix"])
      output = drain_output()

      assert output =~ "removed"

      # Verify the item is actually gone
      reloaded = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      data = Helpers.media_data(reloaded)
      assert MediaData.get_collection(data, "images") == []
    end

    test "--fix clears missing conversions but keeps the item" do
      post = Fixtures.create_test_post()

      _post =
        create_local_media(post, "images",
          generated_conversions: %{"thumb" => true}
        )

      send(self(), {:mix_shell_input, :yes?, true})

      run(["--fix"])
      output = drain_output()

      assert output =~ "cleared"

      reloaded = TestRepo.get!(PhxMediaLibrary.TestPost, post.id)
      data = Helpers.media_data(reloaded)
      [item] = MediaData.get_collection(data, "images")
      assert item.generated_conversions == %{}
    end
  end
end
