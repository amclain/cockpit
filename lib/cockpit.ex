defmodule Cockpit do
  use Bitwise
  use GenServer

  require Logger

  defmodule State do
    defstruct [
      :adc_pids,
      :dcs_hub_host,
      :dcs_hub_port,
      :gpios,
      :socket,
      :scan_timer_ref,
    ]
  end

  def start_link(_), do: Cockpit.start_link
  def start_link do
    GenServer.start_link(__MODULE__, nil)
  end

  def init(_) do
    dcs_hub_uri = Application.get_env(:cockpit, :dcs_hub_uri) |> URI.parse

    unless dcs_hub_uri.scheme == "udp",
      do: throw "dcs_hub_uri: invalid scheme"

    unless dcs_hub_uri.host,
      do: throw "dcs_hub_uri: invalid host"

    configure_header_pinmux()

    dcs_hub_host = dcs_hub_uri.host |> String.to_charlist
    dcs_hub_port = dcs_hub_uri.port || 7778

    {:ok, socket} = :gen_udp.open(0)

    gpios =
      [
        38, 39, 34, 35, 66, 67, 69, 68, 45, 44,
        23, 26, 47, 46, 27, 65, 22, 63, 62, 37,
        36, 33, 32, 61, 86, 88, 87, 89, 10, 11,
         9, 81,  8, 80, 78, 79, 76, 77, 74, 75,
      ]
      |> Enum.map(fn pin ->
        {:ok, pid} = Circuits.GPIO.open(pin, :input)
        value      = Circuits.GPIO.read(pid)

        {pin, pid, value}
      end)

    adc_pids =
      [0]
      |> Enum.map(fn adc_number ->
        {:ok, pid} = Cockpit.ADC.start_link(adc_number, self())

        {adc_number, pid}
      end)

    scan_timer_ref = Process.send_after(self(), :scan_timer, 20)

    state = %State{
      adc_pids:       adc_pids,
      dcs_hub_host:   dcs_hub_host,
      dcs_hub_port:   dcs_hub_port,
      gpios:          gpios,
      socket:         socket,
      scan_timer_ref: scan_timer_ref,
    }

    {:ok, state}
  end

  def handle_info(:scan_timer, state) do
    gpios =
      state.gpios
      |> Enum.map(fn {pin, pid, last_value} ->
        value = Circuits.GPIO.read(pid)

        if value != last_value,
          do: send(self(), {:circuits_gpio, pin, 0, value})

        {pin, pid, value}
      end)

    scan_timer_ref = Process.send_after(self(), :scan_timer, 20)

    state = %State{
      state |
      gpios:          gpios,
      scan_timer_ref: scan_timer_ref,
    }

    {:noreply, state}
  end

  # AHCP
  def handle_info({:circuits_gpio, 89, _, raw_value}, state) do
    send_parameter("AHCP_MASTER_ARM", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 10, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("AHCP_MASTER_ARM", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 88, _, raw_value}, state) do
    send_parameter("AHCP_GUNPAC", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 87, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("AHCP_GUNPAC", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 11, _, raw_value}, state) do
    send_parameter("AHCP_LASER_ARM", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 9, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("AHCP_LASER_ARM", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 78, _, value}, state),
    do: set_gpio_control("AHCP_TGP", value, state)

  def handle_info({:circuits_gpio, 76, _, raw_value}, state) do
    send_parameter("AHCP_ALT_SCE", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 77, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("AHCP_ALT_SCE", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 74, _, value}, state),
    do: set_gpio_control("AHCP_HUD_DAYNIGHT", value, state)

  def handle_info({:circuits_gpio, 79, _, value}, state),
    do: set_gpio_control("AHCP_HUD_MODE", value, state)

  def handle_info({:circuits_gpio, 75, _, value}, state),
    do: set_gpio_control("AHCP_CICU", value, state)

  def handle_info({:circuits_gpio, 80, _, value}, state),
    do: set_gpio_control("AHCP_JTRS", value, state)

  def handle_info({:circuits_gpio, 81, _, raw_value}, state) do
    send_parameter("AHCP_IFFCC", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 8, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("AHCP_IFFCC", value, state)

    {:noreply, state}
  end

  # Fuel Panel
  def handle_info({:circuits_gpio, 38, _, value}, state),
    do: set_gpio_control("FSCP_EXT_TANKS_WING", value, state)

  def handle_info({:circuits_gpio, 39, _, value}, state),
    do: set_gpio_control("FSCP_EXT_TANKS_FUS", value, state)

  def handle_info({:circuits_gpio, 34, _, value}, state),
    do: set_gpio_control("FSCP_RCVR_LEVER", value, state)

  def handle_info({:circuits_gpio, 35, _, value}, state),
    do: set_gpio_control("EXT_STORES_JETTISON", value, state)

  def handle_info({:circuits_gpio, 66, _, value}, state),
    do: set_gpio_control("FSCP_TK_GATE", value, state)

  def handle_info({:circuits_gpio, 67, _, value}, state),
    do: set_gpio_control("FSCP_CROSSFEED", value, state)

  def handle_info({:circuits_gpio, 69, _, value}, state),
    do: set_gpio_control("FSCP_BOOST_WING_L", value, state)

  def handle_info({:circuits_gpio, 68, _, value}, state),
    do: set_gpio_control("FSCP_BOOST_WING_R", value, state)

  def handle_info({:circuits_gpio, 45, _, value}, state),
    do: set_gpio_control("FSCP_BOOST_MAIN_L", value, state)

  def handle_info({:circuits_gpio, 44, _, value}, state),
    do: set_gpio_control("FSCP_BOOST_MAIN_R", value, state)

  # SAS Panel
  def handle_info({:circuits_gpio, 23, _, value}, state),
    do: set_gpio_control("SASP_YAW_SAS_L", value, state)

  def handle_info({:circuits_gpio, 26, _, value}, state),
    do: set_gpio_control("SASP_YAW_SAS_R", value, state)

  def handle_info({:circuits_gpio, 47, _, value}, state),
    do: set_gpio_control("SASP_PITCH_SAS_L", value, state)

  def handle_info({:circuits_gpio, 46, _, value}, state),
    do: set_gpio_control("SASP_PITCH_SAS_R", value, state)

  def handle_info({:circuits_gpio, 22, _, value}, state),
    do: set_gpio_control("SASP_TO_TRIM", value, state)

  def handle_info({:cockpit_adc, 0, value}, state) do
    # Calibration parameters
    # min    = 2
    center = 2043
    # max    = 4094
    # ----------------------

    offset           = 2048 - center
    calibrated_value = value + offset
    scaled_value     = value * 16

    send_parameter("SASP_YAW_TRIM", scaled_value, state, skip_log: true)

    {:noreply, state}
  end

  # Emergency Panel
  def handle_info({:circuits_gpio, 63, _, value}, state),
    do: set_gpio_control("EFCP_SPDBK_EMER_RETR", value, state)

  def handle_info({:circuits_gpio, 62, _, value}, state),
    do: set_gpio_control("EFCP_TRIM_OVERRIDE", value, state)

  def handle_info({:circuits_gpio, 37, _, raw_value}, state) do
    send_parameter("EFCP_AILERON_EMER_DISENGAGE", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 36, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("EFCP_AILERON_EMER_DISENGAGE", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 33, _, raw_value}, state) do
    send_parameter("EFCP_ELEVATOR_EMER_DISENGAGE", raw_value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 32, _, raw_value}, state) do
    value = bxor(raw_value, 1) + 1

    send_parameter("EFCP_ELEVATOR_EMER_DISENGAGE", value, state)

    {:noreply, state}
  end

  def handle_info({:circuits_gpio, 61, _, value}, state),
    do: set_gpio_control("EFCP_FLAPS_EMER_RETR", value, state)

  def handle_info({:circuits_gpio, 86, _, value}, state),
    do: set_gpio_control("EFCP_MRFCS", value, state)

  def handle_info(msg, state) do
    Logger.info "unhandled: #{inspect msg}"

    {:noreply, state}
  end

  defp set_gpio_control(parameter, raw_value, state) do
    value = bxor(raw_value, 1)

    send_parameter(parameter, value, state)

    {:noreply, state}
  end

  defp send_parameter(parameter, value, state, opts \\ []) do
    skip_log = opts[:skip_log]

    message = "#{parameter} #{value}"

    unless skip_log,
      do: Logger.info message

    packet = message <> "\n"

    :gen_udp.send(state.socket, state.dcs_hub_host, state.dcs_hub_port, packet)
  end

  defp configure_header_pinmux do
    # Configure port 8 GPIO pins
    3..46
    |> Enum.each(fn pin ->
      pin_name = pin |> Integer.to_string |> String.pad_leading(2, "0")
      File.write("/sys/devices/platform/ocp/ocp:P8_#{pin_name}_pinmux/state", "gpio_pu")
    end)

    # Configure port 9 GPIO pins
    [11, 12, 13, 14, 15, 16, 17, 18, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 41, 42]
    |> Enum.each(fn pin ->
      pin_name = pin |> Integer.to_string |> String.pad_leading(2, "0")
      File.write("/sys/devices/platform/ocp/ocp:P9_#{pin_name}_pinmux/state", "gpio_pu")
    end)
  end
end
