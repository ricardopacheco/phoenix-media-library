defmodule PhxMediaLibrary.Fixtures do
  @moduledoc """
  Test fixtures for PhxMediaLibrary tests.
  """

  alias PhxMediaLibrary.{MediaData, MediaItem, TestRepo}

  @fixtures_path Path.expand("fixtures", __DIR__)

  @doc """
  Returns the path to a test fixture file.
  """
  def fixture_path(filename) do
    Path.join(@fixtures_path, filename)
  end

  @doc """
  Creates a temporary file with the given content.
  Returns the path to the temporary file.
  """
  def create_temp_file(content, filename \\ "test_file.txt") do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    path
  end

  @doc """
  Creates a temporary image file.
  Returns the path to the temporary file.
  """
  def create_temp_image(opts \\ []) do
    width = Keyword.get(opts, :width, 100)
    height = Keyword.get(opts, :height, 100)
    color = Keyword.get(opts, :color, "red")
    format = Keyword.get(opts, :format, :png)

    filename = "test_image_#{:erlang.unique_integer([:positive])}.#{format}"
    path = Path.join(System.tmp_dir!(), filename)

    # Create a simple colored image using Image library
    case Image.new(width, height, color: color) do
      {:ok, image} ->
        Image.write!(image, path)
        path

      {:error, _reason} ->
        # Fallback: create a minimal valid PNG
        create_minimal_png(path)
        path
    end
  end

  @doc """
  Creates a minimal valid PNG file.
  """
  def create_minimal_png(path) do
    # Minimal 1x1 red PNG
    png_data =
      <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
        0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4, 0xEF, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

    File.write!(path, png_data)
  end

  @doc """
  Creates a test post persisted in the database.

  In the JSONB approach, the post must be persisted because media data
  lives in the post's `media_data` column.
  """
  def create_test_post(attrs \\ %{}) do
    default_attrs = %{
      title: "Test Post"
    }

    %PhxMediaLibrary.TestPost{}
    |> Ecto.Changeset.change(Map.merge(default_attrs, Enum.into(attrs, %{})))
    |> TestRepo.insert!()
  end

  @doc """
  Creates a media item in the default collection of a new post.

  This is a convenience that creates a persisted post and adds a media
  item to it via JSONB. Returns the `MediaItem` struct.

  For more control, use `create_test_post/1` + `create_media_in_jsonb/3`.
  """
  def create_media(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    collection = Map.get(attrs, :collection_name, "default")
    post = Map.get_lazy(attrs, :post, fn -> create_test_post() end)

    item_attrs =
      attrs
      |> Map.drop([:collection_name, :post, :mediable_type, :mediable_id, :order_column])

    updated_post = create_media_in_jsonb(post, collection, item_attrs)

    # Return the MediaItem with owner context
    column = post.__struct__.__media_column__()
    data = Map.get(updated_post, column) || %{}

    data
    |> MediaData.get_collection(collection,
      owner_type: post.__struct__.__media_type__(),
      owner_id: to_string(updated_post.id)
    )
    |> List.last()
  end

  @doc """
  Creates a media item in a post's JSONB media_data column.

  Builds a `MediaItem`, adds it to the specified collection in the post's
  JSONB data, and updates the post in the database. Returns the updated post.

  ## Options

  Accepts the same fields as `MediaItem` (`:uuid`, `:file_name`, `:mime_type`,
  `:disk`, `:size`, etc.). Defaults are provided for convenience.
  """
  def create_media_in_jsonb(post, collection_name, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    item =
      MediaItem.new(
        uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
        name: Map.get(attrs, :name, "test-file"),
        file_name: Map.get(attrs, :file_name, "test-file.jpg"),
        mime_type: Map.get(attrs, :mime_type, "image/jpeg"),
        disk: Map.get(attrs, :disk, "memory"),
        size: Map.get(attrs, :size, 1024),
        checksum: Map.get(attrs, :checksum),
        checksum_algorithm: Map.get(attrs, :checksum_algorithm, "sha256"),
        order: Map.get(attrs, :order, 0),
        custom_properties: Map.get(attrs, :custom_properties, %{}),
        metadata: Map.get(attrs, :metadata, %{}),
        generated_conversions: Map.get(attrs, :generated_conversions, %{}),
        responsive_images: Map.get(attrs, :responsive_images, %{}),
        inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now() |> DateTime.to_iso8601())
      )

    column = post.__struct__.__media_column__()
    current_data = Map.get(post, column) || %{}
    updated_data = MediaData.put_item(current_data, collection_name, item)

    post
    |> Ecto.Changeset.change(%{column => updated_data})
    |> TestRepo.update!()
  end

  @doc """
  Cleans up temporary test files.
  """
  def cleanup_temp_files(paths) when is_list(paths) do
    Enum.each(paths, &File.rm/1)
  end

  def cleanup_temp_files(path) when is_binary(path) do
    File.rm(path)
  end

  @doc """
  Sets up a temporary directory for file storage tests.
  Returns the path and a cleanup function.
  """
  def setup_temp_storage do
    dir = Path.join(System.tmp_dir!(), "phx_media_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_cleanup = fn ->
      File.rm_rf!(dir)
    end

    {dir, on_cleanup}
  end
end
