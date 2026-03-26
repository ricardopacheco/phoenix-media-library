defmodule PhxMediaLibrary.TestRepo.Migrations.AddMediaDataToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :media_data, :map, default: %{}, null: false
    end
  end
end
