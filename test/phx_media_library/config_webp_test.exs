defmodule PhxMediaLibrary.ConfigWebpTest do
  # Changes the global :webp env, so it can't run alongside other tests.
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.Config

  setup do
    original = Application.get_env(:phx_media_library, :webp)
    Application.delete_env(:phx_media_library, :webp)

    on_exit(fn ->
      if original,
        do: Application.put_env(:phx_media_library, :webp, original),
        else: Application.delete_env(:phx_media_library, :webp)
    end)
  end

  describe "resolve_webp/1" do
    test "defaults to disabled, quality 82, keep_original" do
      assert Map.new(Config.resolve_webp(nil)) == %{
               enabled: false,
               quality: 82,
               keep_original: true
             }
    end

    test "true / false toggle WebP and keep the other knobs" do
      assert Map.new(Config.resolve_webp(true)) == %{
               enabled: true,
               quality: 82,
               keep_original: true
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
               keep_original: true
             }

      assert Config.resolve_webp(false)[:enabled] == false
      assert Config.resolve_webp(quality: 95)[:quality] == 95
    end
  end
end
