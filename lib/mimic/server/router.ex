defmodule Mimic.Server.Router do
  @moduledoc false

  @pool_size_key {__MODULE__, :pool_size}

  @spec init_pool_size() :: pos_integer()
  def init_pool_size do
    size = Application.get_env(:mimic, :pool_size, 1)
    :persistent_term.put(@pool_size_key, size)
    size
  end

  @spec pool_size() :: pos_integer()
  def pool_size, do: :persistent_term.get(@pool_size_key)

  @spec shard_name(non_neg_integer()) :: atom()
  def shard_name(index) when is_integer(index) and index >= 0 do
    Module.concat(Mimic.Server.Shard, Integer.to_string(index))
  end

  @spec shard_for(pid()) :: atom()
  def shard_for(pid) when is_pid(pid) do
    shard_name(:erlang.phash2(pid, pool_size()))
  end
end
