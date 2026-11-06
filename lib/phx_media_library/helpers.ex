defmodule PhxMediaLibrary.Helpers do
  @moduledoc false
  # Internal helpers shared across PhxMediaLibrary modules.

  alias PhxMediaLibrary.{Collection, Config, MediaData}

  # From get_owner_type/1 (duplicated in phx_media_library.ex, media_adder.ex, conversions.ex)
  def owner_type(model) do
    module = model.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :__media_type__, 0) do
      module.__media_type__()
    else
      if function_exported?(module, :__schema__, 1) do
        module.__schema__(:source)
      else
        module |> Module.split() |> List.last() |> Macro.underscore()
      end
    end
  end

  def owner_type_for_module(module) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :__media_type__, 0) -> module.__media_type__()
      function_exported?(module, :__schema__, 1) -> module.__schema__(:source)
      true -> module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  def media_column(model) do
    module = model.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :__media_column__, 0) do
      module.__media_column__()
    else
      :media_data
    end
  end

  # From update_model_media_data/2 (duplicated in phx_media_library.ex, media_adder.ex)
  def update_media_data(model, update_fn) do
    column = media_column(model)
    fresh = Config.repo().get!(model.__struct__, model.id)
    current = Map.get(fresh, column) || %{}
    updated = update_fn.(current)
    fresh |> Ecto.Changeset.change(%{column => updated}) |> Config.repo().update!()
  end

  # From sanitize_name/1 (duplicated in phx_media_library.ex, media_adder.ex)
  def sanitize_name(filename), do: PhxMediaLibrary.FileName.slug(filename)

  # The model's Collection for `collection_name` (atom or string), or nil.
  # Strings are matched against the declared names, never turned into atoms
  # (collection names read back from JSONB are strings).
  def collection_config(model, collection_name) do
    module = model.__struct__
    Code.ensure_loaded(module)

    cond do
      is_atom(collection_name) and function_exported?(module, :get_media_collection, 1) ->
        module.get_media_collection(collection_name)

      function_exported?(module, :media_collections, 0) ->
        name = to_string(collection_name)
        Enum.find(module.media_collections(), &(to_string(&1.name) == name))

      true ->
        nil
    end
  end

  # The model's conversion definitions for a collection.
  def conversions(model, collection_name) do
    module = model.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :get_media_conversions, 1) do
      module.get_media_conversions(collection_name)
    else
      []
    end
  end

  # The `order` for the next item added to a collection.
  def next_order(model, collection_name) do
    model |> media_data() |> MediaData.count(collection_name)
  end

  # Applies the collection's `single_file` / `max_files` limits after
  # `new_item` was added: deletes the files of the excess items (oldest first)
  # and removes them from the JSONB in a single write. `max_files: 0` means
  # no limit.
  def enforce_collection_limits(model, collection_name, new_item) do
    case excess_items(model, collection_name, new_item) do
      [] ->
        :ok

      excess ->
        Enum.each(excess, &PhxMediaLibrary.Media.delete_files/1)
        uuids = Enum.map(excess, & &1.uuid)
        update_media_data(model, &remove_items(&1, collection_name, uuids))
        :ok
    end
  end

  defp remove_items(data, collection_name, uuids) do
    Enum.reduce(uuids, data, fn uuid, acc ->
      {_removed, updated} = MediaData.remove_item(acc, collection_name, uuid)
      updated
    end)
  end

  defp excess_items(model, collection_name, new_item) do
    items = fn ->
      model
      |> media_data()
      |> MediaData.get_collection(collection_name,
        owner_type: new_item.owner_type,
        owner_id: new_item.owner_id
      )
    end

    case collection_config(model, collection_name) do
      %Collection{single_file: true} ->
        Enum.reject(items.(), &(&1.uuid == new_item.uuid))

      %Collection{max_files: max} when is_integer(max) and max > 0 ->
        all = items.()
        Enum.take(all, max(length(all) - max, 0))

      _ ->
        []
    end
  end

  # From get_default_disk/2 (duplicated in phx_media_library.ex, media_adder.ex)
  def default_disk(model, collection_name) do
    case collection_config(model, collection_name) do
      %{disk: disk} when not is_nil(disk) -> disk
      _ -> Config.default_disk()
    end
  end

  # From conversion_key/1 (duplicated in media.ex, responsive_images.ex)
  def conversion_key(nil), do: "original"
  def conversion_key(conversion), do: to_string(conversion)

  # Read media data from model's JSONB column
  def media_data(model) do
    column = media_column(model)
    Map.get(model, column) || %{}
  end
end
