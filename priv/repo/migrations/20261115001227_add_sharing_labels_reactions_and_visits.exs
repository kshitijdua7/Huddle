defmodule Huddle.Repo.Migrations.AddSharingLabelsReactionsAndVisits do
  use Ecto.Migration

  def up do
    alter table(:boards) do
      # The slug of the read-only link (/v/:view_slug).
      add :view_slug, :string
      add :votes_hidden, :boolean, null: false, default: false
    end

    # Give boards that already exist a random read-only slug.
    execute """
    UPDATE boards
    SET view_slug = substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 12)
    WHERE view_slug IS NULL
    """

    alter table(:boards) do
      modify :view_slug, :string, null: false
    end

    create unique_index(:boards, [:view_slug])

    alter table(:cards) do
      add :label, :string
      # %{"👍" => ["user-id", ...]}
      add :reactions, :map, null: false, default: %{}
    end

    alter table(:messages) do
      add :reactions, :map, null: false, default: %{}
    end

    # Which boards each visitor has opened, for "Your boards" on the home page.
    create table(:board_visits) do
      add :user_id, :string, null: false
      add :read_only, :boolean, null: false, default: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_visits, [:user_id, :board_id])
    create index(:board_visits, [:board_id])
  end

  def down do
    drop table(:board_visits)

    alter table(:messages) do
      remove :reactions
    end

    alter table(:cards) do
      remove :label
      remove :reactions
    end

    drop unique_index(:boards, [:view_slug])

    alter table(:boards) do
      remove :view_slug
      remove :votes_hidden
    end
  end
end
