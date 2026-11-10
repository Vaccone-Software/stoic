# App Attest vectors

Bytes a verifier of App Attest, in any language, can be checked against
(design/29, Testing).

## `apple-development.json`: Apple's own bytes

Seven attestations and assertions captured from iPhones (iOS 14.2 to 14.4) in
the **development** environment, taken from the test resources of
[devicecheck-appattest](https://github.com/veehaitch/devicecheck-appattest)
(Apache License 2.0; see `NOTICE`). For each sample:

- `attestation`: the attestation object (base64), as `attestKey` returned it,
  for key `keyID`, over `SHA-256(attestationClientData)`. App id
  `teamID.bundleID`. Its credential certificate is valid for three days around
  `attestedAt`; verify at that moment, against Apple App Attestation Root CA
  (SHA-256 `1cb9823b…c932`, in the file's `root`).
- `assertion`: an assertion by the same key over
  `SHA-256(assertionClientData)`, with counter `assertionCounter`.

There is no production capture: the production AAGUID (`appattest` and seven
zero bytes) is tested against the stand-in only.

## `app-attest-v1.json`: request signing format v1

Made once by `AppAttestStandIn` (a test root, P-384; real P-256 keys) and
committed; re-recorded only with `STOIC_RECORD_VECTORS=1`.

- `root`: the test root, DER, base64. `app`, `environment`, `validAt`.
- `challenge`, `keyID`, `attestation`: an enrolment; verify the attestation of
  `keyID` over `SHA-256(challenge)` at `validAt` against `root`.
- `requests`: in order, each signed by that key with challenge `nonce`:
  `method`, `authority` (the server's configured one), `path` and `query` as
  received (the query without its `?`), `body` (base64), `idempotencyKey`, the
  `headers` received, the exact signature `base` (UTF-8, lines joined by a line
  feed, none after the last), and `clientDataHash` (base64 of `SHA-256(base)`).
  A request with a `failure` must be refused with that check (`replayed`,
  `body_digest`, `signature`); the others verify, each with its `counter`,
  committing the record before the next.
- `workedExample`: design/29's worked example, its base and client data hash.

The signature base is design/29's format v1: covered components `"@method"`,
`"@authority"`, `"@path"`, `"@query"`, `"content-digest"`, and
`"idempotency-key"` when the request has one; parameters `keyid`, `nonce`
(standard base64 with padding) and `alg="apple-app-attest"`, in that order;
label `attest`. The assertion signs `SHA-256(base)`: its nonce is
`SHA-256(authenticatorData ‖ SHA-256(base))`, and the ECDSA P-256 signature is
over that nonce with SHA-256.
