defmodule PhxMediaLibrary.Plug.MediaDownloadTest do
  # Changes the global :disks env.
  use ExUnit.Case, async: false

  import Plug.Test

  alias PhxMediaLibrary.Plug.MediaDownload
  alias PhxMediaLibrary.SignedUrl

  @secret "test-secret-at-least-32-bytes-long!!"

  setup do
    base = Path.join(System.tmp_dir!(), "phx_media_plug_#{:erlang.unique_integer([:positive])}")
    root = Path.join(base, "media")
    File.mkdir_p!(Path.join(root, "posts/1/abc"))
    File.write!(Path.join(root, "posts/1/abc/notes.txt"), "hello")
    File.write!(Path.join(base, "secret.txt"), "outside")

    original = Application.get_env(:phx_media_library, :disks)

    Application.put_env(:phx_media_library, :disks,
      local: [
        adapter: PhxMediaLibrary.Storage.Disk,
        root: root,
        base_url: "/uploads",
        secret_key_base: @secret
      ]
    )

    on_exit(fn ->
      Application.put_env(:phx_media_library, :disks, original)
      File.rm_rf!(base)
    end)

    :ok
  end

  defp request(path, opts \\ []) do
    conn(:get, path) |> MediaDownload.call(MediaDownload.init([disk: :local] ++ opts))
  end

  test "serves the file with nosniff and no-store" do
    conn = request("/posts/1/abc/notes.txt")

    assert conn.status == 200
    assert conn.resp_body == "hello"
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert conn.halted
  end

  test "dl=1 adds an attachment Content-Disposition" do
    conn = request("/posts/1/abc/notes.txt?dl=1")

    assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "notes.txt"
  end

  test "a missing file is 404" do
    assert request("/posts/1/abc/missing.txt").status == 404
  end

  test "a path leaving the root is 403" do
    assert request("/../secret.txt").status == 403
  end

  describe "require_signed: true" do
    test "refuses unsigned requests" do
      assert request("/posts/1/abc/notes.txt", require_signed: true).status == 403
    end

    test "serves a valid signature" do
      {token, exp} = SignedUrl.sign("posts/1/abc/notes.txt", secret_key_base: @secret)
      conn = request("/posts/1/abc/notes.txt?sign=#{token}&exp=#{exp}", require_signed: true)

      assert conn.status == 200
      assert conn.resp_body == "hello"
    end

    test "refuses a signature for another path" do
      {token, exp} = SignedUrl.sign("posts/1/abc/other.txt", secret_key_base: @secret)

      assert request("/posts/1/abc/notes.txt?sign=#{token}&exp=#{exp}", require_signed: true).status ==
               403
    end
  end
end
