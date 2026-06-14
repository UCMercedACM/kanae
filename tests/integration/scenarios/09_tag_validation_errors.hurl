# Every validation guard on ModifiedTag and the tag mutation
# endpoints must fire as 422 with the documented RequestValidationError
# shape — never 5xx, never silently dropped. Catches Pydantic-version
# drift where new validators don't fire as expected.

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ROOT_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

# Missing required `description` field.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario10-no-desc" }
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors" isCollection
jsonpath "$.errors[*].type" contains "missing"
jsonpath "$.errors[*].loc[*]" contains "description"

# Missing both fields.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{}
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "title"
jsonpath "$.errors[*].loc[*]" contains "description"

# Wrong types for both fields.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": 12345, "description": ["a","b"] }
HTTP 422

# Null values for required fields.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": null, "description": null }
HTTP 422

# Body is a JSON primitive, not an object.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
"just a string"
HTTP 422

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
42
HTTP 422

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
true
HTTP 422

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
null
HTTP 422

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
[1,2,3]
HTTP 422

# Body isn't JSON at all — wrap in triple-backticks so Hurl treats
# the raw text as body, not as the next request's HTTP method.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
```
this is not json
```
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "json_invalid"

# Empty body with JSON content-type.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
HTTP 422

# Title violating the NO_NULL_REGEX pattern (NUL byte via \u0000).
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario10\u0000nul", "description": "ok" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# Same on PUT.
PUT {{KANAE_URL}}/tags/1
Content-Type: application/json
{}
HTTP 422

PUT {{KANAE_URL}}/tags/1
Content-Type: application/json
{ "title": null, "description": null }
HTTP 422

# Path param validation also fires before body — wrong-shape id never
# reaches body validation, so the only error type is for path.
PUT {{KANAE_URL}}/tags/not-a-number
Content-Type: application/json
{ "title": "x", "description": "y" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "tag_id"
