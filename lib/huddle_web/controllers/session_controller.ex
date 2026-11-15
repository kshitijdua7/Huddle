defmodule HuddleWeb.SessionController do
  use HuddleWeb, :controller

  alias Huddle.Identity

  @doc "Changes the visitor's display name and sends them back where they were."
  def update(conn, params) do
    name =
      case params do
        %{"user" => %{"name" => name}} when is_binary(name) -> name
        _other -> ""
      end

    return_to = safe_return_to(params["return_to"])

    case Identity.rename(conn.assigns.current_user, name) do
      {:ok, user} ->
        conn
        |> put_session(:user, user)
        |> put_flash(:info, "You're now #{user["name"]}.")
        |> redirect(to: return_to)

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: return_to)
    end
  end

  # Only ever redirect to a path on this site.
  defp safe_return_to("/" <> rest = path) do
    if String.starts_with?(rest, "/") or String.contains?(path, ["\\", "\n", "\r"]) do
      "/"
    else
      path
    end
  end

  defp safe_return_to(_other), do: "/"
end
