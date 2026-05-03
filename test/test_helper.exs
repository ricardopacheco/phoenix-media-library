ExUnit.start()

# Configure the library for testing
Application.put_env(:phx_media_library, :repo, PhxMediaLibrary.TestRepo)

# Run conversions in-process so background Tasks don't outlive the test
# that triggered them (which leaks the Sandbox connection and prints
# `Postgrex.Protocol failed to connect` on stderr).
Application.put_env(:phx_media_library, :async_processor, PhxMediaLibrary.SyncProcessor)

Application.put_env(:phx_media_library, :disks,
  local: [
    adapter: PhxMediaLibrary.Storage.Disk,
    root: "priv/static/uploads",
    base_url: "/uploads"
  ],
  memory: [
    adapter: PhxMediaLibrary.Storage.Memory,
    base_url: "/test-uploads"
  ],
  s3_test: [
    adapter: PhxMediaLibrary.Storage.S3,
    bucket: "phx-media-library-test",
    region: "us-east-1",
    access_key_id: "rustfsadmin",
    secret_access_key: "rustfsadmin",
    scheme: "http://",
    host: "localhost",
    port: 9000
  ]
)

# Start the Memory storage agent for tests that need it
{:ok, _} = PhxMediaLibrary.Storage.Memory.start_link()

# Start the TestRepo for integration tests that need a real database.
# If Postgres is not available, repo-dependent tests will be excluded
# via the :db tag.
db_available? =
  case PhxMediaLibrary.TestRepo.start_link() do
    {:ok, _pid} ->
      # Run migrations programmatically so the test DB is always up to date
      migrations_path =
        Path.join([
          Application.app_dir(:phx_media_library),
          "..",
          "..",
          "priv",
          "repo",
          "migrations"
        ])

      migrations_path =
        if File.dir?(migrations_path) do
          migrations_path
        else
          # Fallback for running from the project root
          Path.join(["priv", "repo", "migrations"])
        end

      if File.dir?(migrations_path) do
        Ecto.Migrator.run(PhxMediaLibrary.TestRepo, migrations_path, :up, all: true, log: false)
      end

      # Configure the sandbox mode for the repo
      Ecto.Adapters.SQL.Sandbox.mode(PhxMediaLibrary.TestRepo, :manual)
      true

    {:error, _reason} ->
      false
  end

# Exclude integration tests if the database is not available
unless db_available? do
  ExUnit.configure(exclude: [:db])
end

# Detect a running RustFS (S3-compatible) instance at localhost:9000 and
# pre-create the test bucket. When unreachable, exclude :s3 tagged tests.
s3_available? =
  try do
    bucket = "phx-media-library-test"

    request_opts = [
      access_key_id: "rustfsadmin",
      secret_access_key: "rustfsadmin",
      region: "us-east-1",
      scheme: "http://",
      host: "localhost",
      port: 9000
    ]

    # Idempotent: PUT bucket succeeds whether or not it already exists.
    case ExAws.S3.put_bucket(bucket, "us-east-1") |> ExAws.request(request_opts) do
      {:ok, _} ->
        true

      {:error, {:http_error, status, _}} when status in [409] ->
        # 409 = bucket already exists and owned by us
        true

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

unless s3_available? do
  ExUnit.configure(exclude: [:s3])
end
