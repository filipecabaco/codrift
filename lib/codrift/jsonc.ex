defmodule Codrift.JSONC do
  @moduledoc """
  Reads JSONC (JSON with comments), the format used by editor-style config
  files such as `~/.config/opencode/opencode.jsonc`.

  `JSON.decode!/1` rejects `//` and `/* */` comments, so they are removed first.
  Comment markers inside string literals are preserved — stripping those would
  truncate any value containing `//`, which includes every `https://` URL.
  """

  @doc """
  Decodes JSONC content, raising `JSON.DecodeError` if the result is not valid
  JSON.
  """
  @spec decode!(binary()) :: term()
  def decode!(content), do: content |> strip_comments() |> JSON.decode!()

  @doc """
  Removes `//` line and `/* */` block comments, leaving string literals intact.
  """
  @spec strip_comments(binary()) :: binary()
  def strip_comments(content) when is_binary(content), do: outside(content, [])

  defp outside(<<>>, acc), do: to_binary(acc)
  defp outside(<<"//", rest::binary>>, acc), do: outside(skip_line(rest), acc)
  defp outside(<<"/*", rest::binary>>, acc), do: outside(skip_block(rest), acc)
  defp outside(<<?", rest::binary>>, acc), do: in_string(rest, [?" | acc])
  defp outside(<<c, rest::binary>>, acc), do: outside(rest, [c | acc])

  defp in_string(<<>>, acc), do: to_binary(acc)
  defp in_string(<<?\\, c, rest::binary>>, acc), do: in_string(rest, [c, ?\\ | acc])
  defp in_string(<<?", rest::binary>>, acc), do: outside(rest, [?" | acc])
  defp in_string(<<c, rest::binary>>, acc), do: in_string(rest, [c | acc])

  # The newline is left in place so decode errors still report the right line.
  defp skip_line(<<>>), do: <<>>
  defp skip_line(<<?\n, _::binary>> = rest), do: rest
  defp skip_line(<<_, rest::binary>>), do: skip_line(rest)

  defp skip_block(<<>>), do: <<>>
  defp skip_block(<<"*/", rest::binary>>), do: rest
  defp skip_block(<<_, rest::binary>>), do: skip_block(rest)

  defp to_binary(acc), do: acc |> Enum.reverse() |> :binary.list_to_bin()
end
