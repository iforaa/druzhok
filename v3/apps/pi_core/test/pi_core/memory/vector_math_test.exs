defmodule PiCore.Memory.VectorMathTest do
  use ExUnit.Case

  alias PiCore.Memory.VectorMath

  test "cosine_similarity of identical vectors is 1.0" do
    v = [1.0, 2.0, 3.0]
    assert_in_delta VectorMath.cosine_similarity(v, v), 1.0, 0.001
  end

  test "cosine_similarity of orthogonal vectors is 0.0" do
    a = [1.0, 0.0, 0.0]
    b = [0.0, 1.0, 0.0]
    assert_in_delta VectorMath.cosine_similarity(a, b), 0.0, 0.001
  end

  test "cosine_similarity of opposite vectors is -1.0" do
    a = [1.0, 0.0]
    b = [-1.0, 0.0]
    assert_in_delta VectorMath.cosine_similarity(a, b), -1.0, 0.001
  end

  test "cosine_similarity returns 0.0 for zero vectors" do
    assert VectorMath.cosine_similarity([0.0, 0.0], [1.0, 1.0]) == 0.0
  end

  test "chunk_hash returns consistent SHA256" do
    hash1 = VectorMath.chunk_hash("hello world")
    hash2 = VectorMath.chunk_hash("hello world")
    assert hash1 == hash2
    assert byte_size(hash1) == 64
  end

  test "chunk_hash differs for different content" do
    assert VectorMath.chunk_hash("hello") != VectorMath.chunk_hash("world")
  end
end
