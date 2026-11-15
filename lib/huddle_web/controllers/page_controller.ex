defmodule HuddleWeb.PageController do
  use HuddleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
