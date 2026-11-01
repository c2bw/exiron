defmodule ExironWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ExironWeb.CoreComponents

  test "renders the supported input variants" do
    form = Phoenix.Component.to_form(%{"value" => "hello", "enabled" => "true"})

    assert render_component(&CoreComponents.input/1, field: form[:value], type: "hidden") =~
             ~s(type="hidden")

    checkbox = render_component(&CoreComponents.input/1, field: form[:enabled], type: "checkbox")
    assert checkbox =~ ~s(type="checkbox")

    select =
      render_component(&CoreComponents.input/1,
        field: form[:value],
        type: "select",
        options: [One: "one", Two: "two"]
      )

    assert select =~ "<select"
    assert select =~ "One"

    textarea = render_component(&CoreComponents.input/1, field: form[:value], type: "textarea")
    assert textarea =~ "<textarea"

    text = render_component(&CoreComponents.input/1, field: form[:value], type: "text")
    assert text =~ ~s(type="text")
    assert text =~ ~s(value="hello")
  end

  test "renders structural components and icon helpers" do
    assert render_component(&CoreComponents.button/1, %{inner_block: slot("Save")}) =~ "Save"

    assert render_component(&CoreComponents.button/1, %{
             navigate: "/monitor",
             inner_block: slot("Monitor")
           }) =~ ~s(href="/monitor")

    assert render_component(&CoreComponents.header/1, %{inner_block: slot("Title")}) =~ "Title"

    header =
      render_component(&CoreComponents.header/1, %{
        inner_block: slot("Title"),
        subtitle: [%{inner_block: fn _changed, _arg -> "Subtitle" end}]
      })

    assert header =~ "Subtitle"

    assert render_component(&CoreComponents.list/1, %{
             item: [%{title: "Name", inner_block: fn _changed, _arg -> "Ada" end}]
           }) =~ "Ada"

    assert render_component(&CoreComponents.icon/1, name: "hero-x-mark", class: "size-4") =~
             "hero-x-mark"

    flash = render_component(&CoreComponents.flash/1, kind: :error, flash: %{"error" => "Failed"})
    assert flash =~ "Failed"
    assert flash =~ "hero-exclamation-circle"

    table =
      render_component(&CoreComponents.table/1, %{
        id: "people",
        rows: [%{id: 1, name: "Ada"}],
        row_id: &"person-#{&1.id}",
        row_click: fn row -> "select-#{row.id}" end,
        col: [%{label: "Name", inner_block: fn _changed, row -> row.name end}],
        action: [%{inner_block: fn _changed, row -> "Edit #{row.name}" end}]
      })

    assert table =~ ~s(id="person-1")
    assert table =~ "Ada"
    assert table =~ "Edit Ada"

    assert %Phoenix.LiveView.JS{} = CoreComponents.show("#dialog")
    assert %Phoenix.LiveView.JS{} = CoreComponents.hide("#dialog")
  end

  test "translates interpolated validation errors" do
    assert CoreComponents.translate_error({"must be at least %{count}", count: 3}) ==
             "must be at least 3"

    assert CoreComponents.translate_errors([name: {"is required", []}], :name) == ["is required"]
    assert CoreComponents.translate_errors([other: {"ignored", []}], :name) == []
  end

  defp slot(content), do: [%{inner_block: fn _changed, _arg -> content end}]
end
