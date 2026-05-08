defmodule Mimic.Server.PurgeTest do
  use ExUnit.Case, async: false

  describe "reset/1 purge_module broadcast" do
    test "drops call_history for the reset module" do
      Mimic.copy(Calculator)
      Mimic.stub(Calculator, :add, fn _, _ -> 99 end)
      Calculator.add(1, 2)

      Mimic.Server.reset(Calculator)
      Mimic.copy(Calculator)

      assert Mimic.calls(Calculator, :add, 2) == []
    end
  end
end
