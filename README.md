# TCP Server and Client in Elixir

Este projeto implementa um servidor e cliente TCP multithread (usando processos Elixir) para transferência de arquivos com verificação de integridade (SHA-256) e chat simpleso.

## Requisitos

- Elixir 1.19 ou superior
- Erlang/OTP

## Instalação

1. Instale Elixir: https://elixir-lang.org/install.html
2. Clone ou baixe o projeto.
3. `mix deps.get`
4. `mix compile`

## Como executar

1. Inicie o servidor em um terminal: `mix server`
2. Inicie o cliente em outro terminal (duas opções):
  - Modo rápido (passa host e porta): `mix client localhost 4000`
  - Modo interativo (será solicitado host e porta): `mix client`
3. Para testar com dois clientes, abra mais terminais e execute `mix client localhost 4000` (ou `mix client` em modo interativo).

## Arquivo de Teste

Um arquivo deve ser colocado na pasta `files/` para testar transferência de arquivos do servidor. O cliente fará download para a pasta `downloads/`.

## Estrutura do Projeto

- `lib/server.ex`: Código do servidor TCP
- `lib/client.ex`: Código do cliente TCP
- `lib/utils.ex`: Utilitários (cálculo de hash SHA-256)
- `lib/tasks.ex`: Mix tasks para iniciar servidor e cliente
- `files/`: Pasta para arquivos do servidor
- `downloads/`: Pasta para downloads do cliente

## Protocolo de Aplicação

Todas as mensagens são strings UTF-8 terminadas por `\n`, exceto o conteúdo binário dos arquivos.

### Requisições do Cliente

- **Sair**: `SAIR\n`
- **Arquivo**: `ARQUIVO nome_do_arquivo\n`
- **Chat**: `CHAT mensagem\n`

### Respostas do Servidor

- **Sair**: `OK\n`
- **Arquivo**:
  - Se erro: `ERRO_ARQUIVO_NAO_ENCONTRADO\n`
  - Se OK: `OK\nnome\ntamanho\nhash_sha256\n` seguido pelo conteúdo binário do arquivo.
- **Chat**: Nenhuma resposta específica; a mensagem é exibida no console do servidor.
- **Erro**: `ERRO_<motivo_do_erro>\n`

### Mensagens do Servidor para Cliente (Chat)

- `CHAT_SERVIDOR mensagem\n`

## Funcionalidades

- **Multithread**: Servidor aceita múltiplas conexões simultâneas, cada uma em um processo dedicado.
- **Transferência de Arquivos**: Suporta arquivos grandes (> 10 MB), com cálculo de hash SHA-256 no servidor e verificação no cliente.
- **Chat**: Cliente pode enviar mensagens para o servidor (exibidas no console), e o servidor pode fazer broadcast de mensagens para todos os clientes conectados via console.
- **Tratamento de Erros**: Arquivo não encontrado, comandos desconhecidos.
