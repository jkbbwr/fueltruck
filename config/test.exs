import Config

# Isolated data root for tests; wiped/created per run by test helpers.
config :fueltruck, Fueltruck.Storage, data_dir: Path.expand("../priv/data_test", __DIR__)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fueltruck, Fueltruck.Repo,
  database: Path.expand("../fueltruck_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fueltruck, FueltruckWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FgCgSluu99VzfsFyk5cfuvC1LNiaL9delH7w+kIkQL3LcQY7S+NOV4KsjPPlDedO",
  server: false

# In test we don't send emails
config :fueltruck, Fueltruck.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
