# Surface-level checks that the app boots and exposes its
# documentation + OpenAPI spec correctly. Everything downstream
# (Schemathesis, frontend codegen, /docs in a browser) breaks
# silently if any of these regress.

GET {{KANAE_URL}}/
HTTP 307
[Asserts]
header "location" contains "/docs"
header "location" not contains "openapi"

GET {{KANAE_URL}}/docs
HTTP 200
[Asserts]
header "content-type" startsWith "text/html"
duration <= 5000
body contains "ReDoc"
body contains "spec-url"
body contains "/openapi.json"
body matches "<title>.*Kanae.*</title>"

GET {{KANAE_URL}}/openapi.json
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.openapi" matches "^3\\."
jsonpath "$.info" isObject
jsonpath "$.info.title" isString
jsonpath "$.info.version" isString
jsonpath "$.paths" isObject
jsonpath "$.components.schemas" isObject
jsonpath "$.paths['/tags']" exists
jsonpath "$.paths['/tags/{tag_id}']" exists
jsonpath "$.paths['/tags/create']" exists
jsonpath "$.paths['/tags/bulk-create']" exists
jsonpath "$.paths['/events']" exists
jsonpath "$.paths['/events/{event_id}']" exists
jsonpath "$.paths['/events/create']" exists
jsonpath "$.paths['/events/{event_id}/join']" exists
jsonpath "$.paths['/events/{event_id}/verify']" exists
jsonpath "$.paths['/projects']" exists
jsonpath "$.paths['/projects/{project_id}']" exists
jsonpath "$.paths['/projects/create']" exists
jsonpath "$.paths['/projects/{project_id}/join']" exists
jsonpath "$.paths['/projects/{project_id}/leave']" exists
jsonpath "$.paths['/projects/{project_id}/bulk-join']" exists
jsonpath "$.paths['/members/me']" exists
jsonpath "$.paths['/members/{member_id}']" exists
jsonpath "$.paths['/members/me/projects']" exists
jsonpath "$.paths['/members/me/events']" exists
jsonpath "$.paths['/members/logout']" exists
jsonpath "$.paths['/tags/{tag_id}'].get.responses['200']" exists
jsonpath "$.paths['/tags/{tag_id}'].get.responses['404']" exists
jsonpath "$.components.schemas.ModifiedTag.properties.title.pattern" matches "\\^\\[\\^"
jsonpath "$.components.schemas.ModifiedTag.properties.description.pattern" matches "\\^\\[\\^"
body contains "minimum"
body contains "maximum"


OPTIONS {{KANAE_URL}}/tags
Origin: http://localhost:5173
Access-Control-Request-Method: GET
Access-Control-Request-Headers: content-type
HTTP 200
[Asserts]
header "access-control-allow-origin" == "http://localhost:5173"
header "access-control-allow-methods" contains "GET"
header "access-control-allow-credentials" == "true"
