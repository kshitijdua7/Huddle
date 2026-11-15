defmodule Huddle.Identity do
  @moduledoc """
  Lightweight guest identities.

  Huddle has no passwords: every visitor starts as Kshitij Dua with a random
  colour, stored in their signed session cookie, so anyone can open a shared link and
  start collaborating straight away. The identity is a plain map with string
  keys (`"id"`, `"name"`, `"color"`) because that is how it travels through the
  session.
  """

  @colors ~w(#6366f1 #8b5cf6 #d946ef #ec4899 #f43f5e #f97316 #d97706 #16a34a #0d9488 #0891b2 #2563eb #64748b)
  @max_name_length 24

  @doc "Generates a unique guest identity with the default display name."
  def generate do
    %{
      "id" => Ecto.UUID.generate(),
      "name" => "Kshitij Dua",
      "color" => Enum.random(@colors)
    }
  end

  @doc "Returns `{:ok, identity}` with the new display name, or `{:error, message}`."
  def rename(%{"id" => _} = identity, name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, @max_name_length) do
      "" -> {:error, "Your name can't be blank."}
      trimmed -> {:ok, Map.put(identity, "name", trimmed)}
    end
  end

  def rename(_identity, _name), do: {:error, "Your name can't be blank."}

  @doc "Up to two uppercase initials for an avatar."
  def initials(name) when is_binary(name) do
    initials =
      name
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(2)
      |> Enum.map_join(&String.first/1)
      |> String.upcase()

    if initials == "", do: "?", else: initials
  end
end
