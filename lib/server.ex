defmodule TCPServer do
  @moduledoc """
  Servidor TCP multithread (cada thread em um processo) que oferece
  transferência de arquivos e chat simples.

  Implementa um loop principal que aceita conexões e cria um processo
  para cada cliente. As threads de cliente tratam
  requisições textuais de aplicação definidas pelo protocolo simples
  usado pelo projeto.
  """

  @port 4000

  @doc """
  Inicializa o servidor:

  - inicia um `Agent` que mantém a lista de clientes conectados (`clients_pid`);
  - cria um processo para leitura de mensagens de chat digitadas no console;
  - abre um socket TCP de escuta na porta `@port` e entra no `accept_loop/2`.
  """
  def start do
    # Inicia o Agent para gerenciar clientes conectados
    {:ok, clients_pid} = Agent.start_link(fn -> [] end)

    # Inicia o processo para leitura de chat do console
    spawn(fn -> chat_input_loop(clients_pid) end)

    # Abre o socket de escuta
    {:ok, listen_socket} =
      :gen_tcp.listen(@port, [
        :binary,
        # para mensagens de texto
        packet: :line,
        # ativo para receive
        active: true,
        reuseaddr: true
      ])

    IO.puts("Servidor escutando na porta #{@port}")
    accept_loop(listen_socket, clients_pid)
  end

  defp accept_loop(listen_socket, clients_pid) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    # obtém endereço do cliente para log e formata como "ip:porta"
    client_addr =
      case :inet.peername(socket) do
        {:ok, {ip, port}} ->
          # :inet.ntoa/1 retorna uma charlist, convertemos para string
          to_string(:inet.ntoa(ip)) <> ":" <> Integer.to_string(port)

        _ ->
          "unknown"
      end

    IO.puts("Cliente conectado: #{client_addr}")

    # Spawna processo para o cliente e transfere controle do socket
    client_pid = spawn(fn -> handle_client(socket, clients_pid, client_addr) end)
    :gen_tcp.controlling_process(socket, client_pid)

    accept_loop(listen_socket, clients_pid)
  end

  defp handle_client(socket, clients_pid, client_addr) do
    # Registra o cliente no Agent `clients_pid` (lista de {pid, addr})
    client_pid = self()

    Agent.update(clients_pid, fn clients ->
      [{client_pid, client_addr} | clients]
    end)

    client_loop(socket, clients_pid, client_addr)
  end

  defp client_loop(socket, clients_pid, client_addr) do
    receive do
      {:tcp, ^socket, data} ->
        # Recebe dados textuais do cliente e despacha para o handler
        handle_request(String.trim(data), socket, client_addr)
        client_loop(socket, clients_pid, client_addr)

      {:tcp_closed, ^socket} ->
        IO.puts("Cliente desconectado: #{client_addr}")

        client_pid = self()

        Agent.update(clients_pid, fn clients ->
          Enum.reject(clients, fn {pid, _addr} -> pid == client_pid end)
        end)

        :ok

      {:chat_server, message} ->
        # Mensagem enviada pelo servidor para broadcast
        :gen_tcp.send(socket, "CHAT_SERVIDOR #{message}\n")
        client_loop(socket, clients_pid, client_addr)

      _ ->
        client_loop(socket, clients_pid, client_addr)
    end
  end

  defp handle_request("SAIR", socket, _client_addr) do
    # Cliente solicita encerramento da conexão
    :gen_tcp.send(socket, "OK\n")
    :gen_tcp.close(socket)
  end

  defp handle_request("ARQUIVO " <> filename, socket, client_addr) do
    # Evita path traversal: usa apenas o basename do filename
    safe_name = Path.basename(filename)
    path = Path.join("files", safe_name)

    if File.exists?(path) do
      {:ok, stat} = File.stat(path)
      size = stat.size
      # calcula hash SHA-256 do arquivo (por streaming)
      hash = Utils.sha256_file(path)

      # Log de metadados antes do envio
      IO.puts(
        "Enviando arquivo: #{safe_name} (tamanho: #{size} bytes, sha256: #{hash}) para #{client_addr}"
      )

      # Muda para packet 0 para enviar binário cru
      :inet.setopts(socket, packet: 0)
      :gen_tcp.send(socket, "OK\n#{safe_name}\n#{size}\n#{hash}\n")

      # Envia o conteúdo em chunks para suportar arquivos grandes
      File.stream!(path, [], 4096)
      |> Enum.each(fn chunk ->
        :gen_tcp.send(socket, chunk)
      end)

      # Volta para packet :line (mensagens textuais)
      :inet.setopts(socket, packet: :line)

      IO.puts("Arquivo #{safe_name} enviado para #{client_addr}")
    else
      :gen_tcp.send(socket, "ERRO_ARQUIVO_NAO_ENCONTRADO\n")
      IO.puts("Arquivo não encontrado: #{safe_name} solicitado por #{client_addr}")
    end
  end

  defp handle_request("CHAT " <> message, _socket, client_addr) do
    # Apenas registra a mensagem vinda do cliente no console do servidor
    IO.puts("Chat de #{inspect(client_addr)}: #{message}")
  end

  defp handle_request(_unknown, socket, _client_addr) do
    # Comando não reconhecido pelo protocolo de aplicação
    :gen_tcp.send(socket, "ERRO_COMANDO_DESCONHECIDO\n")
  end

  defp chat_input_loop(clients_pid) do
    # Lê mensagens do console e envia broadcast para todos os clientes
    IO.write("Digite mensagem para broadcast: ")
    message = IO.gets("")

    if message != :eof and message != nil do
      trimmed = String.trim(message)

      cond do
        trimmed == "" ->
          :ok

        trimmed == "SAIR" ->
          # Notifica clientes que o servidor vai encerrar e finaliza o VM
          clients = Agent.get(clients_pid, fn c -> c end)

          Enum.each(clients, fn {pid, _addr} ->
            if is_pid(pid) and pid != clients_pid and Process.alive?(pid) do
              send(pid, {:chat_server, "Servidor encerrando"})
            end
          end)

          IO.puts("Servidor encerrando a pedido do console...")
          System.halt(0)

        trimmed == "LIST" ->
          clients = Agent.get(clients_pid, fn c -> c end)

          clients
          |> Enum.with_index(1)
          |> Enum.each(fn
            {{pid, addr}, idx} ->
              IO.puts("#{idx}. #{addr} (#{inspect(pid)})")

            {item, idx} ->
              # caso a entrada não seja o par esperado, mostra informação bruta
              IO.puts("#{idx}. #{inspect(item)}")
          end)

        String.starts_with?(trimmed, "@") ->
          # formatos suportados:
          #  - @ip:porta mensagem  (envia para cliente por endereço)
          #  - @N mensagem         (envia para cliente pelo índice mostrado em LIST)
          case String.split(trimmed, " ", parts: 2) do
            [target_token, msg] ->
              target = String.trim_leading(target_token, "@")
              clients = Agent.get(clients_pid, fn c -> c end)

              cond do
                # alvo por índice (ex: @1)
                Regex.match?(~r/^\d+$/, target) ->
                  idx = String.to_integer(target)

                  case Enum.at(clients, idx - 1) do
                    {pid, addr} when is_pid(pid) ->
                      if pid != clients_pid and Process.alive?(pid) do
                        send(pid, {:chat_server, msg})
                      else
                        IO.puts("Cliente #{addr} (index #{idx}) não está disponível")
                      end

                    nil ->
                      IO.puts("Índice #{idx} inválido")
                  end

                # alvo por endereço (ex: 127.0.0.1:4826)
                true ->
                  case Enum.find(clients, fn
                         {pid, addr} when is_pid(pid) -> addr == target
                         _ -> false
                       end) do
                    {pid, addr} ->
                      if is_pid(pid) and pid != clients_pid and Process.alive?(pid) do
                        send(pid, {:chat_server, msg})
                      else
                        IO.puts("Cliente #{addr} não está disponível")
                      end

                    nil ->
                      IO.puts("Cliente #{target} não encontrado")
                  end
              end

            _ ->
              IO.puts("Formato inválido. Use: @ip:porta mensagem ou @<índice> mensagem")
          end

        true ->
          # broadcast para todos os clientes (filtra entradas inválidas e evita enviar ao próprio Agent)
          clients = Agent.get(clients_pid, fn c -> c end)

          Enum.each(clients, fn
            {pid, _addr} when is_pid(pid) and pid != clients_pid ->
              if Process.alive?(pid) do
                send(pid, {:chat_server, trimmed})
              end

            _ ->
              :ok
          end)
      end

      chat_input_loop(clients_pid)
    end
  end
end
