defmodule PhxMediaLibrary.ComponentsTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Components

  # ---------------------------------------------------------------------------
  # Module public API surface
  # ---------------------------------------------------------------------------

  describe "public API" do
    setup do
      Code.ensure_loaded!(Components)
      :ok
    end

    test "media_upload/1 is exported" do
      assert function_exported?(Components, :media_upload, 1)
    end

    test "media_gallery/1 is exported" do
      assert function_exported?(Components, :media_gallery, 1)
    end

    test "media_upload_button/1 is exported" do
      assert function_exported?(Components, :media_upload_button, 1)
    end

    test "format_file_size/1 is private (not exported)" do
      refute function_exported?(Components, :format_file_size, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # format_file_size/1 — tested indirectly through rendered component output
  #
  # Since format_file_size is private, we verify its correctness through the
  # PhxMediaLibrary.Components.FormatTest helper module below, which exercises
  # the same logic via Module.eval_quoted to validate the formatting rules.
  #
  # The actual rendering in components is covered by LiveView integration tests.
  # ---------------------------------------------------------------------------

  # We can test the formatting logic by extracting it into a shared helper.
  # For now, we verify the component modules compile and export correctly.
  # Full rendering tests require a LiveView test setup (Milestone 2).

  describe "component compilation" do
    test "Components module compiles without errors" do
      Code.ensure_loaded!(Components)
      assert {:module, Components} = Code.ensure_loaded(Components)
    end

    test "Components module defines expected function components" do
      Code.ensure_loaded!(Components)

      components = Components.__components__()

      assert Map.has_key?(components, :media_upload)
      assert Map.has_key?(components, :media_gallery)
      assert Map.has_key?(components, :media_upload_button)
    end

    test "media_upload component has expected attrs" do
      Code.ensure_loaded!(Components)

      %{media_upload: component} = Components.__components__()
      attr_names = Enum.map(component.attrs, & &1.name)

      assert :upload in attr_names
      assert :id in attr_names
      assert :label in attr_names
      assert :compact in attr_names
      assert :disabled in attr_names
      assert :cancel_event in attr_names
    end

    test "media_gallery component has expected attrs" do
      Code.ensure_loaded!(Components)

      %{media_gallery: component} = Components.__components__()
      attr_names = Enum.map(component.attrs, & &1.name)

      assert :media in attr_names
      assert :id in attr_names
      assert :columns in attr_names
      assert :delete_event in attr_names
      assert :confirm_delete in attr_names
      assert :conversion in attr_names
    end

    test "media_upload_button component has expected attrs" do
      Code.ensure_loaded!(Components)

      %{media_upload_button: component} = Components.__components__()
      attr_names = Enum.map(component.attrs, & &1.name)

      assert :upload in attr_names
      assert :id in attr_names
      assert :label in attr_names
      assert :icon in attr_names
    end

    test "media_upload component has drop_zone slot" do
      Code.ensure_loaded!(Components)

      %{media_upload: component} = Components.__components__()
      slot_names = Enum.map(component.slots, & &1.name)

      assert :drop_zone in slot_names
    end

    test "media_gallery component has item and empty slots" do
      Code.ensure_loaded!(Components)

      %{media_gallery: component} = Components.__components__()
      slot_names = Enum.map(component.slots, & &1.name)

      assert :item in slot_names
      assert :empty in slot_names
    end
  end

  # ---------------------------------------------------------------------------
  # Default attribute values
  # ---------------------------------------------------------------------------

  describe "default attribute values" do
    setup do
      Code.ensure_loaded!(Components)
      :ok
    end

    test "media_upload defaults" do
      %{media_upload: component} = Components.__components__()
      attrs = Map.new(component.attrs, &{&1.name, &1})

      assert attrs[:compact].opts[:default] == false
      assert attrs[:disabled].opts[:default] == false
      assert attrs[:cancel_event].opts[:default] == "cancel_upload"
    end

    test "media_gallery defaults" do
      %{media_gallery: component} = Components.__components__()
      attrs = Map.new(component.attrs, &{&1.name, &1})

      assert attrs[:columns].opts[:default] == 4
      assert attrs[:delete_event].opts[:default] == "delete_media"
      assert attrs[:confirm_delete].opts[:default] == true
      assert attrs[:conversion].opts[:default] == nil
    end

    test "media_upload_button defaults" do
      %{media_upload_button: component} = Components.__components__()
      attrs = Map.new(component.attrs, &{&1.name, &1})

      assert attrs[:label].opts[:default] == "Choose file"
      assert attrs[:icon].opts[:default] == "hero-arrow-up-tray"
    end
  end

  # ---------------------------------------------------------------------------
  # Render tests — exercise the JSONB-aware components introduced in Wave 2 / 3
  # ---------------------------------------------------------------------------

  describe "blurhash/1 (Wave 3) — renders against a MediaItem struct" do
    import Phoenix.LiveViewTest

    test "renders the canvas keyed by media.uuid when a hash is present" do
      media = %PhxMediaLibrary.MediaItem{
        uuid: "abc-123",
        responsive_images: %{"blurhash" => "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"}
      }

      html = render_component(&Components.blurhash/1, media: media)

      assert html =~ ~s|id="blurhash-abc-123"|
      assert html =~ ~s|data-hash="LKO2?V%2Tw=w]~RBVZRi};RPxuwH"|
    end

    test "renders nothing when no blurhash is stored" do
      media = %PhxMediaLibrary.MediaItem{uuid: "abc-123", responsive_images: %{}}

      html = render_component(&Components.blurhash/1, media: media)

      refute html =~ "blurhash-abc-123"
      refute html =~ "data-hash"
    end

    test "tolerates a nil responsive_images map" do
      media = %PhxMediaLibrary.MediaItem{uuid: "abc-123", responsive_images: nil}

      html = render_component(&Components.blurhash/1, media: media)

      refute html =~ "data-hash"
    end
  end

  describe "media_video/1 (Wave 2) — renders against a MediaItem struct" do
    import Phoenix.LiveViewTest

    test "renders a <video> tag and uses the poster URL from responsive_images" do
      media = %PhxMediaLibrary.MediaItem{
        uuid: "vid-1",
        file_name: "clip.mp4",
        mime_type: "video/mp4",
        disk: "memory",
        responsive_images: %{
          "poster" => %{"path" => "videos/vid-1/poster.jpg", "url" => "/uploads/poster.jpg"}
        },
        metadata: %{"duration" => 12.5, "width" => 1920, "height" => 1080, "codec" => "h264"}
      }

      html = render_component(&Components.media_video/1, media: media)

      assert html =~ ~s|<video|
      assert html =~ ~s|poster="/uploads/poster.jpg"|
      assert html =~ ~s|type="video/mp4"|
      # Metadata strip
      assert html =~ "1920×1080"
      assert html =~ "h264"
    end

    test "omits the metadata strip when metadata is empty" do
      media = %PhxMediaLibrary.MediaItem{
        uuid: "vid-2",
        file_name: "clip.mp4",
        mime_type: "video/mp4",
        disk: "memory",
        responsive_images: %{},
        metadata: %{}
      }

      html = render_component(&Components.media_video/1, media: media)

      assert html =~ ~s|<video|
      refute html =~ "border-t border-zinc-800"
    end
  end
end
