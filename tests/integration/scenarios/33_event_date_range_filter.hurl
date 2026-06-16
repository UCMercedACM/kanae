# list_events before/after date-range filter. LEADS creates a clearly-past and
# a clearly-future event (both names share a trigram-matchable prefix), then the
# public listing is filtered by date, by name+date, and by a full range. The
# bounds use the (start_at <= $2 OR $2 IS NULL) / (start_at >= $3 OR $3 IS NULL)
# optional-filter predicate, so before/after combine freely and with `name`.

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "33333333-3333-4333-8333-333333333331",
  "name": "scenario33-range-past",
  "description": "clearly in the past",
  "start_at": "2000-01-01T00:00:00Z",
  "end_at":   "2000-01-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
past_id: jsonpath "$.id"

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "33333333-3333-4333-8333-333333333332",
  "name": "scenario33-range-future",
  "description": "clearly in the future",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-01-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
future_id: jsonpath "$.id"

# before only — only events starting on/before the cutoff. Nothing else in the
# stack starts before 2001, so the past event is the sole match.
GET {{KANAE_URL}}/events?before=2001-01-01T00:00:00Z
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
body contains "{{past_id}}"
body not contains "{{future_id}}"

# name + after — trigram matches both events; after narrows to the future one.
GET {{KANAE_URL}}/events?name=scenario33-range&after=2098-01-01T00:00:00Z
HTTP 200
[Asserts]
body contains "{{future_id}}"
body not contains "{{past_id}}"

# name + after + before — full range brackets both.
GET {{KANAE_URL}}/events?name=scenario33-range&after=1999-01-01T00:00:00Z&before=2100-01-01T00:00:00Z
HTTP 200
[Asserts]
body contains "{{past_id}}"
body contains "{{future_id}}"

# name alone (no date filter) — both still returned.
GET {{KANAE_URL}}/events?name=scenario33-range
HTTP 200
[Asserts]
body contains "{{past_id}}"
body contains "{{future_id}}"
