defmodule PhxMediaLibrary.SyncProcessor do
  @moduledoc """
  Deprecated: use `PhxMediaLibrary.AsyncProcessor.Inline`.

  Kept so existing `config :phx_media_library, async_processor:
  PhxMediaLibrary.SyncProcessor` settings keep working; every call delegates
  to `PhxMediaLibrary.AsyncProcessor.Inline`, which behaves identically.
  """

  @moduledoc deprecated: "Use PhxMediaLibrary.AsyncProcessor.Inline instead"

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.AsyncProcessor.Inline

  @doc "See `PhxMediaLibrary.AsyncProcessor.Inline.process_async/2`."
  @impl true
  @deprecated "Use PhxMediaLibrary.AsyncProcessor.Inline instead"
  @spec process_async(PhxMediaLibrary.AsyncProcessor.context(), [PhxMediaLibrary.Conversion.t()]) ::
          :ok
  defdelegate process_async(context, conversions), to: Inline

  @doc "See `PhxMediaLibrary.AsyncProcessor.Inline.process_sync/2`."
  @impl true
  @deprecated "Use PhxMediaLibrary.AsyncProcessor.Inline instead"
  @spec process_sync(PhxMediaLibrary.AsyncProcessor.context(), [PhxMediaLibrary.Conversion.t()]) ::
          :ok | {:error, term()}
  defdelegate process_sync(context, conversions), to: Inline
end
