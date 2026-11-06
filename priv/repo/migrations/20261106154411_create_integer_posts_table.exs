defmodule PhxMediaLibrary.TestRepo.Migrations.CreateIntegerPostsTable do
  use Ecto.Migration

  # A parent table with the default `bigserial` primary key, used to verify
  # that media works for schemas whose primary key is not a UUID.
  def change do
    create table(:integer_posts) do
      add :title, :string
      add :media_data, :map, default: %{}, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
