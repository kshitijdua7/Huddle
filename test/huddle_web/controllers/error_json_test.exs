defmodule HuddleWeb.ErrorJSONTest do
  use HuddleWeb.ConnCase, async: true

  test "renders 404" do
    assert HuddleWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert HuddleWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
