defmodule Mix.Tasks.PhxMediaLibrary.Gen.Migration do
  @moduledoc """
  Generates a migration that adds a JSONB media column to a table.

  ## Usage

      $ mix phx_media_library.gen.migration posts
      $ mix phx_media_library.gen.migration posts media_data
      $ mix phx_media_library.gen.migration users attachments

  ## Arguments

      TABLE_NAME    The target table (required)
      COLUMN_NAME   The JSONB column name (default: "media_data")

  """

  @shortdoc "Generates a migration to add a JSONB media column"

  use Mix.Task

  import Mix.Generator

  @default_column "media_data"

  @impl Mix.Task
  def run(args) do
    case args do
      [table | rest] ->
        column = List.first(rest) || @default_column
        generate_migration(table, column)

      [] ->
        Mix.shell().error("Usage: mix phx_media_library.gen.migration <table> [column]")
        exit(:shutdown)
    end
  end

  defp generate_migration(table, column) do
    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    timestamp = generate_timestamp()
    snake_name = "add_#{column}_to_#{table}"
    filename = "#{timestamp}_#{snake_name}.exs"
    path = Path.join(migrations_path, filename)

    module_name = "Add#{Macro.camelize(column)}To#{Macro.camelize(table)}"

    content = """
    defmodule #{inspect(repo_module())}.Migrations.#{module_name} do
      use Ecto.Migration

      def change do
        alter table(:#{table}) do
          add :#{column}, :map, default: %{}, null: false
        end

        create index(:#{table}, [:#{column}], using: "GIN")
      end
    end
    """

    create_file(path, content)
    Mix.shell().info("Created #{path}")
  end

  defp generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"

  defp repo_module do
    app = Mix.Project.config()[:app]
    app_module = app |> to_string() |> Macro.camelize() |> String.to_atom()
    Module.concat([app_module, Repo])
  end
end
