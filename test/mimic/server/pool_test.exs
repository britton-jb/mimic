defmodule Mimic.Server.PoolTest do
  use ExUnit.Case, async: false

  describe "pool topology" do
    test "Mimic.Server.Supervisor is the supervisor and supervises the coordinator + N shards" do
      assert Process.whereis(Mimic.Server.Supervisor),
             "expected Mimic.Server.Supervisor to be registered"

      children = Supervisor.which_children(Mimic.Server.Supervisor)
      ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

      assert Mimic.Server.Coordinator in ids,
             "expected coordinator in supervisor children, got: #{inspect(ids)}"

      shard_count = Mimic.Server.Router.pool_size()
      assert shard_count >= 1

      for i <- 0..(shard_count - 1) do
        shard_id = Mimic.Server.Router.shard_name(i)

        assert shard_id in ids,
               "expected shard #{inspect(shard_id)} to be supervised, got: #{inspect(ids)}"

        assert Process.whereis(shard_id),
               "expected shard #{inspect(shard_id)} to be registered"
      end
    end

    test "Router.shard_for/1 returns a registered shard name for any pid" do
      pid = self()
      shard = Mimic.Server.Router.shard_for(pid)

      assert is_atom(shard)
      assert Process.whereis(shard), "shard #{inspect(shard)} not registered"
    end

    test "Router.shard_for/1 is deterministic for the same pid" do
      pid = self()
      assert Mimic.Server.Router.shard_for(pid) == Mimic.Server.Router.shard_for(pid)
    end
  end
end
