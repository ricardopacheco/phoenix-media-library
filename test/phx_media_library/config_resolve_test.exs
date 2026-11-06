defmodule PhxMediaLibrary.ConfigResolveTest do
  # Changes the global :webp and :responsive_images env, so it can't run
  # alongside other tests.
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.Config

  setup do
    for key <- [:webp, :responsive_images] do
      original = Application.fetch_env(:phx_media_library, key)
      Application.delete_env(:phx_media_library, key)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    :ok
  end

  describe "resolve_webp/1" do
    test "defaults to disabled, quality 82, keep_original, no size cap" do
      assert Map.new(Config.resolve_webp(nil)) == %{
               enabled: false,
               quality: 82,
               keep_original: true,
               max_dimension: nil
             }
    end

    test "true / false toggle WebP and keep the other knobs" do
      assert Map.new(Config.resolve_webp(true)) == %{
               enabled: true,
               quality: 82,
               keep_original: true,
               max_dimension: nil
             }

      assert Config.resolve_webp(false)[:enabled] == false
    end

    test "a keyword override implies enabled: true" do
      settings = Config.resolve_webp(quality: 90, keep_original: false)

      assert settings[:enabled] == true
      assert settings[:quality] == 90
      assert settings[:keep_original] == false
    end

    test "a keyword override can still disable it" do
      assert Config.resolve_webp(enabled: false, quality: 90)[:enabled] == false
    end

    test "the global config sits between the defaults and the collection" do
      Application.put_env(:phx_media_library, :webp, enabled: true, quality: 70)

      assert Map.new(Config.resolve_webp(nil)) == %{
               enabled: true,
               quality: 70,
               keep_original: true,
               max_dimension: nil
             }

      assert Config.resolve_webp(false)[:enabled] == false
      assert Config.resolve_webp(quality: 95)[:quality] == 95
    end
  end

  describe "resolve_responsive/1" do
    test "defaults to disabled, the default widths and tiny placeholders" do
      assert Map.new(Config.resolve_responsive(nil)) == %{
               enabled: false,
               widths: [320, 640, 960, 1280, 1920],
               tiny_placeholder: true
             }
    end

    test "the global config supplies the widths" do
      Application.put_env(:phx_media_library, :responsive_images, enabled: true, widths: [100])

      assert Config.resolve_responsive(nil)[:widths] == [100]
      assert Config.resolve_responsive(nil)[:enabled] == true
    end

    test "a keyword override sets its widths and implies enabled: true" do
      Application.put_env(:phx_media_library, :responsive_images, widths: [100])

      settings = Config.resolve_responsive(widths: [640, 1280])
      assert settings[:widths] == [640, 1280]
      assert settings[:enabled] == true
    end

    test "false disables it over a global enabled: true" do
      Application.put_env(:phx_media_library, :responsive_images, enabled: true)
      assert Config.resolve_responsive(false)[:enabled] == false
    end
  end

  describe "responsive_for_collection?/1" do
    test "follows the collection's boolean" do
      assert Config.responsive_for_collection?(%{responsive: true})
      refute Config.responsive_for_collection?(%{responsive: false})
    end

    test "a keyword is enabled unless it says enabled: false" do
      assert Config.responsive_for_collection?(%{responsive: [widths: [640]]})
      refute Config.responsive_for_collection?(%{responsive: [enabled: false, widths: [640]]})
    end

    test "nil falls back to the global switch" do
      refute Config.responsive_for_collection?(%{responsive: nil})

      Application.put_env(:phx_media_library, :responsive_images, enabled: true)
      assert Config.responsive_for_collection?(%{responsive: nil})
      assert Config.responsive_for_collection?(nil)
    end
  end
end
