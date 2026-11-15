# Creates a demo board so the app has something to show on first run:
#
#     mix run priv/repo/seeds.exs
#
# It only runs when the database has no boards yet, so it is safe to repeat.

alias Huddle.Boards
alias Huddle.Boards.Board
alias Huddle.{Chat, Repo}

if Repo.aggregate(Board, :count) == 0 do
  ada = %{"id" => "seed-ada", "name" => "Ada", "color" => "#6366f1"}
  grace = %{"id" => "seed-grace", "name" => "Grace", "color" => "#ec4899"}

  {:ok, board} = Boards.create_board(%{"name" => "Welcome to Huddle"})
  [todo, doing, done] = Boards.get_board_by_slug(board.slug).columns

  for {column, user, title} <- [
        {todo, ada, "Open this board in a second window to see it sync"},
        {todo, grace, "Drag me to another column"},
        {todo, ada, "Vote for the cards you like"},
        {doing, grace, "Start the shared timer in the top bar"},
        {doing, ada, "Say hello in the chat"},
        {done, grace, "Create the board"}
      ] do
    {:ok, _card} = Boards.create_card(column, user, %{"title" => title})
  end

  {:ok, _message} =
    Chat.create_message(board, ada, %{"body" => "Welcome! Everything here updates live."})

  {:ok, _message} =
    Chat.create_message(board, grace, %{
      "body" => "Try moving a card and watch the activity feed."
    })

  IO.puts("Seeded the demo board at /b/#{board.slug}")
end
