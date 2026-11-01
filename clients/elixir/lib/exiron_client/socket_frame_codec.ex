defmodule ExironClient.SocketFrameCodec do
  @moduledoc """
  Incremental WebSocket frame decoder.

  The codec owns byte buffering, logical message fragmentation, and the
  configured message-size limit. It never performs I/O or invokes application
  callbacks, which keeps transport and delivery concerns independent.
  """

  alias WebSockex.Frame

  defstruct [:max_frame_size, buffer: <<>>, fragment: nil]

  @type t :: %__MODULE__{
          max_frame_size: pos_integer(),
          buffer: binary(),
          fragment: fragment() | nil
        }

  @type fragment :: %{type: atom(), parts: [binary()], size: non_neg_integer()}

  @spec new(pos_integer()) :: t()
  def new(max_frame_size) when is_integer(max_frame_size) and max_frame_size > 0 do
    %__MODULE__{max_frame_size: max_frame_size}
  end

  @spec append(t(), binary()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = codec, data) when is_binary(data) do
    codec = %{codec | buffer: codec.buffer <> data}

    case validate_frame_size(codec) do
      :ok -> {:ok, codec}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec next_frame(t()) :: {:ok, term(), t()} | :incomplete | {:error, term()}
  def next_frame(%__MODULE__{} = codec) do
    with :ok <- validate_frame_size(codec) do
      case Frame.parse_frame(codec.buffer) do
        :incomplete ->
          :incomplete

        {:ok, frame, buffer} ->
          codec = %{codec | buffer: buffer}
          decode_frame(frame, codec)

        {:error, reason} ->
          {:error, {:protocol_error, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec needs_data?(t()) :: boolean()
  def needs_data?(%__MODULE__{buffer: buffer}), do: byte_size(buffer) > 0

  @doc false
  def frame_header(buffer) when is_binary(buffer) and byte_size(buffer) < 2, do: :incomplete

  def frame_header(
        <<final?::1, reserved::3, opcode::4, masked?::1, payload_size::7, _rest::binary>>
      )
      when payload_size < 126 do
    {:ok, header(final?, reserved, opcode, masked?, payload_size)}
  end

  def frame_header(
        <<final?::1, reserved::3, opcode::4, masked?::1, 126::7, payload_size::16, _rest::binary>>
      ) do
    {:ok, header(final?, reserved, opcode, masked?, payload_size)}
  end

  def frame_header(<<_::16, _rest::binary>> = buffer) when byte_size(buffer) < 4,
    do: :incomplete

  def frame_header(
        <<final?::1, reserved::3, opcode::4, masked?::1, 127::7, payload_size::64, _rest::binary>>
      ) do
    {:ok, header(final?, reserved, opcode, masked?, payload_size)}
  end

  def frame_header(<<_::16, _rest::binary>> = buffer) when byte_size(buffer) < 10,
    do: :incomplete

  defp decode_frame(:ping, codec), do: {:ok, :ping, codec}
  defp decode_frame({:ping, _payload} = frame, codec), do: {:ok, frame, codec}
  defp decode_frame(:pong, codec), do: {:ok, :pong, codec}
  defp decode_frame({:pong, _payload} = frame, codec), do: {:ok, frame, codec}

  defp decode_frame(:close, codec), do: {:ok, :close, codec}

  defp decode_frame({:close, _code, _reason} = frame, codec), do: {:ok, frame, codec}

  defp decode_frame({:fragment, type, payload}, %{fragment: nil} = codec) do
    fragment = %{type: type, parts: [payload], size: byte_size(payload)}
    next_frame(%{codec | fragment: fragment})
  end

  defp decode_frame({:fragment, _type, _payload}, codec),
    do: protocol_error(codec, "new fragment before previous message completed")

  defp decode_frame({:continuation, _payload}, %{fragment: nil} = codec),
    do: protocol_error(codec, "continuation without an open fragment")

  defp decode_frame({:continuation, payload}, codec) do
    fragment = codec.fragment

    fragment = %{
      fragment
      | parts: [payload | fragment.parts],
        size: fragment.size + byte_size(payload)
    }

    next_frame(%{codec | fragment: fragment})
  end

  defp decode_frame({:finish, _payload}, %{fragment: nil} = codec),
    do: protocol_error(codec, "final continuation without an open fragment")

  defp decode_frame({:finish, payload}, codec) do
    fragment = codec.fragment
    payload = IO.iodata_to_binary(Enum.reverse([payload | fragment.parts]))
    codec = %{codec | fragment: nil}

    if fragment.type == :text and not String.valid?(payload) do
      protocol_error(codec, "invalid UTF-8 text frame")
    else
      {:ok, {fragment.type, payload}, codec}
    end
  end

  defp decode_frame({type, _payload}, %{fragment: fragment} = codec)
       when type in [:text, :binary] and not is_nil(fragment),
       do: protocol_error(codec, "data frame received before fragment completed")

  defp decode_frame(frame, codec), do: {:ok, frame, codec}

  defp validate_frame_size(%__MODULE__{buffer: buffer} = codec) do
    case frame_header(buffer) do
      :incomplete ->
        :ok

      {:ok, %{opcode: opcode, payload_size: payload_size}} ->
        frame_size = logical_frame_size(opcode, payload_size, codec.fragment)

        if frame_size > codec.max_frame_size do
          {:error, {:frame_too_large, frame_size}}
        else
          :ok
        end
    end
  end

  defp logical_frame_size(:continuation, payload_size, %{size: fragment_size}),
    do: fragment_size + payload_size

  defp logical_frame_size(opcode, payload_size, _fragment)
       when opcode in [:text, :binary, :continuation],
       do: payload_size

  defp logical_frame_size(_opcode, _payload_size, _fragment), do: 0

  defp protocol_error(codec, message) do
    {:error, {:protocol_error, message, codec.buffer}}
  end

  defp header(final?, reserved, opcode, masked?, payload_size) do
    %{
      final?: final? == 1,
      reserved: reserved,
      opcode: opcode_name(opcode),
      masked?: masked? == 1,
      payload_size: payload_size
    }
  end

  defp opcode_name(0), do: :continuation
  defp opcode_name(1), do: :text
  defp opcode_name(2), do: :binary
  defp opcode_name(8), do: :close
  defp opcode_name(9), do: :ping
  defp opcode_name(10), do: :pong
  defp opcode_name(opcode), do: opcode
end
