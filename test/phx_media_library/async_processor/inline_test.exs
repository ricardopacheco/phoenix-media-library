defmodule PhxMediaLibrary.AsyncProcessor.InlineTest do
  use PhxMediaLibrary.DataCase, async: false

  @moduletag :db

  alias PhxMediaLibrary.AsyncProcessor.Inline
  alias PhxMediaLibrary.{Config, Conversion, Fixtures, SyncProcessor, TestPost}

  # The happy path — Inline running Conversions.process/2 in the caller's
  # process — is exercised by the whole suite, since test_helper.exs
  # configures it as the :async_processor. These tests pin the return
  # contract of each callback.

  setup do
    post = Fixtures.create_test_post()

    context = %{
      owner_module: TestPost,
      owner_id: post.id,
      collection_name: "images",
      item_uuid: Ecto.UUID.generate()
    }

    {:ok, context: context, conversions: [Conversion.new(:thumb, width: 10)]}
  end

  test "implements the AsyncProcessor behaviour" do
    Code.ensure_loaded!(Inline)
    behaviours = Inline.module_info(:attributes) |> Keyword.get_values(:behaviour)
    assert [PhxMediaLibrary.AsyncProcessor] in behaviours
  end

  test "process_sync/2 returns the conversion result", %{context: ctx, conversions: convs} do
    assert {:error, :media_item_not_found} = Inline.process_sync(ctx, convs)
  end

  test "process_async/2 always returns :ok", %{context: ctx, conversions: convs} do
    assert :ok = Inline.process_async(ctx, convs)
  end

  describe "deprecated SyncProcessor" do
    test "still works when configured, delegating to Inline", %{
      context: ctx,
      conversions: convs
    } do
      # Resolved through Config, exactly as the library dispatches it.
      original = Application.get_env(:phx_media_library, :async_processor)
      Application.put_env(:phx_media_library, :async_processor, SyncProcessor)
      on_exit(fn -> Application.put_env(:phx_media_library, :async_processor, original) end)

      processor = Config.async_processor()
      assert processor == SyncProcessor
      assert {:error, :media_item_not_found} = processor.process_sync(ctx, convs)
      assert :ok = processor.process_async(ctx, convs)
    end
  end
end
