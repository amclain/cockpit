defmodule Cockpit.ADC do
  use GenServer

  @base_path "/sys/bus/iio/devices/iio:device0"

  defmodule State do
    @moduledoc false
    defstruct [:adc_number, :notify_pid, :sample_rate, :timer_ref]
  end

  def start_link(adc_number, notify_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {adc_number, notify_pid, opts})
  end

  @impl true
  def init({adc_number, notify_pid, opts}) do
    sample_rate = Keyword.get(opts, :sample_rate, 30)

    state = %State{
      adc_number: adc_number,
      notify_pid: notify_pid,
      sample_rate: sample_rate
    }

    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    timer_ref = Process.send_after(self(), :timer_tick, state.sample_rate)

    {:noreply, %State{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:timer_tick, state) do
    value = read_adc(state)

    send(state.notify_pid, {:cockpit_adc, state.adc_number, value})

    timer_ref = Process.send_after(self(), :timer_tick, state.sample_rate)

    {:noreply, %State{state | timer_ref: timer_ref}}
  end

  defp read_adc(state) do
    {:ok, string_value} =
      @base_path
      |> Path.join("in_voltage#{state.adc_number}_raw")
      |> File.read()

    string_value |> String.trim() |> String.to_integer()
  end
end
