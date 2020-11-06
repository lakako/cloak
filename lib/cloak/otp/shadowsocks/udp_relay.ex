require Logger

defmodule Cloak.Shadowsocks.UDPRelay do
  use    GenServer, shutdown: 2000
  import Cloak.Registry
  alias  Cloak.{ Cipher, Conn }

  @socket_option [:binary, active: :once, reuseaddr: true ]
  @port_ttl      10

  defstruct(
    account:   nil,
    port:      nil,
    cipher:    nil,
    req_ports: %{}
  )

  def start_link(account) do
    GenServer.start_link(
      __MODULE__,
      account,
      name: via({:udp_relay, account.port}),
      spawn_opt: [fullsweep_after: 0]
    )
  end

  def init(%{ port: port, method: method, passwd: passwd } = account) do
    # This makes it so that when your process "crashes", it calls the terminate/2
    # callback function prior to actually exiting the process. Using this method,
    # you can manually close your listening socket in the terminate function,
    # thereby avoiding the irritating port cleanup delay.
    Process.flag( :trap_exit , true )
    with { :ok, pt } <- :gen_udp.open(port, @socket_option),
         { :ok, c } <- Cipher.setup(method, passwd)
    do
      # do not start timer at the sametime for all processes
      Process.send_after(self(), :ttl, Enum.random(1..(@port_ttl * 1000)))
      { :ok, %__MODULE__{ port: pt, account: account, cipher: c } }
    else
      { :error, reason }  -> { :stop, reason }
      _ -> :stop
    end
  end

  # request to udp servicing port
  def handle_info({ :udp, pt, ip, rport, payload }, %{ port: pt, cipher: c } = state ) do
    :inet.setopts(pt, active: :once)
    with { :ok, %{ iv: iv, data: d }} <- Conn.split_package(payload, c.iv_len),
         c = Cipher.init_decoder(c, iv),
         { :ok, _, decoded } <- Cipher.decode(c, d),
         { :ok, req } <- Conn.parse_shadowsocks_request(decoded), 
         { :ok, req } <- Conn.udp_send(req)
    do
      req_ports = Map.put(state.req_ports, req.remote, { ip, rport, :os.system_time(:seconds) + @port_ttl })
      { :noreply, %{ state | req_ports: req_ports } }
    else
      { :error, reason } when reason in ~w( invalid_request private_address )a -> { :noreply, state }
      { :error, reason } when is_atom(reason) ->
        Logger.warn "#{reason} / udp:#{state.account.port} / #{inspect ip}"
        { :noreply, state }
      { :error, { :nxdomain, req } } ->
        Logger.debug "UDP [nxdomain]: #{inspect(req)}"
        { :noreply, state }
      { :error, { reason, req } } ->
        Logger.warn "----- Unhandled UDP connection: #{inspect(reason)} -----"
        Logger.warn "request: #{inspect(req)}"
        { :noreply, state }
    end
  end

  # received response from remote
  def handle_info( { :udp, pt, addr, _port, payload }, %{ req_ports: req_ports, cipher: c } = state ) do
    :inet.setopts(pt, active: :once)
    with { ip, port, _expiry } <- req_ports[pt],
         { iv, c } <- Cipher.init_encoder(c)
    do
      d = Conn.udp_build_packet(payload, addr, port)
      { :ok, _, encoded } = Cipher.encode(c, d)
      :gen_udp.send(state.port, ip, port, iv<>encoded)
      req_ports = Map.put(req_ports, pt, { ip, port, :os.system_time(:seconds) + @port_ttl })
      { :noreply, %{ state | req_ports: req_ports }}
    else
      _ -> { :noreply, state }
    end
  end

  def handle_info( { :udp_closed, pt }, %{ port: port, req_ports: req_ports } = state) when pt != port do
    req_ports = Map.delete(req_ports, pt)
    :gen_udp.close( pt )
    { :noreply, %{ state | req_ports: req_ports } }
  end

  # remove unused ports after @port_ttl seconds of inactivity
  def handle_info(:ttl, %{ req_ports: req_ports } = state ) do
    now = :os.system_time(:seconds)
    req_ports
    |> Enum.filter( fn {_, {_, _, exp }} -> exp < now end )
    |> Enum.map(fn {pt, _} -> :gen_udp.close(pt) end )
    req_ports = req_ports
                |> Enum.reject(fn {_, {_, _, exp}} -> exp < now end)
                |> Enum.into(%{})
    Process.send_after(self(), :ttl, @port_ttl * 1000)
    { :noreply, %{ state | req_ports: req_ports }}
  end

  # handle all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast( { :set, %{ passwd: _ } = account }, state ) do
    case Cipher.setup(account.method, account.passwd) do
      { :ok, c } -> { :noreply, %{ state | cipher: c, account: account } }
      _ -> { :noreply, state }
    end
  end

  def set(pid, account) when is_pid(pid) do
    GenServer.cast(pid, { :set, account })
  end

  def set(port, account) when is_integer(port) do
    GenServer.cast(via({:tcp_relay, port}), { :set, account })
  end

  # cleanup listening socket
  def terminate(_, state), do: { :shutdown, state }

end
