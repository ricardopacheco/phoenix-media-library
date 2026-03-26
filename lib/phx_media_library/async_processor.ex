defmodule PhxMediaLibrary.AsyncProcessor do
  @moduledoc """
  Behaviour for asynchronous conversion processing.

  The context map contains:
  - `:owner_module` - The Ecto schema module
  - `:owner_id` - The parent record ID
  - `:collection_name` - Collection name string
  - `:item_uuid` - Media item UUID
  """

  @type context :: %{
          owner_module: module(),
          owner_id: String.t(),
          collection_name: String.t(),
          item_uuid: String.t()
        }

  @callback process_async(context(), [PhxMediaLibrary.Conversion.t()]) :: :ok | {:error, term()}

  @callback process_sync(context(), [PhxMediaLibrary.Conversion.t()]) :: :ok | {:error, term()}

  @optional_callbacks [process_sync: 2]
end
