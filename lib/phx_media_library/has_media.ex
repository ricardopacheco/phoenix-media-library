defmodule PhxMediaLibrary.HasMedia do
  @moduledoc """
  Adds media management capabilities to an Ecto schema via JSONB.

  Media data is stored in a JSONB column on the schema itself (default:
  `media_data`), eliminating the need for a separate `media` table.

  ## Usage

  1. Add `use PhxMediaLibrary.HasMedia` to your schema
  2. Declare a `:map` field for the JSONB column
  3. Define collections and optionally conversions

  ### Options

  - `:column` - JSONB column name (default: `:media_data`)
  - `:media_type` - Override the type string used in storage paths (default: table name)

  ### Declarative DSL — nested style (recommended)

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          field :media_data, :map, default: %{}
          timestamps()
        end

        media_collections do
          collection :images, disk: :s3, max_files: 20 do
            convert :thumb, width: 150, height: 150, fit: :cover
            convert :preview, width: 800, quality: 85
          end

          collection :documents, accepts: ~w(application/pdf)

          collection :avatar, single_file: true do
            convert :thumb, width: 150, height: 150, fit: :cover
          end
        end
      end

  ### Declarative DSL — flat style

      media_collections do
        collection :images, disk: :s3, max_files: 20
        collection :documents, accepts: ~w(application/pdf)
      end

      media_conversions do
        convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
        convert :preview, width: 800, quality: 85, collections: [:images]
      end

  ### Function-based approach

      def media_collections do
        [
          collection(:images, disk: :local),
          collection(:documents, accepts: ~w(application/pdf)),
          collection(:avatar, single_file: true)
        ]
      end

      def media_conversions do
        [
          conversion(:thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]),
          conversion(:preview, width: 800, quality: 85, collections: [:images])
        ]
      end

  ## Generated Functions

  `use PhxMediaLibrary.HasMedia` generates:

  - `__media_column__/0` — returns the JSONB column name atom
  - `__media_type__/0` — returns the type string for storage paths (defaults to table name)
  - `media_collections/0` — returns the list of collection definitions
  - `media_conversions/0` — returns the list of conversion definitions
  - `get_media_collection/1` — looks up a collection by name
  - `get_media_conversions/1` — returns conversions, optionally filtered by collection

  ## Collection Options

  - `:disk` - Storage disk to use (default: configured default)
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file in collection (default: false)
  - `:max_files` - Maximum number of files to keep
  - `:max_size` - Maximum file size in bytes (e.g. `10_000_000` for 10 MB)
  - `:fallback_url` - URL to use when collection is empty
  - `:verify_content_type` - Verify file content matches declared MIME type (default: true)

  ## Conversion Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - How to fit the image (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - JPEG/WebP quality (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`)
  - `:collections` - Only apply to specific collections

  """

  alias PhxMediaLibrary.{Collection, Conversion}

  # -------------------------------------------------------------------------
  # __using__ — sets up the caller module
  # -------------------------------------------------------------------------

  defmacro __using__(opts) do
    media_type_override = Keyword.get(opts, :media_type)
    column = Keyword.get(opts, :column, :media_data)

    quote do
      import PhxMediaLibrary.HasMedia,
        only: [
          collection: 1,
          collection: 2,
          conversion: 2,
          convert: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL,
        only: [media_collections: 1, media_conversions: 1]

      @before_compile PhxMediaLibrary.HasMedia

      # Store the explicit override (nil if not provided) so we can
      # resolve it in __before_compile__ and has_media() macro.
      Module.put_attribute(__MODULE__, :__phx_media_type_override__, unquote(media_type_override))

      # Store the JSONB column name for media data storage.
      Module.put_attribute(__MODULE__, :__phx_media_column__, unquote(column))

      # Accumulators for the declarative DSL. When the developer uses
      # `media_collections do ... end` or `media_conversions do ... end`,
      # each `collection` / `convert` call inside the block appends to these.
      Module.register_attribute(__MODULE__, :__phx_media_collections__, accumulate: true)
      Module.register_attribute(__MODULE__, :__phx_media_conversions__, accumulate: true)

      # Used by nested `collection ... do convert ... end` blocks to
      # auto-scope conversions to the enclosing collection.
      Module.register_attribute(__MODULE__, :__phx_media_current_collection__, [])
      Module.put_attribute(__MODULE__, :__phx_media_current_collection__, nil)

      # Track whether the DSL blocks were used, so we know whether
      # to use the accumulated values or the default empty list.
      Module.put_attribute(__MODULE__, :__phx_media_collections_dsl__, false)
      Module.put_attribute(__MODULE__, :__phx_media_conversions_dsl__, false)

      # Default implementations that can be overridden by the user.
      # The DSL approach works differently — see __before_compile__.
      def media_collections, do: []
      def media_conversions, do: []

      defoverridable media_collections: 0, media_conversions: 0
    end
  end

  # -------------------------------------------------------------------------
  # __before_compile__ — injects __media_type__/0, DSL results, and helpers
  # -------------------------------------------------------------------------

  defmacro __before_compile__(env) do
    override = Module.get_attribute(env.module, :__phx_media_type_override__)
    user_defined_media_type? = Module.defines?(env.module, {:__media_type__, 0}, :def)

    # JSONB column name (default: :media_data)
    media_column = Module.get_attribute(env.module, :__phx_media_column__) || :media_data

    # DSL-collected items (accumulated in reverse order)
    dsl_collections_used? = Module.get_attribute(env.module, :__phx_media_collections_dsl__)
    dsl_conversions_used? = Module.get_attribute(env.module, :__phx_media_conversions_dsl__)

    dsl_collections =
      env.module
      |> Module.get_attribute(:__phx_media_collections__)
      |> Enum.reverse()

    dsl_conversions =
      env.module
      |> Module.get_attribute(:__phx_media_conversions__)
      |> Enum.reverse()

    media_type_def = build_media_type_def(user_defined_media_type?, override)
    media_column_def = build_media_column_def(media_column)
    helpers = build_helpers()

    dsl_defs =
      build_dsl_defs(
        dsl_collections_used?,
        dsl_conversions_used?,
        dsl_collections,
        dsl_conversions
      )

    quote do
      unquote(media_type_def)
      unquote(media_column_def)
      unquote_splicing(dsl_defs)
      unquote(helpers)
    end
  end

  # Build the __media_type__/0 definition unless the user already defined one.
  defp build_media_type_def(true = _user_defined?, _override), do: nil

  defp build_media_type_def(_user_defined?, override) when not is_nil(override) do
    quote do
      @doc """
      Returns the polymorphic type string used to identify this schema
      in the `mediable_type` column.

      This value was explicitly set via
      `use PhxMediaLibrary.HasMedia, media_type: #{inspect(unquote(override))}`.
      """
      def __media_type__, do: unquote(override)
    end
  end

  defp build_media_type_def(_user_defined?, _override) do
    quote do
      @doc """
      Returns the polymorphic type string used to identify this schema
      in the `mediable_type` column.

      Defaults to the Ecto table name (via `__schema__(:source)`), which
      is the most reliable derivation strategy. For example,
      `MyApp.Post` with `schema "posts"` returns `"posts"`, and
      `MyApp.BlogCategory` with `schema "blog_categories"` returns
      `"blog_categories"`.

      Override this function if you need a custom type string:

          def __media_type__, do: "blog_posts"

      """
      def __media_type__ do
        __MODULE__.__schema__(:source)
      end
    end
  end

  # Build the __media_column__/0 definition that returns the configured JSONB column name.
  defp build_media_column_def(column) do
    quote do
      @doc """
      Returns the JSONB column name used to store media data on this schema.

      Defaults to `:media_data`. Can be overridden via
      `use PhxMediaLibrary.HasMedia, column: :my_column`.
      """
      def __media_column__, do: unquote(column)
    end
  end

  # Build collection/conversion lookup helpers injected into every HasMedia module.
  defp build_helpers do
    quote do
      @doc """
      Get the collection configuration for this model by name.
      """
      def get_media_collection(name) do
        media_collections()
        |> Enum.find(fn %PhxMediaLibrary.Collection{name: n} -> n == name end)
      end

      @doc """
      Get all conversion configurations for this model, optionally filtered
      by collection name.
      """
      def get_media_conversions(collection_name \\ nil) do
        conversions = media_conversions()

        if collection_name do
          Enum.filter(conversions, fn %PhxMediaLibrary.Conversion{collections: cols} ->
            cols == [] or collection_name in cols
          end)
        else
          conversions
        end
      end
    end
  end

  # If the DSL was used, inject media_collections/0 and/or
  # media_conversions/0 that return the accumulated definitions.
  #
  # We use `defoverridable` + `def` to ensure the DSL definition
  # replaces the default empty-list implementation from __using__.
  defp build_dsl_defs(collections_used?, conversions_used?, collections, conversions) do
    List.flatten([
      build_dsl_collections_def(collections_used?, collections),
      build_dsl_conversions_def(conversions_used?, conversions)
    ])
  end

  defp build_dsl_collections_def(true, collections) do
    escaped = Macro.escape(collections)

    quote do
      defoverridable media_collections: 0
      def media_collections, do: unquote(escaped)
    end
  end

  defp build_dsl_collections_def(_, _collections), do: []

  defp build_dsl_conversions_def(true, conversions) do
    escaped = Macro.escape(conversions)

    quote do
      defoverridable media_conversions: 0
      def media_conversions, do: unquote(escaped)
    end
  end

  defp build_dsl_conversions_def(_, _conversions), do: []

  # -------------------------------------------------------------------------
  # Helper functions for building collection/conversion configs
  # -------------------------------------------------------------------------

  @doc """
  Define a media collection.

  Can be used in two ways:

  1. Inside a `media_collections do ... end` block (DSL style — the
     collection is automatically registered):

         media_collections do
           collection :images, disk: :s3
           collection :avatar, single_file: true
         end

  2. Inside a `media_collections/0` function (function style — return a
     list of collections):

         def media_collections do
           [
             collection(:images, disk: :s3),
             collection(:avatar, single_file: true)
           ]
         end

  ## Options

  - `:disk` - Storage disk to use
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file (default: false)
  - `:max_files` - Maximum number of files
  - `:fallback_url` - URL when collection is empty
  - `:fallback_path` - Path when collection is empty

  """
  def collection(name, opts \\ []) do
    Collection.new(name, opts)
  end

  @doc """
  Define a media conversion (function-style).

  Used inside a `media_conversions/0` function return list:

      def media_conversions do
        [
          conversion(:thumb, width: 150, height: 150, fit: :cover),
          conversion(:preview, width: 800, quality: 85)
        ]
      end

  ## Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - Resize strategy (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - Output quality for JPEG/WebP (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:original`)
  - `:collections` - Only apply to these collections (default: all)
  - `:queued` - Process asynchronously (default: true)

  """
  def conversion(name, opts) do
    Conversion.new(name, opts)
  end

  @doc """
  Define a media conversion (DSL-style).

  Used inside a `media_conversions do ... end` block:

      media_conversions do
        convert :thumb, width: 150, height: 150, fit: :cover
        convert :preview, width: 800, quality: 85
        convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
      end

  This is an alias for `conversion/2` — both produce identical
  `PhxMediaLibrary.Conversion` structs. The `convert` name reads more
  naturally in the declarative DSL context.

  ## Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - Resize strategy (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - Output quality for JPEG/WebP (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:original`)
  - `:collections` - Only apply to these collections (default: all)
  - `:queued` - Process asynchronously (default: true)

  """

  def convert(name, opts) do
    Conversion.new(name, opts)
  end
end
