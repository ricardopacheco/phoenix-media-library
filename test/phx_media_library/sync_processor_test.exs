defmodule PhxMediaLibrary.SyncProcessorTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.SyncProcessor

  setup_all do
    Code.ensure_loaded!(SyncProcessor)
    :ok
  end

  test "implements the AsyncProcessor behaviour" do
    behaviours =
      :attributes
      |> SyncProcessor.module_info()
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PhxMediaLibrary.AsyncProcessor in behaviours
  end

  test "exports both process_async/2 and process_sync/2" do
    assert function_exported?(SyncProcessor, :process_async, 2)
    assert function_exported?(SyncProcessor, :process_sync, 2)
  end

  # The runtime behaviour of SyncProcessor.process_async/2 — that it runs
  # Conversions.process/2 inline in the caller's process — is exercised by
  # the entire test suite, since test_helper.exs configures SyncProcessor
  # as the default :async_processor. Any test that calls
  # PhxMediaLibrary.add(...) | to_collection(...) goes through it; the lack
  # of `Postgrex.Protocol failed to connect` warnings on stderr is the
  # signal that work is staying in-process and not leaking past the
  # Sandbox connection owner.
end
