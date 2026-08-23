defmodule Codrift.Integration.ErrorTest do
  @moduledoc """
  What a failed integration call says to the user.

  The case that drove this module: a day-old Linear token made the initiative
  picker render

      Linear unavailable — HTTP 401: %{"errors" => [%{"extensions" => %{"code" => ...

  which is an inspected Elixir map, tells the reader nothing they can act on,
  and hides the one fact that mattered — that reconnecting would have fixed it.
  These tests pin both halves of the replacement: the sentence, and the `:kind`
  the UI branches on to decide whether to offer a Reconnect button.
  """
  use ExUnit.Case, async: true

  alias Codrift.Integration.Error
  alias Codrift.Integration.HTTP

  describe "explain/2 on a failed response body" do
    test "prefers the provider's own end-user wording over the developer message" do
      body = %{
        "errors" => [
          %{
            "message" => "Authentication required, not authenticated",
            "extensions" => %{
              "code" => "AUTHENTICATION_ERROR",
              "userPresentableMessage" => "You need to authenticate to access this operation."
            }
          }
        ]
      }

      assert HTTP.explain(401, body) ==
               "You need to authenticate to access this operation. (HTTP 401)"
    end

    test "falls back through the shapes different providers use" do
      # GitHub REST
      assert HTTP.explain(404, %{"message" => "Not Found"}) == "Not Found (HTTP 404)"
      # OAuth token endpoints
      assert HTTP.explain(400, %{"error_description" => "code is invalid"}) ==
               "code is invalid (HTTP 400)"

      assert HTTP.explain(400, %{"error" => "invalid_grant"}) == "invalid_grant (HTTP 400)"
    end

    test "accepts an undecoded JSON string body, which is what Req hands back" do
      assert HTTP.explain(403, ~s({"message":"API rate limit exceeded"})) ==
               "API rate limit exceeded (HTTP 403)"
    end

    test "truncates a body that is not a message at all" do
      html = "<html>" <> String.duplicate("x", 500) <> "</html>"
      explained = HTTP.explain(502, html)

      assert String.ends_with?(explained, "(HTTP 502)")
      # Long enough to hint at what came back, short enough for a one-line slot.
      assert String.length(explained) < 250
    end

    test "says only the status when the body carries nothing usable" do
      assert HTTP.explain(500, "") == "HTTP 500"
      assert HTTP.explain(500, %{"data" => nil}) == "HTTP 500"
    end
  end

  describe "from_graphql/2" do
    # GraphQL answers 200 with the failure in the body, so the status-based
    # classification in HTTP never sees these.
    test "reads an expired session out of a 200 response" do
      errors = [
        %{
          "message" => "Authentication required, not authenticated",
          "extensions" => %{"code" => "AUTHENTICATION_ERROR", "statusCode" => 401}
        }
      ]

      error = Error.from_graphql(errors, "linear")

      assert error.kind == :auth
      assert Error.reauth?(error)
      assert to_string(error) == "Linear session expired"
    end

    test "recognises GitHub's spelling of the same thing" do
      errors = [%{"message" => "Bad credentials", "extensions" => %{"code" => "UNAUTHENTICATED"}}]

      assert %Error{kind: :auth} = Error.from_graphql(errors, "github_projects")
    end

    test "an ordinary query error stays an ordinary error" do
      errors = [%{"message" => "Field 'nope' doesn't exist on type 'Issue'"}]
      error = Error.from_graphql(errors, "linear")

      assert error.kind == :http
      refute Error.reauth?(error)
      assert to_string(error) == "Field 'nope' doesn't exist on type 'Issue'"
    end

    test "joins several distinct messages and drops duplicates" do
      errors = [%{"message" => "a"}, %{"message" => "b"}, %{"message" => "a"}]

      assert to_string(Error.from_graphql(errors, "linear")) == "a; b"
    end
  end

  describe "to_map/2" do
    test "keeps the kind so the UI can offer Reconnect" do
      error = Error.reauth("linear")

      assert Error.to_map(error, "linear") == %{
               service: "linear",
               reason: "Linear session expired",
               kind: :auth
             }
    end

    test "accepts a plain string from an adapter that returns one" do
      assert Error.to_map("timed out", "gitlab") == %{
               service: "gitlab",
               reason: "timed out",
               kind: :http
             }
    end
  end

  describe "label/1" do
    test "renders service keys the way the vendors spell them" do
      assert Error.label("linear") == "Linear"
      assert Error.label("linear_projects") == "Linear Projects"
      assert Error.label("github") == "GitHub"
      assert Error.label("github_projects") == "GitHub Projects"
      assert Error.label("gitlab") == "GitLab"
    end
  end

  describe "String.Chars" do
    test "an Error prints as its message, so existing to_string/1 call sites keep working" do
      assert to_string(Error.new(:http, "something broke")) == "something broke"
      assert "#{Error.new(:http, "something broke")}" == "something broke"
    end
  end
end
