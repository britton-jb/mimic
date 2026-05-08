defmodule Mimic.Application do
  use Application
  @moduledoc false

  def start(_, _) do
    children = [Mimic.Server.Supervisor]
    Supervisor.start_link(children, name: Mimic.Supervisor, strategy: :one_for_one)
  end
end
