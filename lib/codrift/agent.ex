defmodule Codrift.Agent do
  @callback cmd() :: String.t()
  @callback args(dir :: String.t()) :: [String.t()]
  @callback env(dir :: String.t()) :: [{String.t(), String.t()}]
  @callback parse_status(output :: binary()) :: :idle | :running | :awaiting_input | nil
end
