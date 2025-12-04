defmodule Mix.Tasks.Server do
  @moduledoc """
  Tarefa Mix para iniciar o servidor TCP.

  Executar com `mix server` irá chamar `TCPServer.start/0`.
  """

  use Mix.Task

  @shortdoc "Inicia o servidor TCP"
  @doc "Executa a tarefa `mix server` e inicia o servidor."
  def run(_) do
    TCPServer.start()
  end
end

defmodule Mix.Tasks.Client do
  @moduledoc """
  Tarefa Mix para iniciar o cliente TCP em modo interativo.

  Ao executar `mix client` a tarefa pergunta interativamente o
  `host` e a `port` e então inicia o cliente interativo.
  """

  use Mix.Task

  @shortdoc "Inicia o cliente TCP (modo interativo)"
  @doc "Executa a tarefa `mix client` — solicita host e porta ao usuário."
  def run(args) do
    case args do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {p, _} -> TCPClient.start(String.to_charlist(host), p)
          :error -> Mix.raise("Porta inválida")
        end

      [] ->
        # lê host e porta interativamente; se deixados em branco, usa defaults
        host =
          case IO.gets("Host (default: localhost): ") do
            nil ->
              "localhost"

            input ->
              trimmed = String.trim(input)
              if trimmed == "", do: "localhost", else: trimmed
          end

        port =
          case IO.gets("Porta (default: 4000): ") do
            nil ->
              4000

            input ->
              trimmed = String.trim(input)

              if trimmed == "" do
                4000
              else
                case Integer.parse(trimmed) do
                  {p, _} -> p
                  :error -> Mix.raise("Porta inválida")
                end
              end
          end

        TCPClient.start(String.to_charlist(host), port)

      _ ->
        Mix.raise("Uso: mix client [host port] (se omitido, será solicitado interativamente)")
    end
  end
end
