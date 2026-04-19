defmodule BullX.Repo do
  use Ecto.Repo,
    otp_app: :bullx,
    adapter: Ecto.Adapters.Postgres
end
