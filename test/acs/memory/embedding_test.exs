defmodule Acs.Memory.EmbeddingTest do
  use ExUnit.Case, async: false

  alias Acs.Memory.Embedding

  describe "embed_text/1" do
    @tag :needs_ollama
    test "generates embedding for text" do
      {:ok, embedding} = Embedding.embed_text("cache release ordering")
      assert is_list(embedding)
      assert embedding != []
      assert Enum.all?(embedding, &is_float/1)
    end

    @tag :needs_ollama
    test "generates consistent embeddings for same text" do
      text = "test memory content"

      {:ok, embedding1} = Embedding.embed_text(text)
      {:ok, embedding2} = Embedding.embed_text(text)

      assert length(embedding1) == length(embedding2)

      diff =
        Enum.zip(embedding1, embedding2)
        |> Enum.map(fn {a, b} -> abs(a - b) end)
        |> Enum.sum()

      assert diff < 0.001, "Embeddings should be nearly identical"
    end

    @tag :needs_ollama
    test "different texts produce different embeddings" do
      {:ok, embedding1} = Embedding.embed_text("cache release ordering")
      {:ok, embedding2} = Embedding.embed_text("task assignment conflict")

      diff_count =
        Enum.zip(embedding1, embedding2)
        |> Enum.count(fn {a, b} -> abs(a - b) > 0.01 end)

      assert diff_count > length(embedding1) * 0.5,
             "Different texts should produce different embeddings"
    end
  end

  describe "embed_texts/1" do
    @tag :needs_ollama
    test "generates embeddings for multiple texts" do
      texts = [
        "cache release ordering",
        "task assignment conflict",
        "file lock management"
      ]

      {:ok, embeddings} = Embedding.embed_texts(texts)

      assert length(embeddings) == 3
      assert Enum.all?(embeddings, &is_list/1)
      assert Enum.all?(embeddings, fn e -> length(e) == length(hd(embeddings)) end)
    end

    test "handles empty list" do
      {:ok, embeddings} = Embedding.embed_texts([])
      assert embeddings == []
    end
  end

  describe "fingerprint/2" do
    test "is stable for the same text and model" do
      assert Embedding.fingerprint("memory", "model") ==
               Embedding.fingerprint("memory", "model")
    end

    test "changes when text or model changes" do
      refute Embedding.fingerprint("memory", "model") ==
               Embedding.fingerprint("changed", "model")

      refute Embedding.fingerprint("memory", "model") ==
               Embedding.fingerprint("memory", "other")
    end
  end

  describe "normalize/1" do
    test "normalizes vector to unit length" do
      embedding = [3.0, 4.0]

      normalized = Embedding.normalize(embedding)

      magnitude = :math.sqrt(Enum.reduce(normalized, 0, fn x, acc -> x * x + acc end))
      assert abs(magnitude - 1.0) < 0.0001
    end

    test "preserves direction of vector" do
      embedding = [1.0, 2.0, 3.0]

      normalized = Embedding.normalize(embedding)

      Enum.zip(embedding, normalized)
      |> Enum.each(fn {orig, norm} ->
        assert (orig > 0 and norm > 0) or (orig < 0 and norm < 0) or orig == norm
      end)
    end

    test "handles zero vector" do
      embedding = [0.0, 0.0, 0.0]

      normalized = Embedding.normalize(embedding)

      assert Enum.all?(normalized, &(&1 == 0.0))
    end
  end

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vector = [0.5, 0.5, 0.5, 0.5]

      similarity = Embedding.cosine_similarity(vector, vector)

      assert abs(similarity - 1.0) < 0.0001
    end

    test "returns 0.0 for orthogonal vectors" do
      vector1 = [1.0, 0.0, 0.0]
      vector2 = [0.0, 1.0, 0.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert abs(similarity) < 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      vector1 = [1.0, 0.0, 0.0]
      vector2 = [-1.0, 0.0, 0.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert abs(similarity - -1.0) < 0.0001
    end

    test "returns value between -1 and 1 for general vectors" do
      vector1 = [1.0, 2.0, 3.0]
      vector2 = [2.0, 4.0, 6.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert similarity > 0.99
      assert similarity <= 1.0
    end
  end

  describe "error handling" do
    test "handles Ollama connection failure gracefully" do
      result = Embedding.embed_text("test")

      assert match?({:ok, _} when elem(result, 0) == :ok, result) or
               match?({:error, _}, result)
    end

    test "health check Req options are accepted" do
      # Regression: invalid opts (e.g. connect_timeout on Req 0.6) raise ArgumentError
      # and available?/0 permanently rescues to false even when Ollama is up.
      result =
        try do
          Req.get("http://127.0.0.1:9/api/tags", receive_timeout: 5_000, retry: false)
        rescue
          ArgumentError -> :bad_options
        end

      refute result == :bad_options
    end
  end
end
