defmodule Mimic.Server.Shard do
  @moduledoc false
  use GenServer

  def child_spec(index) do
    name = Mimic.Server.Router.shard_name(index)
    %{id: name, start: {__MODULE__, :start_link, [name]}}
  end

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @impl true
  def init([]), do: {:ok, %{}}
end
