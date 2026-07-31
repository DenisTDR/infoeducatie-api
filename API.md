# InfoEducatie integration API

The production base URL is `https://api.infoeducatie.ro`. Integration
endpoints use service API keys issued by an administrator from
**Security > API keys** in RailsAdmin.

Send the key only as a Bearer token:

```http
Authorization: Bearer ie_api_IDENTIFIER.SECRET
```

Keys have immutable scopes and expiry dates. Store the plaintext token in the
calling service's secret manager; it is shown only once. Existing keys must be
replaced when a new scope is needed.

## Scopes

| Scope | Access |
| --- | --- |
| `competitions:read` | List competitions and aggregate counts |
| `competition_data:read` | Export participants and projects |
| `competition_results:write` | Update results and conclude a competition |
| `participants:personal_data:read` | Include sensitive participant data in an export |

The personal-data scope also requires `competition_data:read`.

## List competitions

```http
GET /v1/integrations/competitions
GET /v1/integrations/competitions?year=2026
```

Required scope: `competitions:read`.

## Export competition data

```http
GET /v1/integrations/competition_data?competition_id=31
GET /v1/integrations/competition_data?year=2026
```

Required scope: `competition_data:read`. Add `include=personal_data` only when
the key also has `participants:personal_data:read`.

## Update results and conclude a competition

```http
PUT /v1/integrations/competitions/:competition_id/results
```

Required scope: `competition_results:write`.

Example request:

```sh
curl --request PUT \
  https://api.infoeducatie.ro/v1/integrations/competitions/31/results \
  --header "Authorization: Bearer ${INFOEDUCATIE_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{
    "projects": [
      {"id": 1518, "score": 92.5, "extra_score": 5, "place": "I"},
      {"id": 1524, "score": 88, "extra_score": 0, "place": "II"}
    ],
    "conclude": true
  }'
```

Each project entry has:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Positive project ID from the competition-data export |
| `score` | yes | Finite, non-negative base score |
| `extra_score` | no | Finite, non-negative Open/bonus score; omission preserves its stored value |
| `place` | yes | Placement/prize label of at most three characters, or `null`/`""` for no prize |

`total_score` is never accepted from the caller. It is recalculated as `score +
extra_score` by the application. Only approved, finished projects belonging to
the selected competition may be updated.

With `conclude: false`, the endpoint may update a subset and does not change the
competition's publication state. It never reopens or unpublishes results.

With `conclude: true`, the request must contain every approved, finished project
in the competition, and the competition itself must already be published. All
project changes and result publication happen in one database transaction.
Invalid or incomplete submissions write nothing. A successful conclusion
publishes the scores and placements on the public results page.
Identical `PUT` requests can be retried safely. Project creation, imports, and
approval-status changes must be paused while the final conclusion request runs;
the endpoint locks the competition and its existing project roster.

Example response:

```json
{
  "data": {
    "competition": {
      "id": 31,
      "year": 2026,
      "name": "Olimpiada Nationala 2026",
      "concluded": true
    },
    "projects": [
      {
        "id": 1518,
        "score": 92.5,
        "extra_score": 5.0,
        "total_score": 97.5,
        "place": "I"
      }
    ]
  },
  "meta": {
    "updated_count": 1,
    "generated_at": "2026-07-31T16:00:00.000+03:00"
  }
}
```

## Errors and operation

Errors use an `error` object with `code`, `message`, and `request_id`. Result
validation failures also include an `issues` array with field paths. Important
statuses are:

- `400` for invalid JSON or an invalid competition ID;
- `401` for a missing, malformed, expired, or revoked key;
- `403` when the key lacks the required scope;
- `404` when the competition does not exist;
- `422` for malformed, ineligible, or incomplete results, or when concluding an
  unpublished competition;
- `429` when the integration rate limit is exceeded.

Production accepts API keys only over HTTPS. Responses are marked
`private, no-store`. The shared default limit is 300 integration requests per
key per minute; callers should respect the `Retry-After` header on `429`.

## Legacy public endpoints

The existing public API also exposes:

- `GET /alumnis`
- `GET /pages`
- `GET /editions/:id/news`
- `GET /editions/:id/projects`
- `GET /editions/:id/sponsors`
- `GET /editions/:id/talks`
- `GET /users/:id`
