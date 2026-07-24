defmodule Fueltruck.Repo do
  use Ecto.Repo,
    otp_app: :fueltruck,
    adapter: Ecto.Adapters.SQLite3
end
