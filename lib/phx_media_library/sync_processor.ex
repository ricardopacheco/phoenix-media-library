defmodule PhxMediaLibrary.SyncProcessor do
  @moduledoc """
  Synchronous (in-process) implementation of the `PhxMediaLibrary.AsyncProcessor`
  behaviour. Runs `Conversions.process/2` directly in the caller's process.

  Despite the seemingly contradictory pairing ("sync" implementing "async"),
  the `AsyncProcessor` behaviour is just a contract for *how conversion work
  is dispatched* — sibling implementations include `AsyncProcessor.Task`
  (background Task) and `AsyncProcessor.Oban` (persistent queue).

  ## When to use

    1. **Tests.** Background Tasks spawned by `AsyncProcessor.Task` outlive
       the test that triggered them, so they fight for the
       `Ecto.Adapters.SQL.Sandbox` connection and produce noisy
       `Postgrex.Protocol failed to connect` lines on stderr. Running the
       conversion inline in the test process keeps the Sandbox connection
       owner stable.
    2. **Tiny / single-process apps** that don't want a Task supervisor or
       Oban running just for media conversions.

  ## Configuration

      config :phx_media_library, async_processor: PhxMediaLibrary.SyncProcessor

  Production deployments with any meaningful upload volume should prefer
  `AsyncProcessor.Task` (background) or `AsyncProcessor.Oban` (persistent
  queue with retries).
  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.Conversions

  @impl true
  def process_async(context, conversions) do
    Conversions.process(context, conversions)
    :ok
  end

  @impl true
  def process_sync(context, conversions) do
    Conversions.process(context, conversions)
  end
end
