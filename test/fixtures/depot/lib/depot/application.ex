defmodule Depot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Notifier starts first; Queue and Sonar both depend on it through
    # GenServer calls. Under :one_for_one a Notifier crash restarts only
    # the Notifier, and both dependents keep running against a Notifier
    # that has forgotten them — the coupling one_for_one_coupling reports.
    children = [
      Depot.Notifier,
      Depot.Queue,
      Depot.Sonar
    ]

    opts = [strategy: :one_for_one, name: Depot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
