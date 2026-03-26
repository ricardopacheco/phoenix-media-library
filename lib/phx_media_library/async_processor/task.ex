defmodule PhxMediaLibrary.AsyncProcessor.Task do
  @moduledoc """
  Task-based async processor. Processes conversions in a background Task.
  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.Conversions

  @impl true
  def process_async(context, conversions) do
    Task.Supervisor.start_child(
      PhxMediaLibrary.TaskSupervisor,
      fn -> Conversions.process(context, conversions) end
    )

    :ok
  end

  @impl true
  def process_sync(context, conversions) do
    Conversions.process(context, conversions)
  end
end
