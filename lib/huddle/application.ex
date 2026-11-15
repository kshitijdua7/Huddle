defmodule Huddle.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HuddleWeb.Telemetry,
      Huddle.Repo,
      {DNSCluster, query: Application.get_env(:huddle, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Huddle.PubSub},
      # Tracks who is online on each board
      HuddleWeb.Presence,
      # One Huddle.BoardServer process per active board, started on demand
      {Registry, keys: :unique, name: Huddle.BoardRegistry},
      {DynamicSupervisor, name: Huddle.BoardSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      HuddleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Huddle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HuddleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
