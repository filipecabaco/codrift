defmodule Codrift.Integration.Error do
  @moduledoc """
  A failure from an external service, in a shape the UI can act on.

  Adapters and `Codrift.Integration.HTTP` return one of these instead of a
  formatted string, because a string only carries half of what a caller needs.
  The other half is `:kind` — it is what decides whether the picker offers a
  *Reconnect* button or merely reports that a service is down, and no amount of
  matching on message text does that reliably.

  `String.Chars` is implemented on purpose: the many call sites that already do
  `to_string(reason)` keep working unchanged and start printing the readable
  sentence instead of an inspected response body.
  """

  @typedoc """
  What went wrong, coarse enough for the UI to branch on.

  `:auth` is the only one that means *the user can fix this* — everything else
  is the service's problem or the request's.
  """
  @type kind :: :auth | :forbidden | :not_found | :rate_limited | :http | :network

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          service: String.t() | nil,
          status: pos_integer() | nil
        }

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, :service, :status]

  @doc """
  The "your session is over, sign in again" error.

  Phrased as the end of a *session* rather than the expiry of a token: what the
  user has to do is reconnect, and the distinction between an expired access
  token, a spent refresh token and a revoked grant is not theirs to care about.
  """
  @spec reauth(String.t(), String.t() | nil) :: t()
  def reauth(service, detail \\ nil) do
    %__MODULE__{
      kind: :auth,
      service: service,
      status: 401,
      message: "#{label(service)} session expired#{suffix(detail)}"
    }
  end

  @doc "Wraps a message from an adapter that is not an HTTP failure."
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message,
      service: Keyword.get(opts, :service),
      status: Keyword.get(opts, :status)
    }
  end

  @doc """
  Classifies the `errors` array a GraphQL API returns *alongside HTTP 200*.

  GraphQL reports an expired token in the response body while the transport
  still says 200, so the status-based classification in
  `Codrift.Integration.HTTP` never sees it. Reading the provider's own
  `extensions.code` is what keeps a stale Linear session offering Reconnect
  instead of reading as a generic outage.
  """
  @spec from_graphql([map()], String.t()) :: t()
  def from_graphql(errors, service) do
    if Enum.any?(errors, &auth_error?/1) do
      reauth(service)
    else
      new(:http, gql_message(errors), service: service)
    end
  end

  # Linear says AUTHENTICATION_ERROR, GitHub says UNAUTHENTICATED; the nested
  # `status` is the same 401 the transport would have carried had this not been
  # a 200-with-errors response.
  defp auth_error?(%{"extensions" => extensions}) when is_map(extensions) do
    extensions["code"] in ["AUTHENTICATION_ERROR", "UNAUTHENTICATED"] or
      extensions["statusCode"] == 401 or get_in(extensions, ["http", "status"]) == 401
  end

  defp auth_error?(_), do: false

  defp gql_message(errors) do
    errors
    |> Enum.map(&single_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "the request was rejected"
      messages -> Enum.join(messages, "; ")
    end
  end

  # `userPresentableMessage` is the provider's own wording for an end user, so it
  # wins over the developer-facing `message` whenever both are present.
  defp single_message(%{"extensions" => %{"userPresentableMessage" => message}})
       when is_binary(message),
       do: message

  defp single_message(%{"message" => message}) when is_binary(message), do: message
  defp single_message(_), do: nil

  @doc "Whether re-running the OAuth flow is what would fix this."
  @spec reauth?(t() | term()) :: boolean()
  def reauth?(%__MODULE__{kind: :auth}), do: true
  def reauth?(_), do: false

  @doc """
  Renders any error term as the pair the UI consumes.

  Takes bare strings and atoms too, so callers do not have to know whether the
  adapter they just called has been converted to structured errors yet.
  """
  @spec to_map(t() | term(), String.t()) :: %{
          service: String.t(),
          reason: String.t(),
          kind: atom()
        }
  def to_map(%__MODULE__{} = error, service) do
    %{service: error.service || service, reason: error.message, kind: error.kind}
  end

  def to_map(reason, service) do
    %{service: service, reason: to_string(reason), kind: :http}
  end

  @doc ~S(Display name for a service key, e.g. `"linear_projects"` -> `"Linear Projects"`.)
  @spec label(String.t() | nil) :: String.t()
  def label(nil), do: "The service"

  def label(service) do
    service
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "Github" <> rest -> "GitHub" <> rest
      "Gitlab" <> rest -> "GitLab" <> rest
      other -> other
    end
  end

  defp suffix(nil), do: ""
  defp suffix(detail), do: " — #{detail}"

  defimpl String.Chars do
    def to_string(%{message: message}), do: message
  end
end
