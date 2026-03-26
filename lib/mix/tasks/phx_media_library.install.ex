defmodule Mix.Tasks.PhxMediaLibrary.Install do
  @moduledoc """
  Installs PhxMediaLibrary in your project.

  This task will:
  1. Generate a migration that adds a JSONB media column to a specified table
  2. Print configuration and usage instructions

  ## Usage

      $ mix phx_media_library.install --table posts
      $ mix phx_media_library.install --table posts --column attachments
      $ mix phx_media_library.install --table posts --no-migration

  ## Options

      --table         Target table name (required)
      --column        JSONB column name (default: "media_data")
      --no-migration  Skip migration generation

  """

  @shortdoc "Installs PhxMediaLibrary in your project"

  use Mix.Task

  import Mix.Generator

  @default_column "media_data"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          no_migration: :boolean,
          table: :string,
          column: :string
        ]
      )

    table = opts[:table]
    column = opts[:column] || @default_column

    unless table do
      Mix.shell().error("Missing required --table option.")
      Mix.shell().error("Usage: mix phx_media_library.install --table <table_name>")
      exit(:shutdown)
    end

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Installation#{IO.ANSI.reset()}
    ================================
    """)

    unless opts[:no_migration] do
      generate_migration(table, column)
    end

    print_configuration_instructions()
    print_usage_instructions(table, column)

    Mix.shell().info("""

    #{IO.ANSI.green()}Installation complete!#{IO.ANSI.reset()}

    Next steps:
    1. Review and run the migration: #{IO.ANSI.cyan()}mix ecto.migrate#{IO.ANSI.reset()}
    2. Add the configuration to your config files
    3. Add #{IO.ANSI.cyan()}use PhxMediaLibrary.HasMedia#{IO.ANSI.reset()} to your schemas

    """)
  end

  defp generate_migration(table, column) do
    Mix.shell().info("#{IO.ANSI.cyan()}Generating migration...#{IO.ANSI.reset()}")

    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    timestamp = generate_timestamp()
    filename = "#{timestamp}_add_#{column}_to_#{table}.exs"
    path = Path.join(migrations_path, filename)

    migration_content = migration_template(table, column)

    create_file(path, migration_content)

    Mix.shell().info("  #{IO.ANSI.green()}Created#{IO.ANSI.reset()} #{path}")
  end

  defp migration_template(table, column) do
    module_name = "Add#{Macro.camelize(column)}To#{Macro.camelize(table)}"

    """
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
  end

  defp print_configuration_instructions do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}Configuration#{IO.ANSI.reset()}
    -------------

    Add the following to your #{IO.ANSI.yellow()}config/config.exs#{IO.ANSI.reset()}:

        config :phx_media_library,
          repo: #{inspect(repo_module())},
          default_disk: :local,
          disks: [
            local: [
              adapter: PhxMediaLibrary.Storage.Disk,
              root: "priv/static/uploads",
              base_url: "/uploads"
            ]
            # Uncomment for S3 support:
            # s3: [
            #   adapter: PhxMediaLibrary.Storage.S3,
            #   bucket: "my-bucket",
            #   region: "us-east-1"
            # ]
          ]

    """)
  end

  defp print_usage_instructions(table, column) do
    schema_module = table |> Macro.camelize() |> String.replace(~r/s$/, "")

    Mix.shell().info("""
    #{IO.ANSI.cyan()}Usage#{IO.ANSI.reset()}
    -----

    Add the JSONB field and HasMedia to your Ecto schema:

        defmodule #{inspect(app_module())}.#{schema_module} do
          use Ecto.Schema
          use PhxMediaLibrary.HasMedia, column: :#{column}

          schema "#{table}" do
            field :title, :string
            field :#{column}, :map, default: %{}
            timestamps()
          end

          media_collections do
            collection :images, disk: :local, max_files: 20 do
              convert :thumb, width: 150, height: 150, fit: :cover
            end

            collection :avatar, single_file: true do
              convert :thumb, width: 150, height: 150, fit: :cover
            end
          end
        end

    Then in your code:

        post
        |> PhxMediaLibrary.add("/path/to/image.jpg")
        |> PhxMediaLibrary.to_collection(:images)

    """)
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

  defp app_module do
    app = Mix.Project.config()[:app]
    app |> to_string() |> Macro.camelize() |> String.to_atom()
  end
end
