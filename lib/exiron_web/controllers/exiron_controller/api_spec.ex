defmodule ExironWeb.ExironController.ApiSpec do
  @moduledoc false

  use OpenApiSpex.ControllerSpecs

  alias ExironWeb.Schemas
  alias OpenApiSpex.Schema

  tags(["Exiron"])

  operation(:status,
    operation_id: "ExironWeb.ExironController.status",
    summary: "Return status scoped to the authenticated hook",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Hub status", "application/json", Schemas.Status},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:capabilities,
    operation_id: "ExironWeb.ExironController.capabilities",
    summary: "Discover protocol capabilities without consuming work or renewing a lease",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Capabilities", "application/json", Schemas.CapabilityResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"API rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:auth,
    operation_id: "ExironWeb.ExironController.auth",
    summary: "Authenticate a hook token",
    description:
      "Validates a hook token. The token may be sent in the JSON body as hook_token or as a bearer token.",
    request_body: {"Auth request", "application/json", Schemas.AuthRequest, required: false},
    security: [%{}, %{"bearerAuth" => []}],
    responses: [
      ok: {"Auth result", "application/json", Schemas.AuthResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:requests,
    operation_id: "ExironWeb.ExironController.requests",
    summary: "Poll queued Telegram requests for the authenticated hook",
    parameters: [
      "x-exiron-sdk": [
        in: :header,
        type: :string,
        required: false,
        description: "Optional self-reported SDK: go or elixir. Display metadata only."
      ],
      "x-exiron-sdk-version": [
        in: :header,
        schema: %Schema{type: :string, maxLength: 64},
        required: false,
        description: "Optional SDK package SemVer, independent of the wire protocol."
      ],
      client_id: [
        in: :query,
        type: :string,
        required: true,
        description: "Stable identifier for this client instance"
      ],
      listen: [
        in: :query,
        schema: %Schema{type: :string, enum: ["false", "true", "all"]},
        required: false,
        description:
          "Use true for listen-style Telegram messages, or all to also receive routed matches as listen messages"
      ],
      delivery_mode: [
        in: :query,
        schema: %Schema{type: :string, enum: ["explicit"]},
        required: false,
        description: "Retain each batch until its delivery_id is acknowledged"
      ],
      delivery_ack: [
        in: :query,
        type: :string,
        required: false,
        description: "delivery_id successfully handled by the previous poll"
      ]
    ],
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Queued requests", "application/json", Schemas.RequestsResponse},
      bad_request: {"Invalid client id", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      conflict: {"Another client is connected for this hook", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:delivery,
    operation_id: "ExironWeb.ExironController.delivery",
    summary: "Inspect the latest delivery operation by request ID or diagnostic ID",
    parameters: [id: [in: :path, type: :string, required: true]],
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Delivery diagnostics", "application/json", Schemas.DeliveryDiagnostics},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Diagnostics no longer retained", "application/json", Schemas.Error},
      conflict: {"Delivery belongs to another hook", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Unavailable", "application/json", Schemas.Error}
    ]
  )

  operation(:retire_client,
    operation_id: "ExironWeb.ExironController.retire_client",
    summary: "Acknowledge a completed owned batch and release its session without fetching work",
    security: [%{"bearerAuth" => []}],
    request_body: {"Fenced batch identity", "application/json", Schemas.ClientLeaseRequest},
    responses: [
      ok: {"Retired", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid identity", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      conflict: {"Session or batch no longer owned", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:renew_lease,
    operation_id: "ExironWeb.ExironController.renew_lease",
    summary: "Renew an owned HTTP batch lease without consuming or acknowledging work",
    security: [%{"bearerAuth" => []}],
    request_body: {"Lease identity", "application/json", Schemas.ClientLeaseRequest},
    responses: [
      ok: {"Renewed", "application/json", Schemas.ClientLeaseResponse},
      bad_request: {"Invalid identity", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      conflict: {"Lease or batch no longer owned", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:client_runtime_report,
    operation_id: "ExironWeb.ExironController.client_runtime_report",
    summary: "Record bounded client runtime observations without changing lease or delivery",
    security: [%{"bearerAuth" => []}],
    request_body: {"Runtime observation", "application/json", Schemas.ClientRuntimeReport},
    responses: [
      ok: {"Recorded or older sequence ignored", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid report", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      conflict: {"Session no longer owned", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:handler_report,
    operation_id: "ExironWeb.ExironController.handler_report",
    summary: "Report bounded client handler attempt state without changing delivery",
    security: [%{"bearerAuth" => []}],
    request_body: {"Handler report", "application/json", Schemas.HandlerReport},
    responses: [
      ok: {"Recorded or already observed", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid report", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Trace no longer retained", "application/json", Schemas.Error},
      conflict:
        {"Request or batch belongs to another recipient", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:request_state,
    operation_id: "ExironWeb.ExironController.request_state",
    summary: "Read owned request state without polling work or renewing a client lease",
    security: [%{"bearerAuth" => []}],
    parameters: [req_id: [in: :query, type: :string, required: true]],
    responses: [
      ok: {"Request state", "application/json", Schemas.RequestState},
      bad_request: {"Invalid request ID", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"State no longer retained", "application/json", Schemas.Error},
      conflict: {"Another hook's request", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      service_unavailable: {"Disabled", "application/json", Schemas.Error}
    ]
  )

  operation(:cancellations,
    operation_id: "ExironWeb.ExironController.cancellations",
    summary: "Cancel a pending request and stop its remaining sends",
    security: [%{"bearerAuth" => []}],
    request_body: {"Cancellation", "application/json", Schemas.CancelPayload},
    responses: [
      ok: {"Request cancelled", "application/json", Schemas.CancelResponse},
      bad_request: {"Invalid request ID", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Request no longer pending", "application/json", Schemas.Error},
      conflict: {"Request belongs to another hook", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Unavailable", "application/json", Schemas.Error}
    ]
  )

  operation(:idempotent_responses,
    operation_id: "ExironWeb.ExironController.idempotent_responses",
    summary: "Send a response for a pending Telegram request",
    security: [%{"bearerAuth" => []}],
    request_body: {"Response payload", "application/json", Schemas.IdempotentResponsePayload},
    responses: [
      ok: {"Response accepted", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid payload", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Request not found", "application/json", Schemas.Error},
      conflict:
        {"Request cannot be accepted in its current state", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled or saturated", "application/json", Schemas.Error},
      gateway_timeout: {"Telegram delivery result timed out", "application/json", Schemas.Error},
      internal_server_error: {"Unhandled downstream error", "application/json", Schemas.Error}
    ]
  )

  operation(:idempotent_push,
    operation_id: "ExironWeb.ExironController.idempotent_push",
    summary: "Push a message to all or one push-enabled Telegram chat routed to the hook",
    security: [%{"bearerAuth" => []}],
    request_body: {"Push payload", "application/json", Schemas.IdempotentPushPayload},
    responses: [
      ok: {"Push result", "application/json", Schemas.PushResponse},
      bad_request: {"Invalid payload", "application/json", Schemas.Error},
      conflict:
        {"Operation running, key conflict or result unavailable", "application/json",
         Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled or saturated", "application/json", Schemas.Error},
      gateway_timeout: {"Telegram delivery result timed out", "application/json", Schemas.Error},
      internal_server_error: {"Unhandled downstream error", "application/json", Schemas.Error}
    ]
  )

  operation(:responses,
    operation_id: "ExironWeb.ExironController.responses",
    summary: "Send a response for a pending Telegram request",
    security: [%{"bearerAuth" => []}],
    request_body: {"Response payload", "application/json", Schemas.ResponsePayload},
    responses: [
      ok: {"Response accepted", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid payload", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Request not found", "application/json", Schemas.Error},
      conflict:
        {"Request cannot be accepted in its current state", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled or saturated", "application/json", Schemas.Error},
      gateway_timeout: {"Telegram delivery result timed out", "application/json", Schemas.Error},
      internal_server_error: {"Unhandled downstream error", "application/json", Schemas.Error}
    ]
  )

  operation(:actions,
    operation_id: "ExironWeb.ExironController.actions",
    summary: "Send a typing or upload action for a pending request",
    security: [%{"bearerAuth" => []}],
    request_body: {"Action", "application/json", Schemas.ActionPayload},
    responses: [
      ok: {"Action sent", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid action", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Request not found", "application/json", Schemas.Error},
      conflict: {"Request not assigned or busy", "application/json", Schemas.Error},
      service_unavailable: {"Unavailable", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      internal_server_error: {"Downstream error", "application/json", Schemas.Error},
      gateway_timeout: {"Delivery unknown", "application/json", Schemas.Error}
    ]
  )

  operation(:edits,
    operation_id: "ExironWeb.ExironController.edits",
    summary: "Edit text or buttons on a retained completed reply",
    security: [%{"bearerAuth" => []}],
    request_body: {"Text or keyboard edit", "application/json", Schemas.ResponsePayload},
    responses: [
      ok: {"Reply edited", "application/json", Schemas.OkResponse},
      bad_request: {"Invalid edit", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Reply no longer retained", "application/json", Schemas.Error},
      conflict: {"Request not assigned or busy", "application/json", Schemas.Error},
      service_unavailable: {"Unavailable", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      internal_server_error: {"Downstream error", "application/json", Schemas.Error},
      gateway_timeout: {"Delivery unknown", "application/json", Schemas.Error}
    ]
  )

  operation(:push,
    operation_id: "ExironWeb.ExironController.push",
    summary: "Push a message to all or one push-enabled Telegram chat routed to the hook",
    security: [%{"bearerAuth" => []}],
    request_body: {"Push payload", "application/json", Schemas.DataPayload},
    responses: [
      ok: {"Push result", "application/json", Schemas.PushResponse},
      bad_request: {"Invalid payload", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled or saturated", "application/json", Schemas.Error},
      gateway_timeout: {"Telegram delivery result timed out", "application/json", Schemas.Error},
      internal_server_error: {"Unhandled downstream error", "application/json", Schemas.Error}
    ]
  )
end
