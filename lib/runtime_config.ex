defmodule Bonfire.Common.RuntimeConfig do
  import Where

  def config_module, do: true

  def config do
    import Config

    config :bonfire, :http,
      proxy_url: System.get_env("HTTP_PROXY_URL", nil),
      adapter_options: [
        ssl_options: [
          # Workaround for remote server certificate chain issues
          partial_chain: &:hackney_connect.partial_chain/1,
          # We don't support TLS v1.3 yet
          versions: [:tlsv1, :"tlsv1.1", :"tlsv1.2"]
        ]
      ]
  end

  def skip_test_tags(extras \\ []) do
    chromedriver_path = Bonfire.Common.Config.get([:wallaby, :chromedriver, :path])

    # TODO: less ugly
    skip = extras ++ [:skip, :todo, :fixme]
    skip = if System.get_env("TEST_INSTANCE")=="yes", do: skip, else: [:test_instance] ++ skip # skip two-instances-required federation tests
    skip = if System.get_env("CI"), do: [:skip_ci] ++ skip, else: skip
    skip = if System.get_env("CI") || is_nil(chromedriver_path), do: [:browser] ++ skip, else: skip # skip browser automation tests in CI

    warn(skip, "Skipping tests tagged with")
  end

end