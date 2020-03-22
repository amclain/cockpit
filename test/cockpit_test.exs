defmodule CockpitTest do
  use ExUnit.Case
  doctest Cockpit

  test "greets the world" do
    assert Cockpit.hello() == :world
  end
end
