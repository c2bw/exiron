defmodule Exiron.Hub.MessageMetadataTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.{MediaAlbum, MessageMetadata}

  test "validates entity offsets as UTF-16 units and rejects malformed options" do
    assert :ok =
             MessageMetadata.validate("text", "😀x",
               entities: [%{type: "bold", offset: 2, length: 1}]
             )

    assert {:error, :invalid_payload} =
             MessageMetadata.validate("text", "😀x",
               entities: [%{type: "bold", offset: 3, length: 1}]
             )

    for opts <- [
          [message_thread_id: -1],
          [file_name: "../name"],
          [entities: "bad"],
          [caption: 123]
        ] do
      assert {:error, :invalid_payload} = MessageMetadata.validate("text", "hello", opts)
    end
  end

  test "album encoding preserves captions and filenames, with type and base64 validation" do
    items = [
      %{datatype: "image", data: "one", caption: "hello", file_name: "one.jpg"},
      %{datatype: "video", data: "two", mime_type: "video/mp4"}
    ]

    assert {:ok, ^items} = items |> MediaAlbum.encode() |> MediaAlbum.decode()
    assert {:error, :invalid_payload} = MediaAlbum.decode(~s([{"datatype":"image","data":"bad"}]))
    mixed = [%{datatype: "image", data: "one"}, %{datatype: "audio", data: "two"}]
    assert {:error, :invalid_payload} = mixed |> MediaAlbum.encode() |> MediaAlbum.decode()
    assert {:error, :invalid_payload} = MediaAlbum.decode("not json")
  end
end
