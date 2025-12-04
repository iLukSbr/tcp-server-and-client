defmodule TCPClient do
  @moduledoc """
  Cliente TCP simples para interagir com o `TCPServer`.

  Implementa modo interativo (leitura de comandos do usuário).

  O cliente mantém o socket em modo `active: false` e realiza leituras
  síncronas com `:gen_tcp.recv/2`. Durante as leituras, mensagens
  de chat iniciadas pelo servidor (prefixo `CHAT_SERVIDOR `) são
  exibidas imediatamente e ignoradas para efeitos de protocolo.
  """

  @doc """
  Conecta ao servidor dado `host` e `port` e inicia o modo interativo.

  - `host` pode ser uma charlist ou IP; `port` é inteiro.
  - cria um processo `receive_loop/2` que fica responsável por receber
    dados do socket e encaminhar eventos para o processo principal.
  """
  def start(host, port) do
    # abre conexão TCP para leitura/escrita (modo passive)
    {:ok, socket} =
      :gen_tcp.connect(host, port, [
        :binary,
        packet: :line,
        active: false
      ])

    # Formata host para string caso seja uma charlist
    host_str = if is_list(host), do: to_string(host), else: host

    # Obtém endereço local (ip:porta) do socket para log
    local_addr =
      case :inet.sockname(socket) do
        {:ok, {ip, local_port}} ->
          to_string(:inet.ntoa(ip)) <> ":" <> Integer.to_string(local_port)

        _ ->
          "unknown"
      end

    IO.puts("Conectado ao servidor #{host_str}:#{port} (local: #{local_addr})")

    # Spawn an independent listener process that will own the socket and
    # forward control lines to this process while printing server chat
    # messages immediately. We transfer socket control to the listener.
    parent = self()
    listener = spawn(fn -> socket_listener(socket, parent) end)

    receive do
      {:listener_started, ^listener} ->
        :ok
    after
      2_000 ->
        IO.puts("Timeout aguardando listener iniciar")
    end

    :ok = :gen_tcp.controlling_process(socket, listener)
    # Após transferir o controle para o listener, instrui-o a iniciar o loop
    send(listener, :begin_loop)

    # Executa o modo interativo passando o listener_pid e o endereço local
    client_loop(socket, listener, local_addr)
  end

  # Atualmente fecha a conexão — use `start_with_commands/3` para testes
  # automatizados passando uma lista de comandos.
  defp client_loop(socket, listener_pid, local_addr) do
    # Loop interativo: lê comandos do usuário e processa cada um
    IO.puts("\nComandos (local: #{local_addr}):")
    IO.puts("1. SAIR")
    IO.puts("2. ARQUIVO nome_do_arquivo")
    IO.puts("3. CHAT mensagem")
    IO.write("Digite o comando: ")

    case IO.gets("") do
      nil ->
        :gen_tcp.close(socket)
        :ok

      input ->
        command = String.trim(input)

        case command do
          "" ->
            client_loop(socket, listener_pid, local_addr)

          _ ->
            case execute_single_command(socket, listener_pid, command) do
              {:continue, listener_pid} -> client_loop(socket, listener_pid, local_addr)
              :stop -> :ok
            end
        end
    end
  end

  # Executa um único comando enviado pelo usuário ou por argumentos.
  # Retorna :continue para prosseguir ou :stop para encerrar.
  defp execute_single_command(socket, listener_pid, command) do
    case String.split(command, " ", parts: 2) do
      ["SAIR"] ->
        # Solicita controle do socket ao listener para ler diretamente
        send(listener_pid, {:transfer_control_to, self()})

        receive do
          {:listener_released} ->
            :ok

          {:listener_error, reason} ->
            IO.puts("Erro ao solicitar controle do listener: #{inspect(reason)}")
            :gen_tcp.close(socket)
            :stop
        after
          5_000 ->
            IO.puts("Timeout ao tentar obter controle do socket; fechando conexão")
            :gen_tcp.close(socket)
            :stop
        end

        :gen_tcp.send(socket, "SAIR\n")

        case recv_non_chat_line_direct(socket) do
          "OK" ->
            IO.puts("Resposta: OK")
            :gen_tcp.close(socket)
            IO.puts("Conexão fechada.")
            :stop

          "__CLOSED__" ->
            IO.puts("Conexão fechada pelo servidor.")
            :gen_tcp.close(socket)
            :stop

          "__ERROR__" ->
            IO.puts("Erro na recepção ao encerrar conexão.")
            :gen_tcp.close(socket)
            :stop

          other ->
            IO.puts("Resposta inesperada: #{inspect(other)}")
            :gen_tcp.close(socket)
            :stop
        end

      ["ARQUIVO", filename] ->
        # Para receber o arquivo, precisamos que o processo principal seja
        # o controlador do socket. Solicitamos ao listener que libere o
        # controle, aguardamos confirmação e então procedemos à transferência.
        send(listener_pid, {:transfer_control_to, self()})

        receive do
          {:listener_released} ->
            :ok

          {:listener_error, reason} ->
            IO.puts("Erro ao solicitar controle do listener: #{inspect(reason)}")
            {:continue, listener_pid}
        after
          5_000 ->
            IO.puts("Timeout ao tentar obter controle do socket")
            {:continue, listener_pid}
        end

        # Agora somos o controlador do socket; devemos ler diretamente do socket
        :gen_tcp.send(socket, "ARQUIVO #{filename}\n")

        case recv_non_chat_line_direct(socket) do
          "ERRO_ARQUIVO_NAO_ENCONTRADO" ->
            IO.puts("Erro: Arquivo não encontrado no servidor.")
            # recria listener e devolve controle (handshake seguro)
            new_listener = spawn(fn -> socket_listener(socket, self()) end)

            receive do
              {:listener_started, ^new_listener} ->
                :ok
            after
              2_000 ->
                IO.puts("Timeout aguardando novo listener iniciar")
            end

            case :gen_tcp.controlling_process(socket, new_listener) do
              :ok ->
                send(new_listener, :begin_loop)
                {:continue, new_listener}

              {:error, reason} ->
                IO.puts(
                  "Não foi possível transferir controle ao novo listener: #{inspect(reason)}"
                )

                {:continue, listener_pid}
            end

          "OK" ->
            # Recebe metadados do arquivo diretamente do socket
            name = recv_non_chat_line_direct(socket)
            size_line = recv_non_chat_line_direct(socket)
            hash_line = recv_non_chat_line_direct(socket)
            # Log dos metadados recebidos
            IO.puts(
              "Recebendo arquivo: #{name} (tamanho: #{size_line} bytes, sha256 esperado: #{String.trim(hash_line)})"
            )

            size = String.to_integer(size_line)
            expected_hash = String.trim(hash_line)

            File.mkdir_p!("downloads")
            dest = Path.join("downloads", name)

            case File.open(dest, [:binary, :write]) do
              {:ok, file} ->
                # Lê os bytes brutos (servidor enviou em packet 0)
                :inet.setopts(socket, packet: 0)
                hash_ctx = :crypto.hash_init(:sha256)

                case recv_file_stream(socket, size, file, hash_ctx) do
                  {:ok, final_ctx} ->
                    File.close(file)
                    :inet.setopts(socket, packet: :line)
                    received_hash = :crypto.hash_final(final_ctx) |> Base.encode16(case: :lower)

                    IO.puts("Hash esperado: #{expected_hash}")
                    IO.puts("Hash recebido : #{received_hash}")

                    if received_hash == expected_hash do
                      IO.puts("Arquivo #{name} salvo com sucesso. Hash verificado.")
                    else
                      IO.puts("Erro: Hash não confere. Arquivo corrompido.")
                    end

                  {:error, reason} ->
                    File.close(file)
                    :inet.setopts(socket, packet: :line)
                    File.rm(dest)
                    IO.puts("Erro recebendo arquivo: #{inspect(reason)}")
                end

              {:error, reason} ->
                :inet.setopts(socket, packet: :line)
                IO.puts("Erro ao abrir arquivo local: #{inspect(reason)}")
            end

            # Após terminar, recria o listener para voltar a exibir chats
            new_listener = spawn(fn -> socket_listener(socket, self()) end)

            receive do
              {:listener_started, ^new_listener} ->
                :ok
            after
              2_000 ->
                IO.puts("Timeout aguardando novo listener iniciar")
            end

            case :gen_tcp.controlling_process(socket, new_listener) do
              :ok ->
                send(new_listener, :begin_loop)
                {:continue, new_listener}

              {:error, reason} ->
                IO.puts(
                  "Não foi possível transferir controle ao novo listener: #{inspect(reason)}"
                )

                {:continue, listener_pid}
            end

          other ->
            IO.puts("Resposta inesperada: #{inspect(other)}")
            # devolve controle
            new_listener = spawn(fn -> socket_listener(socket, self()) end)

            receive do
              {:listener_started, ^new_listener} ->
                :ok
            after
              2_000 ->
                IO.puts("Timeout aguardando novo listener iniciar")
            end

            case :gen_tcp.controlling_process(socket, new_listener) do
              :ok ->
                send(new_listener, :begin_loop)
                {:continue, new_listener}

              {:error, reason} ->
                IO.puts(
                  "Não foi possível transferir controle ao novo listener: #{inspect(reason)}"
                )

                {:continue, listener_pid}
            end
        end

      ["CHAT", message] ->
        :gen_tcp.send(socket, "CHAT #{message}\n")
        {:continue, listener_pid}

      _ ->
        IO.puts("Comando inválido: #{command}")
        {:continue, listener_pid}
    end
  end

  # Nota: as leituras de linhas de controle são feitas agora via mensagens
  # encaminhadas pelo listener (`{:control_line, line}`) ou por leituras
  # diretas quando o processo principal possui o controle do socket.

  # Quando o processo principal possui o controle do socket, usamos
  # leituras diretas para obter linhas do servidor. Esta função
  # lida com mensagens `CHAT_SERVIDOR ` imprimindo-as e continuando
  # a leitura até obter uma linha de controle.
  defp recv_non_chat_line_direct(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        line = String.trim(data)

        if String.starts_with?(line, "CHAT_SERVIDOR ") do
          msg = String.trim_leading(line, "CHAT_SERVIDOR ")
          IO.puts("Mensagem do servidor: #{msg}")
          recv_non_chat_line_direct(socket)
        else
          line
        end

      {:error, :closed} ->
        "__CLOSED__"

      {:error, reason} ->
        IO.puts("Erro no recv direto: #{inspect(reason)}")
        "__ERROR__"
    end
  end

  # Listener process: possui o socket, imprime mensagens de chat e
  # encaminha linhas de controle ao processo principal.
  defp socket_listener(socket, main_pid) do
    # sinaliza ao processo principal que este processo foi criado
    send(main_pid, {:listener_started, self()})

    # aguarda instrução para iniciar o loop (após o controlador ter sido estabelecido)
    receive do
      :begin_loop ->
        listener_loop(socket, main_pid)
    after
      5_000 ->
        # Se não receber a instrução para começar, encerra para evitar processos zumbis
        :ok
    end
  end

  defp listener_loop(socket, main_pid) do
    receive do
      {:transfer_control_to, new_owner} when is_pid(new_owner) ->
        # Transfere o controle do socket para o processo que solicitou.
        :gen_tcp.controlling_process(socket, new_owner)
        send(new_owner, {:listener_released})
        # Após transferir o controle, termina o listener para não tentar
        # mais operações sobre o socket (que agora pertence a outro processo).
        :ok
    after
      0 ->
        case :gen_tcp.recv(socket, 0, 500) do
          {:ok, data} ->
            line = String.trim(data)

            if String.starts_with?(line, "CHAT_SERVIDOR ") do
              msg = String.trim_leading(line, "CHAT_SERVIDOR ")
              IO.puts("\nMensagem do servidor: #{msg}")
              listener_loop(socket, main_pid)
            else
              send(main_pid, {:control_line, line})
              listener_loop(socket, main_pid)
            end

          {:error, :timeout} ->
            listener_loop(socket, main_pid)

          {:error, :closed} ->
            send(main_pid, {:socket_closed})
            :ok

          {:error, reason} ->
            send(main_pid, {:socket_error, reason})
            listener_loop(socket, main_pid)
        end
    end
  end

  # Recebe `remaining` bytes do socket em blocos, grava em `file` e atualiza o contexto de hash.
  defp recv_file_stream(_socket, 0, _file, hash_ctx), do: {:ok, hash_ctx}

  defp recv_file_stream(socket, remaining, file, hash_ctx) when remaining > 0 do
    to_read = min(4096, remaining)

    case :gen_tcp.recv(socket, to_read) do
      {:ok, chunk} ->
        :ok = IO.binwrite(file, chunk)
        new_ctx = :crypto.hash_update(hash_ctx, chunk)
        recv_file_stream(socket, remaining - byte_size(chunk), file, new_ctx)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
