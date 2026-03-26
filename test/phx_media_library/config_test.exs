defmodule PhxMediaLibrary.ConfigTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Config

  describe "default_disk/0" do
    test "returns an atom" do
      disk = Config.default_disk()
      assert is_atom(disk)
    end
  end

  describe "disk_config/1" do
    test "returns configuration for a known disk" do
      # Use whatever default disk is configured
      disk = Config.default_disk()
      config = Config.disk_config(disk)

      assert is_list(config)
      assert Keyword.has_key?(config, :adapter)
    end

    test "accepts string disk names" do
      disk = Config.default_disk()
      disk_string = Atom.to_string(disk)

      config = Config.disk_config(disk_string)
      assert is_list(config)
      assert Keyword.has_key?(config, :adapter)
    end

    test "raises for unknown disk" do
      assert_raise RuntimeError, ~r/Unknown disk/, fn ->
        Config.disk_config(:nonexistent_disk_that_does_not_exist)
      end
    end
  end

  describe "storage_adapter/1" do
    test "returns a StorageWrapper struct" do
      disk = Config.default_disk()
      wrapper = Config.storage_adapter(disk)

      assert %PhxMediaLibrary.StorageWrapper{} = wrapper
      assert is_atom(wrapper.adapter)
      assert is_list(wrapper.config)
    end

    test "wrapper contains disk configuration" do
      disk = Config.default_disk()
      wrapper = Config.storage_adapter(disk)

      # All storage adapters should have these basic options
      assert Keyword.has_key?(wrapper.config, :adapter)
    end

    test "accepts string disk names" do
      disk = Config.default_disk()
      disk_string = Atom.to_string(disk)

      wrapper = Config.storage_adapter(disk_string)
      assert %PhxMediaLibrary.StorageWrapper{} = wrapper
    end
  end

  describe "async_processor/0" do
    test "returns a module" do
      processor = Config.async_processor()
      assert is_atom(processor)
    end

    test "returns default Task processor when not configured" do
      # This tests the default behavior
      processor = Config.async_processor()
      assert processor == PhxMediaLibrary.AsyncProcessor.Task
    end
  end

  describe "image_processor/0" do
    test "returns a module" do
      processor = Config.image_processor()
      assert is_atom(processor)
    end

    test "returns default Image processor when not configured" do
      processor = Config.image_processor()
      assert processor == PhxMediaLibrary.ImageProcessor.Image
    end
  end

  describe "responsive_images_config/0" do
    test "returns a keyword list" do
      config = Config.responsive_images_config()
      assert is_list(config)
    end
  end

  describe "responsive_images_enabled?/0" do
    test "returns a boolean" do
      result = Config.responsive_images_enabled?()
      assert is_boolean(result)
    end

    test "returns value from config" do
      # config/config.exs sets enabled: true; code default is false
      assert Config.responsive_images_enabled?() == true
    end
  end

  describe "responsive_for_collection?/1" do
    test "falls back to global default when collection is nil" do
      assert Config.responsive_for_collection?(nil) == Config.responsive_images_enabled?()
    end

    test "falls back to global default when collection responsive is nil" do
      collection = %PhxMediaLibrary.Collection{name: :images, responsive: nil}
      assert Config.responsive_for_collection?(collection) == Config.responsive_images_enabled?()
    end

    test "returns true when collection responsive is true" do
      collection = %PhxMediaLibrary.Collection{name: :images, responsive: true}
      assert Config.responsive_for_collection?(collection) == true
    end

    test "returns false when collection responsive is false" do
      collection = %PhxMediaLibrary.Collection{name: :images, responsive: false}
      assert Config.responsive_for_collection?(collection) == false
    end

    test "collection setting overrides global config" do
      # Global is false by default, but collection says true
      collection = %PhxMediaLibrary.Collection{name: :images, responsive: true}
      assert Config.responsive_for_collection?(collection) == true
    end
  end

  describe "responsive_image_widths/0" do
    test "returns a list of positive integers" do
      widths = Config.responsive_image_widths()

      assert is_list(widths)
      assert Enum.all?(widths, &is_integer/1)
      assert Enum.all?(widths, &(&1 > 0))
    end

    test "widths are sorted ascending" do
      widths = Config.responsive_image_widths()

      assert widths == Enum.sort(widths)
    end

    test "returns non-empty list" do
      widths = Config.responsive_image_widths()

      assert widths != []
    end
  end

  describe "tiny_placeholders_enabled?/0" do
    test "returns a boolean" do
      result = Config.tiny_placeholders_enabled?()
      assert is_boolean(result)
    end

    test "returns true by default" do
      assert Config.tiny_placeholders_enabled?() == true
    end
  end

  describe "repo/0" do
    test "returns the configured repo" do
      repo = Config.repo()
      assert is_atom(repo)
    end
  end
end
