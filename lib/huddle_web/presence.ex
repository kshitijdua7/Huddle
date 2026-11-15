defmodule HuddleWeb.Presence do
  @moduledoc """
  Tracks who is currently viewing each board.

  Built on `Phoenix.Presence`, which replicates the list across every node of
  a cluster without a central database.
  """
  use Phoenix.Presence,
    otp_app: :huddle,
    pubsub_server: Huddle.PubSub
end
