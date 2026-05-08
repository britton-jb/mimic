defmodule Mimic.Server.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    pool_size = Mimic.Server.Router.init_pool_size()

    coordinator_spec = %{
      id: Mimic.Server.Coordinator,
      start: {Mimic.Server, :start_link, [[]]}
    }

    shard_specs = Enum.map(0..(pool_size - 1), &Mimic.Server.Shard.child_spec/1)

    Supervisor.init([coordinator_spec | shard_specs], strategy: :one_for_one)
  end
end
