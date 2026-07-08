defmodule Codrift.AuthToken do
  @moduledoc """
  Stable local API token for non-browser clients of the loopback server.

  Browsers prove themselves to `Codrift.Plugs.LocalGuard` with a loopback
  `Origin` header (which pages cannot forge). Non-browser clients — the MCP
  clients registered by `codrift mcp install`, scripts, curl — instead send
  this token as `X-Codrift-Token` (or `Authorization: Bearer …`).

  The token is generated once and persisted with `0600` permissions at
  `~/.codrift/auth-token`, so only the owning user can read it. It is stable
  across restarts because MCP client registrations embed it in their config.
  """

  @token_bytes 32
  @min_token_chars 32

  @doc "Returns the local API token, generating and persisting it on first use."
  @spec fetch() :: String.t()
  def fetch do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        token = load_or_create()
        :persistent_term.put(__MODULE__, token)
        token

      token ->
        token
    end
  end

  @doc "Path of the persisted token file."
  @spec path() :: String.t()
  def path, do: Path.join(Codrift.Paths.data_dir(), "auth-token")

  defp load_or_create do
    case File.read(path()) do
      {:ok, content} ->
        token = String.trim(content)
        if String.length(token) >= @min_token_chars, do: token, else: create()

      {:error, _} ->
        create()
    end
  end

  # The temp file is chmod'ed 0600 while still empty, so the token content is
  # never on disk with wider permissions; the rename makes it atomic.
  defp create do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    p = path()
    File.mkdir_p!(Path.dirname(p))
    tmp = p <> ".tmp"
    fd = File.open!(tmp, [:write])
    File.chmod!(tmp, 0o600)
    IO.binwrite(fd, token)
    File.close(fd)
    File.rename!(tmp, p)
    token
  end
end
