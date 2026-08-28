defmodule Codrift.OAuth.CallbackTest do
  @moduledoc """
  Which path a PKCE callback is allowed to arrive on.

  Linear Issues and Linear Projects are two views of one Linear workspace behind
  one registered OAuth app, and a provider only redirects to a URI that app
  registered. Deriving the redirect from the *service* asked Linear to redirect
  to `/oauth/callback/linear_projects`, which it answered with "Invalid
  redirect_uri parameter for the application" — the Projects integration could
  never be connected at all.

  Not `async`: the PKCE state store is a globally-named Agent.
  """
  use ExUnit.Case, async: false

  alias Codrift.OAuth
  alias Codrift.OAuth.Config

  # Starts a real PKCE flow (no network — it only mints and stores state) and
  # hands back the parameters the provider would be sent.
  defp start(service) do
    {:ok, %{auth_url: url}} = OAuth.start_flow(service)
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  test "a service sharing an app asks the provider for that app's redirect" do
    assert start("linear_projects")["redirect_uri"] ==
             "http://127.0.0.1:43117/oauth/callback/linear"
  end

  # The accepting direction is asserted through `callback_name/1` rather than
  # `handle_callback/3`: passing verification puts the flow straight into the
  # token exchange, and a test that has to reach api.linear.app to prove a
  # routing rule is a test that fails on a train.
  test "its callback is accepted on the app's path" do
    assert Config.callback_name("linear_projects") == "linear"
  end

  test "its callback is refused on its own name, which no app registered" do
    params = start("linear_projects")

    assert {:error, message} =
             OAuth.handle_callback("linear_projects", "the-code", params["state"])

    assert message =~ "expected linear"
  end

  test "a callback carrying another provider's state is refused" do
    params = start("linear_projects")

    assert {:error, message} = OAuth.handle_callback("gitlab", "the-code", params["state"])
    assert message =~ "expected linear"
  end

  test "a service with an app of its own is unaffected" do
    params = start("gitlab")

    assert params["redirect_uri"] == Config.redirect_uri("gitlab")
    assert {:error, message} = OAuth.handle_callback("linear", "the-code", params["state"])
    assert message =~ "expected gitlab"
  end
end
