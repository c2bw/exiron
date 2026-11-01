defmodule ExironClient.FeedbackTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Feedback, Message, Wire}

  test "feedback appends to existing keyboards and respects row/button capacity" do
    original = [[%{text: "Next", callback_data: "next"}]]
    assert {:ok, [row, [positive, negative]] = keyboard} = Feedback.keyboard(original)
    assert [row] == original
    assert positive.text == "👍" and negative.text == "👎"
    assert {:error, :invalid_feedback_keyboard} = Feedback.keyboard(keyboard)
    assert {:error, :invalid_feedback_keyboard} = Feedback.keyboard(List.duplicate(row, 20))
    crowded = List.duplicate(List.duplicate(hd(row), 8), 12)
    assert {:ok, _} = Feedback.keyboard(crowded ++ [[hd(row), hd(row)]])

    assert {:error, :invalid_feedback_keyboard} =
             Feedback.keyboard(crowded ++ [List.duplicate(hd(row), 3)])

    assert {:error, :invalid_feedback_keyboard} = Feedback.keyboard([nil])
    # Ordinary one-shot payloads are unchanged; feedback is explicit.
    refute Map.has_key?(Wire.Payload.response("req", "text", "hello"), :inline_keyboard)
  end

  test "callbacks carry both the rated request and the new request to finish" do
    {:ok, [[positive, negative]]} = Feedback.keyboard()

    for {button, vote} <- [{positive, :positive}, {negative, :negative}] do
      assert {:ok, message} =
               Message.from_server(
                 %{
                   "msgtype" => "request",
                   "datatype" => "callback",
                   "req_id" => "vote-req",
                   "data" => Base.encode64(button.callback_data),
                   "from" => %{"id" => 42},
                   "callback_query" => %{"id" => "click", "origin_req_id" => "rated-req"}
                 },
                 :request
               )

      assert {:ok,
              %Feedback{
                vote: ^vote,
                origin_req_id: "rated-req",
                request_id: "vote-req",
                user_id: 42,
                callback_id: "click"
              }} = Feedback.from_message(message)

      for changed <- [
            %{message | datatype: "text"},
            %{message | msgtype: "listen"},
            %{message | from: nil},
            %{message | callback_query: %{"id" => "click"}},
            %{message | data: "next"}
          ] do
        assert :error = Feedback.from_message(changed)
      end
    end
  end
end
