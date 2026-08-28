defmodule Codrift.OAuth.ConfigTest do
  @moduledoc """
  The service table and the URL it builds.

  Worth pinning because every value here is agreed with a third party *at
  registration time* and cannot be renegotiated at runtime: a redirect URI that
  drifts from what the provider stored fails the whole flow with a generic
  "redirect_uri mismatch", far from the line that changed it.

  `async: false` — `resolve_client_id/2` reads process-wide env vars.
  """
  use ExUnit.Case, async: false

  alias Codrift.OAuth.Config

  describe "the service table" do
    test "every supported service resolves, and none is in both flow lists" do
      pkce = Config.pkce_services()
      device = Config.device_flow_services()

      assert Enum.sort(pkce ++ device) == Config.supported_services()
      assert [] == pkce -- (pkce -- device), "a service cannot use two flows"
    end

    test "the flow lists match the flow each config declares" do
      for service <- Config.pkce_services() do
        assert {:ok, %{flow: :pkce_browser}} = Config.get(service)
      end

      for service <- Config.device_flow_services() do
        assert {:ok, %{flow: :device_flow}} = Config.get(service)
      end
    end

    test "every service carries the endpoints its flow needs" do
      for service <- Config.supported_services() do
        {:ok, config} = Config.get(service)

        assert is_binary(config.token_url)
        assert is_binary(config.client_id_env)

        case config.flow do
          :pkce_browser -> assert is_binary(config.auth_url)
          :device_flow -> assert is_binary(config.device_code_url)
        end
      end
    end

    test "an unknown service is an error naming the service" do
      assert {:error, message} = Config.get("not-a-service")
      assert message =~ "not-a-service"
    end
  end

  describe "redirect_uri/1" do
    test "uses the literal loopback IP and the fixed port" do
      # Not `localhost`: Bandit binds IPv4 only, while localhost may resolve to
      # ::1 first. RFC 8252 §7.3 recommends the literal IP for this reason.
      assert Config.redirect_uri("linear") == "http://127.0.0.1:43117/oauth/callback/linear"
    end

    # A provider will only redirect to a URI its registered app holds, so the
    # callback path has to key off the app. Linear Projects is the same Linear
    # app as Linear — asking for /oauth/callback/linear_projects is what Linear
    # rejected as "Invalid redirect_uri parameter for the application".
    test "services sharing one registered app share its callback" do
      assert Config.redirect_uri("linear_projects") == Config.redirect_uri("linear")
      assert Config.callback_name("linear_projects") == "linear"
    end

    test "a service with an app of its own calls back on its own name" do
      for service <- Config.supported_services(), service != "linear_projects" do
        assert Config.callback_name(service) == service
      end
    end

    # Two services may only share a callback when the same registered app sits
    # behind both. Anything else routes a code minted by one provider onto
    # another provider's path.
    test "services sharing a callback are the same registered app" do
      Config.supported_services()
      |> Enum.group_by(&Config.callback_name/1)
      |> Enum.each(fn {_callback, services} ->
        apps =
          Enum.map(services, fn service ->
            {:ok, config} = Config.get(service)
            {config[:auth_url], config.client_id}
          end)

        assert Enum.uniq(apps) == [hd(apps)],
               "#{Enum.join(services, ", ")} share a callback but not an OAuth app"
      end)
    end
  end

  describe "auth_url/3" do
    test "carries the PKCE parameters a provider requires" do
      {:ok, url} = Config.auth_url("linear", "state-123", "challenge-abc")
      %URI{query: query} = URI.parse(url)
      params = URI.decode_query(query)

      assert String.starts_with?(url, "https://linear.app/oauth/authorize?")
      assert params["response_type"] == "code"
      assert params["code_challenge"] == "challenge-abc"
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "state-123"
      assert params["redirect_uri"] == Config.redirect_uri("linear")
      assert params["scope"] == "read"
      assert params["client_id"] != nil
    end

    test "refuses a device-flow service — there is no redirect to send it to" do
      assert {:error, _} = Config.auth_url("github", "state", "challenge")
    end

    test "refuses an unknown service" do
      assert {:error, _} = Config.auth_url("not-a-service", "state", "challenge")
    end

    test "the state and challenge are escaped rather than concatenated raw" do
      {:ok, url} = Config.auth_url("gitlab", "a b&c=d", "x/y+z")
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["state"] == "a b&c=d"
      assert params["code_challenge"] == "x/y+z"
    end
  end

  describe "resolve_client_id/2" do
    test "prefers the env var over the shipped default" do
      {:ok, config} = Config.get("linear")
      System.put_env(config.client_id_env, "from-the-environment")
      on_exit(fn -> System.delete_env(config.client_id_env) end)

      assert {:ok, "from-the-environment"} = Config.resolve_client_id(config, "linear")
    end

    test "falls back to the shipped client id" do
      {:ok, config} = Config.get("linear")
      System.delete_env(config.client_id_env)

      assert {:ok, id} = Config.resolve_client_id(config, "linear")
      assert id == config.client_id
    end

    test "with neither, the error tells the user what to set and where to point it" do
      config = %{client_id_env: "NOPE_CLIENT_ID", client_id: nil}
      System.delete_env("NOPE_CLIENT_ID")

      assert {:error, message} = Config.resolve_client_id(config, "linear")
      assert message =~ "NOPE_CLIENT_ID"
      assert message =~ Config.redirect_uri("linear")
    end
  end
end
