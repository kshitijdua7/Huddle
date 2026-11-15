defmodule HuddleWeb.UserSession do
  @moduledoc """
  Gives every visitor a guest identity (see `Huddle.Identity`).

  * `fetch_current_user/2` is a plug for regular requests. It creates the
    identity on the first visit and stores it in the session.
  * `on_mount/4` makes the same identity available to LiveViews as
    `@current_user`.
  """
  import Plug.Conn

  alias Huddle.Identity

  def fetch_current_user(conn, _opts) do
    case get_session(conn, :user) do
      %{"id" => _, "name" => _, "color" => _} = user ->
        assign(conn, :current_user, user)

      _missing ->
        user = Identity.generate()

        conn
        |> put_session(:user, user)
        |> assign(:current_user, user)
    end
  end

  def on_mount(:default, _params, session, socket) do
    user = session["user"] || Identity.generate()
    {:cont, Phoenix.Component.assign(socket, :current_user, user)}
  end
end
