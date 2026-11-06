defmodule PhxMediaLibrary.AsyncProcessor.Inline do
  @moduledoc """
  Inline implementation of the `PhxMediaLibrary.AsyncProcessor` behaviour:
  conversions run in the calling process, so they are done before
  `PhxMediaLibrary.to_collection/3` returns.

  The `AsyncProcessor` behaviour is a contract for *how conversion work is
  dispatched*; sibling implementations are `AsyncProcessor.Task` (background
  Task, the default) and `AsyncProcessor.Oban` (persistent queue).

  ## When to use

    1. **Tests.** Background Tasks spawned by `AsyncProcessor.Task` outlive
       the test that triggered them, fight for the
       `Ecto.Adapters.SQL.Sandbox` connection and produce noisy
       `Postgrex.Protocol failed to connect` lines on stderr. Running
       conversions inline keeps the Sandbox connection owner stable.
    2. **Scripts and small apps** that don't want a Task supervisor or Oban
       running just for media conversions.

  Production deployments with any meaningful upload volume should prefer
  `AsyncProcessor.Task` or `AsyncProcessor.Oban` (retries, persistence).

  ## Configuration

      config :phx_media_library, async_processor: PhxMediaLibrary.AsyncProcessor.Inline

  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.Conversions

  @doc """
  Runs the conversions in the calling process and returns `:ok`, whatever
  their outcome (failures are logged by `PhxMediaLibrary.Conversions`).
  """
  @impl true
  @spec process_async(PhxMediaLibrary.AsyncProcessor.context(), [PhxMediaLibrary.Conversion.t()]) ::
          :ok
  def process_async(context, conversions) do
    _ = Conversions.process(context, conversions)
    :ok
  end

  @doc """
  Runs the conversions in the calling process and returns their result.
  """
  @impl true
  @spec process_sync(PhxMediaLibrary.AsyncProcessor.context(), [PhxMediaLibrary.Conversion.t()]) ::
          :ok | {:error, term()}
  def process_sync(context, conversions) do
    Conversions.process(context, conversions)
  end
end
