defmodule Mimic.Server.Supervisor do
  @moduledoc false
  use Supervisor

  alias Mimic.Server.{Coordinator, Router, Shard}

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    pool_size = Router.init_pool_size()
    shard_specs = Enum.map(0..(pool_size - 1), &Shard.child_spec/1)
    Supervisor.init([Coordinator | shard_specs], strategy: :one_for_one)
  end
end
