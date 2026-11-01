defmodule ExironClient.SocketFrameCodecTest do
  use ExUnit.Case, async: true

  alias ExironClient.SocketFrameCodec

  test "decodes complete text frames and leaves incomplete bytes buffered" do
    codec = SocketFrameCodec.new(32)

    assert {:ok, codec} = SocketFrameCodec.append(codec, text_frame("hello") |> binary_part(0, 3))
    assert :incomplete = SocketFrameCodec.next_frame(codec)

    remainder = text_frame("hello") |> binary_part(3, byte_size(text_frame("hello")) - 3)
    assert {:ok, codec} = SocketFrameCodec.append(codec, remainder)
    assert {:ok, {:text, "hello"}, codec} = SocketFrameCodec.next_frame(codec)
    assert :incomplete = SocketFrameCodec.next_frame(codec)
  end

  test "reassembles fragmented text frames before exposing a message" do
    codec = SocketFrameCodec.new(32)

    assert {:ok, codec} =
             SocketFrameCodec.append(codec, fragment_frame("hel") <> finish_frame("lo"))

    assert {:ok, {:text, "hello"}, codec} = SocketFrameCodec.next_frame(codec)
    assert codec.fragment == nil
  end

  test "rejects a logical message larger than the configured limit" do
    codec = SocketFrameCodec.new(4)

    assert {:error, {:frame_too_large, 5}} =
             SocketFrameCodec.append(codec, text_frame("hello"))
  end

  test "keeps control frames available while a fragmented message is open" do
    codec = SocketFrameCodec.new(32)
    bytes = fragment_frame("hel") <> ping_frame("probe") <> finish_frame("lo")

    assert {:ok, codec} = SocketFrameCodec.append(codec, bytes)
    assert {:ok, {:ping, "probe"}, codec} = SocketFrameCodec.next_frame(codec)
    assert {:ok, {:text, "hello"}, _codec} = SocketFrameCodec.next_frame(codec)
  end

  defp text_frame(payload), do: frame(1, true, payload)
  defp fragment_frame(payload), do: frame(1, false, payload)
  defp finish_frame(payload), do: frame(0, true, payload)
  defp ping_frame(payload), do: frame(9, true, payload)

  defp frame(opcode, final?, payload) do
    <<if(final?, do: 1, else: 0)::1, 0::3, opcode::4, 0::1, byte_size(payload)::7>> <> payload
  end
end
