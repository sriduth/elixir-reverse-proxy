defmodule ReverseProxy.Runner do
  @moduledoc """
  Retreives content from an upstream.
  """

  alias Plug.Conn

  @typedoc "Representation of an upstream service."
  @type upstream :: [String.t] | {Atom.t, Keyword.t}

  # @spec retreive(Conn.t, upstream) :: Conn.t
  # def retreive(conn, upstream)
  # def retreive(conn, {plug, opts}) when plug |> is_atom do
  #   options = plug.init(opts)
  #   plug.call(conn, options)
  # end

  def retreive(conn, servers, opts, client \\ HTTPoison) do
    server = upstream_select(servers)
    {method, url, body, headers} = prepare_request(server, conn, opts)
    
    method
      |> client.request(url, body, headers, timeout: 5_000)
      |> process_response(conn)
  end

  defp prepare_request(server, conn, opts) do
    conn = conn
    |> Conn.put_req_header("x-forwarded-for", conn.remote_ip |> :inet.ntoa |> to_string)
    |> Conn.delete_req_header("host")
    |> Conn.delete_req_header("transfer-encoding")
    
    method = conn.method |> String.downcase |> String.to_atom
    proxy_scheme = if Keyword.get opts, :scheme do
      Keyword.get opts, :scheme
    else
      conn.scheme
    end
     
    url = if Keyword.get(opts, :strip_base) do
      prefix = Keyword.get opts, :base_path
      if String.starts_with?(conn.request_path, prefix) do
        prefix_stripped_path = String.replace_prefix(conn.request_path, prefix, "/")
        "#{prepare_server(proxy_scheme, server)}#{prefix_stripped_path}?#{conn.query_string}"
      else
        "#{prepare_server(proxy_scheme, server)}#{conn.request_path}?#{conn.query_string}"
      end
    else
      "#{prepare_server(proxy_scheme, server)}#{conn.request_path}?#{conn.query_string}"
    end
    
    
    headers = conn.req_headers

    body = case Conn.read_body(conn) do
      {:ok, body, _conn} ->
        body
      {:more, body, conn} ->
        {:stream,
          Stream.resource(
            fn -> {body, conn} end,
            fn
              {body, conn} ->
                {[body], conn}
              nil ->
                {:halt, nil}
              conn ->
                case Conn.read_body(conn) do
                  {:ok, body, _conn} ->
                    {[body], nil}
                  {:more, body, conn} ->
                    {[body], conn}
                end
            end,
            fn _ -> nil end
          )
        }
    end

    {method, url, body, headers}
  end

  @spec prepare_server(String.t, String.t) :: String.t
  defp prepare_server(scheme, server)
  defp prepare_server(_, "http://" <> _ = server), do: server
  defp prepare_server(_, "https://" <> _ = server), do: server
  defp prepare_server(scheme, server) do
    "#{scheme}://#{server}"
  end

  @spec process_response({Atom.t, Map.t}, Conn.t) :: Conn.t
  defp process_response({:error, _}, conn) do
    conn |> Conn.send_resp(502, "Bad Gateway")
  end
  defp process_response({:ok, response}, conn) do
    conn
      |> put_resp_headers(response.headers)
      |> Conn.delete_resp_header("transfer-encoding")
      |> Conn.send_resp(response.status_code, response.body)
  end

  @spec put_resp_headers(Conn.t, [{String.t, String.t}]) :: Conn.t
  defp put_resp_headers(conn, []), do: conn
  defp put_resp_headers(conn, [{header, value} | rest]) do
    conn
      |> Conn.put_resp_header(header |> String.downcase, value)
      |> put_resp_headers(rest)
  end

  defp upstream_select(servers) do
    servers |> hd
  end
end
