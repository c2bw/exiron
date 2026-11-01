defmodule Exiron.Hub.BootTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Boot, LookupState, Settings}

  test "configure attrs apply all runtime options from one configuration" do
    router = make_ref()
    telegram = make_ref()

    attrs =
      Boot.configure_attrs(router, telegram,
        telegram_pollers_enabled: false,
        client_timeout: 10,
        pending_timeout: 20,
        send_timeout: 30,
        max_pending: 40,
        max_queue_per_hook: 50,
        max_queue_bytes_per_hook: 60,
        max_event_image_preview_bytes: 70,
        max_event_image_history_bytes: 80,
        max_in_flight_sends: 90
      )

    assert %{
             enabled?: true,
             telegram_pollers_enabled?: false,
             telegram_pollers: %{},
             router: ^router,
             telegram: ^telegram,
             settings: %Settings{
               client_timeout: 10,
               pending_timeout: 20,
               send_timeout: 30,
               max_pending: 40,
               max_queue_per_hook: 50,
               max_queue_bytes_per_hook: 60,
               max_event_image_preview_bytes: 70,
               max_event_image_history_bytes: 80,
               max_in_flight_sends: 90
             },
             lookups: %LookupState{generation: generation}
           } = attrs

    assert is_reference(generation)
  end

  test "image history limits have bounded defaults" do
    settings = Settings.from_options([])
    assert settings.max_event_image_preview_bytes == 8 * 1024 * 1024
    assert settings.max_event_image_history_bytes == 64 * 1024 * 1024
  end

  test "image history limits accept zero and clamp negative direct options" do
    assert Settings.from_options(max_event_image_preview_bytes: 123).max_event_image_preview_bytes ==
             123

    assert Settings.from_options(max_event_image_history_bytes: 456).max_event_image_history_bytes ==
             456

    assert Settings.from_options(max_event_image_preview_bytes: 0).max_event_image_preview_bytes ==
             0

    assert Settings.from_options(max_event_image_history_bytes: 0).max_event_image_history_bytes ==
             0

    assert Settings.from_options(max_event_image_preview_bytes: -1).max_event_image_preview_bytes ==
             0

    assert Settings.from_options(max_event_image_history_bytes: -1).max_event_image_history_bytes ==
             0
  end
end
