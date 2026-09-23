# TypeSafe for Swift

A Swift client for [TypeSafe](https://typesafe.ai)'s System One API and its
flagship model, **Jev**. You send a *state* (a string or JSON) and a set of
typed *questions*; Jev returns one calibrated, typed answer per question —
a chosen option, a position on a rubric, or a probability — never free text.

```swift
import TypeSafe

let client = try TypeSafeClient()  // reads TYPESAFE_API_KEY

let response = try await client.systemOne(
    state: [
        "ticket_message": "My flight was cancelled. Can I get a refund?",
        "refund_policy": "Cancelled flights are eligible for a full refund.",
    ],
    questions: [
        "refund_requested": .noul("Does `ticket_message` request a refund?"),
        "request_type": .choice("What is the main request in `ticket_message`?", criteria: [
            "refund": "The customer wants money returned.",
            "rebooking": "The customer wants a replacement flight.",
            "information": "The customer is asking for information only.",
        ]),
        "frustration": .score("How frustrated does the customer appear in `ticket_message`?", criteria: [
            "Calm and neutral.",
            "Concerned but civil.",
            "Very angry or using strong language.",
        ]),
    ]
)

let refund = try response.noul("refund_requested").noul        // 0.99
let request = try response.choice("request_type")               // .choice == "refund", .confidence == 1.0
let frustration = try response.score("frustration")             // .score == 0.27 (between "Calm" and "Concerned"), .confidence == 0.6
```

Requires Swift 6 and macOS 13 / iOS 16 / tvOS 16 / watchOS 9 / visionOS 1.
Linux is supported through `FoundationNetworking` (not exercised in this
repo's test run).

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/spprichard/SwiftJev.git", from: "0.1.0"),
],
targets: [
    .target(name: "App", dependencies: [.product(name: "TypeSafe", package: "SwiftJev")]),
]
```

## Concepts in one paragraph

Read the [AI primer](https://docs.typesafe.ai/introduction/machine-learning-primer)
and [Primitives](https://docs.typesafe.ai/primitives) for the full picture.
The short version: ask for **one snap judgment per question**, put **every
question that shares a state in one request** (they run in parallel and extra
questions are nearly free), reference parts of a structured state with
backticked paths like `` `ticket.messages[0].text` ``, and combine the typed
answers in your own code. Make a second request only when your code cannot
build it until it has the first answer.

## Questions

| Helper | Wire type | Use when | Answer |
| --- | --- | --- | --- |
| `.choice(_:criteria:)` | `choice` | One of a known, unordered set | `ChoiceAnswer`: `choice`, `probabilities`, `confidence` |
| `.score(_:criteria:)` | `score` | A position on an ordered rubric | `ScoreAnswer`: `score`, `legend`, `probabilities`, `confidence` |
| `.noul(_:criteria:)` | `noul` | A yes/no whose probability is the signal | `NoulAnswer`: `noul` (0…1) |

`instructions` and criteria descriptions accept any JSON, so you can attach
data to a question and refer to it by name:

```swift
"same_person": .noul([
    "potential_duplicate": ["name": "John Smith", "location": "Oakland, California"],
    "question": "Is the resume for the same person as `potential_duplicate`?",
])
```

Choice options that need no description take `nil`; Noul criteria clarify
what yes and no mean:

```swift
"department": .choice("Which team should handle this?", criteria: [
    "billing": "Payments, invoicing, refunds",
    "technical": "Bugs, outages, integrations",
    "other": nil,
]),
"is_urgent": .noul("Does this convey urgency?",
                   criteria: NoulCriteria(yes: "Explicitly time-sensitive", no: "No urgency expressed")),
```

## State

`state` is a `JSONValue`. Build it from literals — objects keep the key
order you wrote, which is the order the model reads — or from any
`Encodable`:

```swift
let state: JSONValue = [
    "ticket": ["subject": "Duplicate charge", "messages": [["from": "customer", "text": "…"]]],
    "order": ["id": "A-104", "charges": [["amount_usd": 49, "status": "captured"]]],
    "refund_policy": "Duplicate charges are eligible for a refund.",
]

let state = try JSONValue(encoding: myCodableTicket)
```

## Answers

```swift
let answer = try response.choice("department")
answer.choice                         // "billing"
answer.probabilities["technical"]     // 0.02
answer.confidence                     // 0.97 — see https://docs.typesafe.ai/confidence
answer.choice(as: Department.self)    // Department.billing, for a String-backed enum
answer.ranked                         // [(option, probability)] most likely first

let score = try response.score("frustration")
score.score                           // 1.04 — can fall between levels
score.legend[1]                       // "Frustrated"
score.normalizedScore                 // 0.52 — rescaled to 0…1 for weighting several scores together
score.mostLikelyLevel                 // 1

let noul = try response.noul("is_urgent")
noul.noul                             // 0.95

response["is_urgent"]                 // Answer? for dynamic access
response.model                        // "jev-1.13.0"
response.usage.inputTokens
response.requestID                    // "req_…" — quote this in support requests
```

The typed accessors throw `TypeSafeError.answerMissing` or
`.answerTypeMismatch` rather than returning optionals, since a missing answer
is a programming error.

## Configuration

```swift
let client = try TypeSafeClient(
    apiKey: "…",                       // default: TYPESAFE_API_KEY
    baseURL: URL(string: "…")!,        // default: TYPESAFE_BASE_URL, then https://api.typesafe.ai
    defaultModel: "jev-preview",       // default: TYPESAFE_DEFAULT_MODEL, then jev-latest
    timeout: .seconds(10),             // per attempt
    retryPolicy: .default,             // see below
    defaultHeaders: ["X-Team": "support"],
    transport: URLSessionTransport(),  // any HTTPTransport
    logger: Logger(label: "ai.typesafe.sdk")
)

// Per call:
try await client.systemOne(state: s, questions: q, model: "jev-preview",
                           options: RequestOptions(timeout: .seconds(3), retryPolicy: .noRetries))

// Available models:
let models = try await client.listModels()   // [ModelCard]
```

### Retries

The default policy matches the official SDKs: 2 retries after the first
attempt on 408, 429, and 5xx (including 529 *overloaded*), on connection
errors, and on timeouts; exponential backoff from 500 ms to 5 s with 25 %
jitter; `Retry-After` / `retry-after-ms` honored up to 60 s. Tune any field
on `RetryPolicy`, or pass `.noRetries`. Cancelling the calling `Task` stops
both the in-flight request and any pending retry.

### Errors

Everything thrown is a `TypeSafeError`:

```swift
do {
    try await client.systemOne(…)
} catch let TypeSafeError.api(error) {
    error.status        // 429
    error.kind          // .rateLimited — also .authentication, .badRequest, .unprocessableEntity, .overloaded, .server, …
    error.message       // "Unknown model: nope"
    error.errorType     // "api_usage_error"
    error.body          // the JSON body as a JSONValue
    error.requestID
    error.retryAfter
} catch TypeSafeError.timeout, TypeSafeError.connection {
    // retries exhausted
} catch let TypeSafeError.decoding(underlying, body) {
    // the response wasn't the JSON this library expects
}
```

### Logging

Uses [swift-log](https://github.com/apple/swift-log). Request summaries
(status, elapsed time, request ID, attempt) log at `.debug`; request and
response bodies at `.trace`. The API key is never logged.

### Custom transport

`HTTPTransport` is a one-method protocol. Implement it to route through
AsyncHTTPClient, add a proxy, or stub the API in tests:

```swift
struct StubTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"model":"jev-1.13.0","answers":{…},"usage":{…}}"#.utf8))
    }
}
let client = try TypeSafeClient(apiKey: "test", transport: StubTransport())
```

## Development

```sh
swift test                                   # unit tests, no network
TYPESAFE_API_KEY=… swift test                # also runs the live integration suite
```

## Design notes

- **`OrderedDictionary`** (swift-collections) backs `JSONObject`, `Questions`, and Choice criteria
  so JSON reaches the API in the order you authored it, as the Python and
  JavaScript SDKs do. Literals work without importing `OrderedCollections`.
- **Request bodies are serialized by `JSONValue.serialized()`**, not
  `JSONEncoder`, because Foundation's encoder does not preserve key order.
  The `Codable` conformances remain for interop (config files, caches).
- **`URLSession` is the default transport** because the API is a single POST
  and a GET; a heavier HTTP client would be disproportionate. The transport is
  pluggable for anyone who needs one.
