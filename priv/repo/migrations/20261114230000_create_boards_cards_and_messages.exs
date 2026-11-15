defmodule Huddle.Repo.Migrations.CreateBoardsCardsAndMessages do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:slug])

    create table(:columns) do
      add :title, :string, null: false
      add :position, :integer, null: false, default: 0
      add :board_id, references(:boards, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:columns, [:board_id])

    create table(:cards) do
      add :title, :string, null: false
      add :position, :integer, null: false, default: 0
      add :votes, :integer, null: false, default: 0
      add :author_name, :string, null: false
      add :author_color, :string, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :column_id, references(:columns, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cards, [:board_id])
    create index(:cards, [:column_id])

    create table(:messages) do
      add :body, :text, null: false
      add :kind, :string, null: false, default: "user"
      add :author_name, :string, null: false
      add :author_color, :string, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:board_id])
  end
end
