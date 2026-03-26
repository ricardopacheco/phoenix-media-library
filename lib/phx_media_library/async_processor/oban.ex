if Code.ensure_loaded?(Oban) do
  defmodule PhxMediaLibrary.AsyncProcessor.Oban do
    @moduledoc """
    Oban-based async processor for reliable background processing.

    Requires `oban` as a dependency and proper Oban configuration in your app.
    Unlike the default `Task`-based processor, Oban jobs are persisted to the
    database, survive application restarts, and support automatic retries with
    configurable backoff.

    ## Setup

    1. Add `:oban` to your dependencies and configure it:

           # mix.exs
           {:oban, "~> 2.18"}

           # config/config.exs
           config :my_app, Oban,
             repo: MyApp.Repo,
             queues: [media: 10]

    2. Tell PhxMediaLibrary to use the Oban adapter:

           config :phx_media_library,
             async_processor: PhxMediaLibrary.AsyncProcessor.Oban

    ## Queue Configuration

    The worker uses the `:media` queue by default. Adjust concurrency to
    match your server's CPU/memory capacity:

        # Low-traffic app
        queues: [media: 5]

        # High-traffic app with beefy servers
        queues: [media: 20]

    ## Retry Behaviour

    The `ProcessConversions` worker is configured with `max_attempts: 3`.
    Failed jobs use Oban's default exponential backoff. You can monitor
    failed jobs via Oban's built-in dashboard or `Oban.Web`.

    ## How It Works

    When media is uploaded and conversions are defined, the processor enqueues
    an Oban job with the `owner_module`, `owner_id`, `collection_name`, and
    `item_uuid` so the worker can reconstruct the context and retrieve the full
    `Conversion` definitions (with dimensions, quality, fit mode, etc.).
    """

    @behaviour PhxMediaLibrary.AsyncProcessor

    alias PhxMediaLibrary.{Conversions, Workers.ProcessConversions}

    @impl true
    def process_async(context, conversions) do
      conversion_names = Enum.map(conversions, &to_string(&1.name))

      %{
        owner_module: to_string(context.owner_module),
        owner_id: to_string(context.owner_id),
        collection_name: to_string(context.collection_name),
        item_uuid: context.item_uuid,
        conversions: conversion_names
      }
      |> ProcessConversions.new()
      |> Oban.insert()

      :ok
    end

    @doc """
    Process conversions synchronously, bypassing the Oban queue.

    Useful for tests or situations where you need conversions to complete
    before continuing (e.g. generating a thumbnail before returning a
    response).

    ## Examples

        PhxMediaLibrary.AsyncProcessor.Oban.process_sync(context, conversions)

    """
    @impl true
    def process_sync(context, conversions) do
      Conversions.process(context, conversions)
    end
  end

  defmodule PhxMediaLibrary.Workers.ProcessConversions do
    @moduledoc """
    Oban worker for processing media conversions.

    Resolves full `Conversion` definitions from the model's
    `media_conversions/0` callback, ensuring that width, height, quality,
    fit mode, format, and all other options are preserved during async
    processing.

    ## Job Args

    - `"owner_module"` — the string name of the Ecto schema module (e.g. `"Elixir.MyApp.Post"`)
    - `"owner_id"` — the string ID of the parent record
    - `"collection_name"` — the collection name string (e.g. `"images"`)
    - `"item_uuid"` — the UUID of the media item
    - `"conversions"` — list of conversion name strings (e.g. `["thumb", "preview"]`)
    """

    use Oban.Worker,
      queue: :media,
      max_attempts: 3

    alias PhxMediaLibrary.{Conversion, Conversions, ModelRegistry}

    require Logger

    @impl Oban.Worker
    def perform(%Oban.Job{
          args: %{
            "owner_module" => owner_module_str,
            "owner_id" => owner_id,
            "collection_name" => collection_name,
            "item_uuid" => item_uuid,
            "conversions" => conversion_names
          }
        }) do
      owner_module = safe_to_module(owner_module_str)

      context = %{
        owner_module: owner_module,
        owner_id: owner_id,
        collection_name: collection_name,
        item_uuid: item_uuid
      }

      conversions = resolve_conversions(owner_module, collection_name, conversion_names)

      case conversions do
        [] ->
          Logger.warning(
            "[PhxMediaLibrary] No conversion definitions resolved for " <>
              "#{owner_module_str}##{owner_id} collection=#{collection_name} " <>
              "(requested: #{inspect(conversion_names)})"
          )

          :ok

        conversions ->
          case Conversions.process(context, conversions) do
            :ok -> :ok
            {:error, :media_item_not_found} -> {:discard, :media_not_found}
            {:error, reason} -> {:error, reason}
          end
      end
    end

    # Handle legacy job args that use media_id and mediable_type
    def perform(%Oban.Job{
          args: %{
            "media_id" => media_id,
            "conversions" => _conversion_names,
            "mediable_type" => mediable_type
          }
        }) do
      Logger.warning(
        "[PhxMediaLibrary] Processing legacy Oban job with media_id=#{media_id}. " <>
          "This format is deprecated and will be removed in a future version."
      )

      case ModelRegistry.find_model_module(mediable_type) do
        {:ok, _module} ->
          Logger.warning(
            "[PhxMediaLibrary] Legacy job format cannot be processed with JSONB storage. " <>
              "Job will be discarded. media_id=#{media_id}"
          )

          {:discard, :legacy_job_format}

        :error ->
          {:discard, :legacy_job_format}
      end
    end

    # -------------------------------------------------------------------------
    # Conversion Resolution
    # -------------------------------------------------------------------------

    @doc false
    def resolve_conversions(owner_module, collection_name, conversion_names) do
      requested_atoms = Enum.map(conversion_names, &safe_to_atom/1)
      collection_atom = safe_to_atom(collection_name)

      # Ensure the module is loaded before checking for exported functions.
      # Async processors run in separate processes where the module may not
      # be loaded yet.
      Code.ensure_loaded(owner_module)

      has_conversions? =
        function_exported?(owner_module, :get_media_conversions, 1) or
          function_exported?(owner_module, :media_conversions, 0)

      if has_conversions? do
        owner_module
        |> ModelRegistry.get_model_conversions(collection_atom)
        |> Enum.filter(fn %Conversion{name: name} -> name in requested_atoms end)
      else
        Logger.warning(
          "[PhxMediaLibrary] Could not resolve conversions for #{inspect(owner_module)}. " <>
            "Falling back to name-only conversions (no dimensions/quality/format)."
        )

        requested_atoms
        |> Enum.map(&Conversion.new(&1, []))
      end
    rescue
      error ->
        Logger.warning(
          "[PhxMediaLibrary] Error resolving conversions for #{inspect(owner_module)}: #{inspect(error)}. " <>
            "Falling back to name-only conversions."
        )

        conversion_names
        |> Enum.map(&safe_to_atom/1)
        |> Enum.map(&Conversion.new(&1, []))
    end

    @doc false
    defdelegate find_model_module(mediable_type), to: ModelRegistry

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    defp safe_to_module(str) when is_binary(str) do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> String.to_atom(str)
    end

    defp safe_to_atom(value) when is_atom(value), do: value

    defp safe_to_atom(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> String.to_atom(value)
    end
  end
end
