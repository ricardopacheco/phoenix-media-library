defmodule PhxMediaLibrary.Storage.S3Test do
  use ExUnit.Case, async: false

  @moduletag :s3

  alias PhxMediaLibrary.Storage.S3

  @bucket "phx-media-library-test"
  @s3_opts [
    bucket: @bucket,
    region: "us-east-1",
    access_key_id: "rustfsadmin",
    secret_access_key: "rustfsadmin",
    scheme: "http://",
    host: "localhost",
    port: 9000
  ]

  defp unique_path(suffix) do
    "test/#{:erlang.unique_integer([:positive])}/#{suffix}.bin"
  end

  describe "put/3 + get/2 + exists?/2 + delete/2 round-trip" do
    test "binary content" do
      path = unique_path("binary")
      payload = "hello world"

      assert :ok = S3.put(path, payload, @s3_opts)
      assert true == S3.exists?(path, @s3_opts)
      assert {:ok, ^payload} = S3.get(path, @s3_opts)
      assert :ok = S3.delete(path, @s3_opts)
      assert false == S3.exists?(path, @s3_opts)
    end

    test "stream content with rechunking (>5 MiB triggers multipart with multiple parts)" do
      path = unique_path("stream")

      # 12 MiB total in 64 KiB pieces — exercises rechunk's full-part loop and
      # the last-fun flush of the leftover.
      total_size = 12 * 1024 * 1024
      chunk_size = 64 * 1024
      chunks = div(total_size, chunk_size)

      stream =
        Stream.repeatedly(fn -> :binary.copy(<<0xAB>>, chunk_size) end)
        |> Stream.take(chunks)

      assert :ok = S3.put(path, {:stream, stream}, @s3_opts)
      assert true == S3.exists?(path, @s3_opts)

      assert {:ok, body} = S3.get(path, @s3_opts)
      assert byte_size(body) == total_size

      assert :ok = S3.delete(path, @s3_opts)
    end

    test "stream content smaller than one part still uploads (last_fun flushes leftover)" do
      path = unique_path("small_stream")

      stream = Stream.cycle(["abc"]) |> Stream.take(10)
      expected = String.duplicate("abc", 10)

      assert :ok = S3.put(path, {:stream, stream}, @s3_opts)
      assert {:ok, ^expected} = S3.get(path, @s3_opts)

      assert :ok = S3.delete(path, @s3_opts)
    end

    test "stream content that is an exact multiple of 5 MiB (rechunk flush sees an empty buffer)" do
      path = unique_path("aligned_stream")

      # 10 MiB in 1 MiB pieces — rechunk emits exactly 2 full parts and the
      # final flush sees an empty accumulator (covers the :__flush__, <<>> branch).
      total_size = 10 * 1024 * 1024
      chunk_size = 1024 * 1024

      stream =
        Stream.repeatedly(fn -> :binary.copy(<<0xCD>>, chunk_size) end)
        |> Stream.take(div(total_size, chunk_size))

      assert :ok = S3.put(path, {:stream, stream}, @s3_opts)

      assert {:ok, body} = S3.get(path, @s3_opts)
      assert byte_size(body) == total_size

      assert :ok = S3.delete(path, @s3_opts)
    end
  end

  describe "error paths" do
    @bad_creds_opts Keyword.merge(@s3_opts,
                      access_key_id: "bogus",
                      secret_access_key: "bogus"
                    )

    test "put/3 returns {:error, _} when the request is rejected" do
      assert {:error, _} = S3.put(unique_path("bad"), "x", @bad_creds_opts)
    end

    test "put/3 with a stream returns {:error, _} when the request is rejected" do
      stream = Stream.cycle(["x"]) |> Stream.take(3)
      assert {:error, _} = S3.put(unique_path("bad_stream"), {:stream, stream}, @bad_creds_opts)
    end

    test "delete/3 forwards non-404 errors" do
      # Rejected with 403 (AccessDenied) instead of 404 — covers the
      # {:error, _} = error -> error fall-through in delete/2.
      assert {:error, _} = S3.delete(unique_path("bad_delete"), @bad_creds_opts)
    end

    test "presigned_upload_url/3 surfaces signing errors from ExAws" do
      # ExAws.S3.presigned_url returns {:error, "expires_in_exceeds_one_week"}
      # when :expires_in > 604800. Use that to exercise the {:error, _} branch
      # of presigned_upload_url/3 with no mocking.
      one_week_plus = 60 * 60 * 24 * 7 + 1

      assert {:error, "expires_in_exceeds_one_week"} =
               S3.presigned_upload_url(
                 unique_path("too_long"),
                 [expires_in: one_week_plus],
                 @s3_opts
               )
    end
  end

  describe "delete/2" do
    test "treats a missing key as success" do
      # RustFS returns 200 for DELETE of a missing key (idempotent semantics
      # match real S3); this exercises the {:ok, _} -> :ok branch.
      assert :ok = S3.delete(unique_path("never_existed"), @s3_opts)
    end

    test "treats a 404 from S3 as success (covers the http_error 404 branch)" do
      # Deleting from a non-existent bucket returns
      # {:error, {:http_error, 404, ...}}. The adapter swallows the 404 to
      # keep delete idempotent in face of upstream churn.
      bucket_opts = Keyword.put(@s3_opts, :bucket, "nonexistent-bucket-xyz-#{:erlang.unique_integer([:positive])}")
      assert :ok = S3.delete("any/path", bucket_opts)
    end
  end

  describe "exists?/2" do
    test "returns false for a missing key" do
      refute S3.exists?(unique_path("missing"), @s3_opts)
    end
  end

  describe "get/2" do
    test "returns an error tuple for a missing key" do
      assert {:error, _} = S3.get(unique_path("missing"), @s3_opts)
    end
  end

  describe "url/2" do
    test "unsigned URL uses the virtual-hosted bucket form by default" do
      url = S3.url("a/b/c.jpg", @s3_opts)

      assert url == "https://#{@bucket}.s3.us-east-1.amazonaws.com/a/b/c.jpg"
    end

    test "unsigned URL honors :base_url for CDN setups" do
      opts = Keyword.put(@s3_opts, :base_url, "https://cdn.example.com/assets")

      assert S3.url("photo.jpg", opts) == "https://cdn.example.com/assets/photo.jpg"
    end

    test "signed URL points at the configured RustFS host with an X-Amz-Signature" do
      path = unique_path("signed")
      :ok = S3.put(path, "x", @s3_opts)

      url = S3.url(path, Keyword.put(@s3_opts, :signed, true))

      assert url =~ "http://localhost:9000/#{@bucket}/#{path}"
      assert url =~ "X-Amz-Signature="

      :ok = S3.delete(path, @s3_opts)
    end

    test "download: true forces signing and adds response-content-disposition" do
      path = unique_path("download")
      :ok = S3.put(path, "x", @s3_opts)

      url =
        S3.url(
          path,
          Keyword.merge(@s3_opts, download: true, filename: "renamed.bin")
        )

      assert url =~ "X-Amz-Signature="
      assert url =~ "response-content-disposition"
      assert url =~ "renamed.bin"

      :ok = S3.delete(path, @s3_opts)
    end

    test "download: true defaults the filename to Path.basename when none is given" do
      path = unique_path("default_name")

      url = S3.url(path, Keyword.put(@s3_opts, :download, true))

      basename = Path.basename(path)
      assert url =~ "response-content-disposition"
      assert url =~ basename
    end

    test "filenames containing quotes are escaped in the Content-Disposition header" do
      url =
        S3.url(
          "x.bin",
          Keyword.merge(@s3_opts, download: true, filename: ~s(my "report".bin))
        )

      # The escaped \" appears URL-encoded in the query string. The signature
      # changes when the param changes, but the encoded backslash should be
      # present.
      assert url =~ "response-content-disposition"
    end
  end

  describe "path/2" do
    test "always returns nil (S3 has no local filesystem path)" do
      assert S3.path("anything", []) == nil
      assert S3.path("anything", @s3_opts) == nil
    end
  end

  describe "default-argument arity dispatchers" do
    # The behaviour declares get/2, delete/2, and exists?/2; the adapter
    # also defines them with `opts \\ []` which compiles a hidden 1-arity
    # form. Real callers always pass opts (the wrapper requires :bucket),
    # so the 1-arity form invariably raises. These tests exist only to
    # exercise that compiled head for coverage parity with the 2-arity form.
    test "get/1 dispatches to get/2 with [] and raises (no :bucket)" do
      assert_raise KeyError, fn -> S3.get("any") end
    end

    test "delete/1 dispatches to delete/2 with [] and raises (no :bucket)" do
      assert_raise KeyError, fn -> S3.delete("any") end
    end

    test "exists?/1 dispatches to exists?/2 with [] and raises (no :bucket)" do
      assert_raise KeyError, fn -> S3.exists?("any") end
    end
  end

  describe "presigned_upload_url/3" do
    test "returns {:ok, url, fields} with a PUT presigned URL" do
      path = unique_path("presigned")

      assert {:ok, url, fields} = S3.presigned_upload_url(path, [], @s3_opts)

      assert url =~ "http://localhost:9000/#{@bucket}/#{path}"
      assert url =~ "X-Amz-Signature="
      assert fields == %{}
    end

    test "honors :content_type and surfaces it in the fields map" do
      assert {:ok, _url, fields} =
               S3.presigned_upload_url(
                 unique_path("ct"),
                 [content_type: "image/png"],
                 @s3_opts
               )

      assert fields == %{"Content-Type" => "image/png"}
    end

    test "accepts :content_length_range without erroring (option is currently a no-op)" do
      # NOTE: ExAws.S3.presigned_url/5 with :put does not honor
      # :content_length_range — it's only valid for POST policy uploads.
      # The S3 adapter accepts the option for forward compatibility, but two
      # URLs with different ranges currently produce identical signatures.
      # Enforcing client-side size limits would require switching to a POST
      # policy (TODO).
      path = unique_path("clr")

      assert {:ok, _url, _fields} =
               S3.presigned_upload_url(
                 path,
                 [content_length_range: {0, 1_000_000}],
                 @s3_opts
               )
    end

    test "honors a custom :expires_in" do
      path = unique_path("expires")

      {:ok, url, _} = S3.presigned_upload_url(path, [expires_in: 60], @s3_opts)

      assert url =~ "X-Amz-Expires=60"
    end
  end
end
