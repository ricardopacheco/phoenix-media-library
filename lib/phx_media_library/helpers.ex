defmodule PhxMediaLibrary.Helpers do
  @moduledoc false
  # Internal helpers shared across PhxMediaLibrary modules.

  alias PhxMediaLibrary.Config

  # From get_owner_type/1 (duplicated in phx_media_library.ex, media_adder.ex, conversions.ex)
  def owner_type(model) do
    if function_exported?(model.__struct__, :__media_type__, 0) do
      model.__struct__.__media_type__()
    else
      if function_exported?(model.__struct__, :__schema__, 1) do
        model.__struct__.__schema__(:source)
      else
        model.__struct__ |> Module.split() |> List.last() |> Macro.underscore()
      end
    end
  end

  # Module-based variant (duplicated in 3 mix tasks as resolve_owner_type/1)
  def owner_type_for_module(module) do
    cond do
      function_exported?(module, :__media_type__, 0) -> module.__media_type__()
      function_exported?(module, :__schema__, 1) -> module.__schema__(:source)
      true -> module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  # From get_media_column/1 (duplicated in phx_media_library.ex, media_adder.ex, conversions.ex)
  def media_column(model) do
    if function_exported?(model.__struct__, :__media_column__, 0) do
      model.__struct__.__media_column__()
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
  def sanitize_name(filename) do
    filename
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  # From get_collection_config/2 (duplicated in phx_media_library.ex, media_adder.ex, live_upload.ex)
  def collection_config(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_collection, 1) do
      model.__struct__.get_media_collection(collection_name)
    else
      nil
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
