defmodule TCPServerAndClient.MixProject do
  @moduledoc """
  Configuração do projeto Mix para `tcp_server_and_client`.

  Este módulo define as configurações usadas pelo Mix: nome da
  aplicação, versão do Elixir, dependências e aplicações extras.
  """

  use Mix.Project

  @doc """
  Retorna as configurações do projeto usadas pelo Mix.

  - `:app`       - nome do OTP app
  - `:version`   - versão do projeto
  - `:elixir`    - requisito de versão do Elixir
  - `:deps`      - lista de dependências (definida em `deps/0`)
  """
  def project do
    [
      app: :tcp_server_and_client,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  @doc """
  Configurações de runtime da aplicação.

  Define aplicações extras necessárias em runtime.
  """
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Lista de dependências do projeto.
  defp deps do
    [
    ]
  end
end
