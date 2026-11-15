defmodule Huddle.Repo do
  use Ecto.Repo,
    otp_app: :huddle,
    adapter: Ecto.Adapters.Postgres
end
