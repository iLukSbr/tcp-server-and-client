defmodule Utils do
  @moduledoc """
  Utilitários para o projeto TCP.
  """

  @doc """
  Calcula o hash SHA-256 de um arquivo.
  """
  def sha256_file(path) do
    # Calcula SHA-256 em streaming para suportar arquivos grandes
    if File.exists?(path) do
      hash_ctx = :crypto.hash_init(:sha256)
      final =
        File.stream!(path, [], 4096)
        |> Enum.reduce(hash_ctx, fn chunk, ctx -> :crypto.hash_update(ctx, chunk) end)
        |> :crypto.hash_final()

      Base.encode16(final, case: :lower)
    else
      nil
    end
  end

  @doc """
  Calcula o hash SHA-256 de dados binários.
  """
  def sha256_data(data) do
    # Calcula SHA-256 em binário e converte para hex em lowercase
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
