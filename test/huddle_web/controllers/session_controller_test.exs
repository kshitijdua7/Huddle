defmodule HuddleWeb.SessionControllerTest do
  use HuddleWeb.ConnCase, async: true

  test "POST /session renames the visitor and returns them to where they were", %{conn: conn} do
    conn =
      post(conn, ~p"/session", %{"user" => %{"name" => " Kshitij "}, "return_to" => "/b/abc"})

    assert redirected_to(conn) == "/b/abc"
    assert get_session(conn, :user)["name"] == "Kshitij"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You're now Kshitij."
  end

  test "POST /session keeps the old name when the new one is blank", %{conn: conn} do
    conn = post(conn, ~p"/session", %{"user" => %{"name" => "  "}})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :user)["name"] != ""
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Your name can't be blank."
  end

  test "POST /session never redirects to another site", %{conn: conn} do
    for return_to <- ["https://evil.example", "//evil.example", "/\\evil.example"] do
      conn = post(conn, ~p"/session", %{"user" => %{"name" => "Ada"}, "return_to" => return_to})
      assert redirected_to(conn) == "/"
    end
  end
end
