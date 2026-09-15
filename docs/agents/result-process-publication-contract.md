---
title: Result Process Publication Contract (Database-owned)
docType: contract
scope: repo
status: active
authoritative: true
owner: database-engine
language: en
whenToUse:
  - when implementing or consuming the manager-attested Result Process publication command
  - when Release orchestrates a state-120 Result publication or its readback
whenToUpdate:
  - when the publication request, response, error, receipt, hash-domain or authorization contract changes
checkPaths:
  - docs/agents/result-process-publication-contract.md
  - supabase/migrations/*result_process_publication*.sql
lastReviewedAt: 2026-09-15
lastReviewedCommit: "fc21d401f7c87a516af938f9136dd36eba4118e9"
lastReviewedNote: "Contract reviewed against branch base fc21d401 with the implementation now delivered in migration 20260915150000 and exercised by its pgTAP suite and the two-client concurrency harness on a disposable task database. The command, receipt and readback exist as described here. This is local migration and test evidence only: no hosted, Dev or production deployment is claimed, and cross-repository consumer integration remains separate work."
related:
  - ../../AGENTS.md
  - ./repo-architecture.md
  - ./repo-validation.md
---

# Result Process Publication Contract

## 1. Representation decision

Manager confirmation, the executable publication approval and the publication receipt are
**F4 authoritative authorization and audit records**. The recorded truth is
`manager_attestation`. It is **not** verified calculation lineage, and nothing in this
contract may be presented as machine-verified computational provenance.

Consequences:

- The Data Product Manager is an authorized attestor. Ordinary ownership, a client-supplied
  role, and service credentials are each insufficient on their own.
- The receipt is immutable and append-only. An existing attestation is never updated and is
  never promoted to machine provenance.
- A conflicting publication requires a **new explicitly authorized identity/version**. A row
  at 120 is never demoted, rewritten or auto-migrated, including from legacy 100.
- Mutable derivative search fields (`extracted_md`, `search_text`, `embedding_ft`,
  `embedding_ft_at`) remain governed by the existing lifecycle contract.

## 2. Transport and authorization

Three `api`-schema PostgREST RPCs, callable with an actor JWT under the existing CLI
transport capability (`CLI-RPC-01`). No service key is required or accepted as authority,
and no Edge endpoint is introduced.

| Purpose | Function |
| --- | --- |
| Prepare | `api.qry_result_process_publish_prepare_v1(p_request jsonb)` |
| Execute | `api.cmd_result_process_publish_v1(p_request jsonb)` |
| Readback | `api.qry_result_process_publication_readback_v1(p_request jsonb)` |

- Actor is always the server-derived `auth.uid()`. A request field naming an actor is
  rejected as unknown.
- Every call, including readback and every retry, re-checks
  `private.lca_release_is_manager()` against live role state, on prepare, execute AND readback.
  Revocation therefore blocks all three on the next request. It does **not** delete or rewrite
  already-recorded receipts: those rows remain stored and unchanged, and they become readable
  again only if the role is restored, since readback itself re-checks the live role.
- Both `role` and `targetState` are fixed server-side. A request cannot carry them.

## 3. Hash domains

Two distinct, explicitly named domains. They are never assumed equal.

| Domain | Definition | Used for |
| --- | --- | --- |
| `result-process-content.v1` | `sha256` over the UTF-8 bytes of the **exact stored** `json_ordered` text | identity of the published content; receipt binding; readback verification |
| `result-process-preparation.v1` | `sha256` over the server canonical encoding of the immutable prepare inputs plus actor and precondition | `preparationHash` |

The client's RFC 8785 canonicalization and the database's jsonb canonicalization are **not**
assumed to agree. The command verifies the caller's `contentSha256` against the stored-byte
domain above. Incoming Candidate bytes are preserved; no normalization is applied. If any
normalization is ever permitted it must introduce a separate canonical hash definition
rather than redefine the stored-byte domain.

All hashes are lowercase hex SHA-256 (64 characters).

### Storage-byte preservation, verified

`public.processes.json_ordered` is `json`, which preserves the exact input bytes: key order,
whitespace and duplicate keys all survive storage, unlike `jsonb` which normalizes layout and
silently collapses duplicate keys. Measured on the task database: `{"b":1,  "a":2}` is stored
byte-identically, and `{"a":1,"a":2}` keeps both members in `json` while `jsonb` reduces it to
`{"a": 2}`. The command therefore:

- writes the caller's `contentText` cast to `json` and nothing else, so the stored bytes are
  the attested bytes;
- hashes and re-reads `json_ordered::text`, never a jsonb rendering;
- rejects a document containing a duplicate key at any level, because `json` and `jsonb`
  disagree about it and the derived `json` copy would diverge from what readers see;
- relies on the existing `processes_json_sync_trigger` to populate `json` and `version` from
  `json_ordered`. No trigger is disabled, and the required version path is `json_ordered`,
  which the command validates before insert.

### Bounds and normalization of request scalars

| Field | Bound |
| --- | --- |
| `contentText` | valid UTF-8 JSON object, 2 bytes .. 1 MiB by `octet_length` |
| `contentSha256` | exactly 64 lowercase hex, no whitespace |
| `idempotencyKey` | 1..200 characters after no trimming; leading/trailing whitespace rejected rather than trimmed |
| `audit.reason` | 1..1000 characters, `octet_length` <= 4000, no control characters |
| `source.*Hash`, `expectedPreparationHash` | exactly 64 lowercase hex |

## 4. Prepare

Prepare must not depend on a future executable plan or approval, so it carries no such
hash. It validates the content and identity, decides the precondition class, and returns a
deterministic `preparationHash` over immutable input, actor and precondition only.

Request:

```json
{ "table": "processes", "id": "<uuid>", "version": "NN.NN.NNN",
  "contentText": "<UTF-8 JSON text>", "contentSha256": "<64 hex>",
  "sourceKind": "manager_attestation",
  "source": { "candidateSetHash": "<64 hex>", "sourceManifestHash": "<64 hex>" },
  "audit": { "reason": "<1..1000 chars>" } }
```

Response:

```json
{ "ok": true, "data": {
    "schemaVersion": "result-process.publish-prepare.v1",
    "preparationHash": "<64 hex>",
    "actorUserId": "<uuid>", "id": "<uuid>", "version": "NN.NN.NNN",
    "contentSha256": "<64 hex>", "hashDomain": "result-process-content.v1",
    "sourceKind": "manager_attestation",
    "classification": "absent" | "candidate_content_matches_existing" | "conflict",
    "existingState": null | -1 | 0 | 20 | 100 | 120 | 200 } }
```

`preparationHash` is the server preparation digest. It is **not** the client's
`executablePlanHash` and **not** the client's `approvalHash`; Release keeps all three
separate. Prepare is read-only.

Prepare carries no idempotency key, no executable plan hash and no approval hash, because it
must not depend on artifacts that do not exist yet. `classification` therefore describes
**content candidacy only**, and never authorization and never a no-op:

| Value | Meaning |
| --- | --- |
| `absent` | no row exists for this exact identity |
| `candidate_content_matches_existing` | a row exists at 120 whose **stored content hash equals this request's content hash**. This is strictly a **content-only** observation: it does **not** compare actor, source bindings, audit reason or any attesting hash, it does **not** mean the publication is authorized, and it does **not** mean execute would be a no-op |
| `conflict` | a row exists that is not a published 120 row with this exact stored content hash. This includes a published row whose content differs, a legacy row at another state, and a draft. It is a state-and-content observation only; **source bindings are not compared here** |

Execute with a different `idempotencyKey` than the one that created an existing receipt
still conflicts. Candidacy at prepare time never substitutes for the receipt check, and no
no-op is ever released without an exact receipt match.

## 5. Execute

Request: the full prepare request plus the client's own authorization evidence and the
expected precondition. Execute independently revalidates identity, content hash and
classification, and requires the caller's `expectedPreparationHash` to equal the value it
recomputes, so a stale or tampered preparation cannot be executed.

```json
{ "table": "processes", "id": "<uuid>", "version": "NN.NN.NNN",
  "contentText": "<UTF-8 JSON text>", "contentSha256": "<64 hex>",
  "sourceKind": "manager_attestation",
  "source": { "candidateSetHash": "<64 hex>", "sourceManifestHash": "<64 hex>",
              "executablePlanHash": "<64 hex>", "approvalHash": "<64 hex>" },
  "expectedPreparationHash": "<64 hex>",
  "idempotencyKey": "<1..200 chars>",
  "audit": { "reason": "<1..1000 chars>" } }
```

`executablePlanHash` and `approvalHash` are **attested**: the server binds and records them
and does not claim to have validated an upstream approval artifact.

Transaction protocol, in the order actually executed. Two ordering facts are load-bearing.
Content is validated **before any lock is taken**, so a malformed request never queues behind
a held lock. Steps 6 and 7 are the resolution of the lost-response case and must run in this
sequence; recomputing the preparation first would reject a legitimate retry, because the
precondition it covers has legitimately changed from absent to 120.

1. Re-check actor and live manager role.
2. Validate the request against the strict versioned schema: unknown fields are rejected
   recursively; `role` and `targetState` are rejected outright.
3. **Validate content before taking any lock**: parsed envelope (root object,
   `processDataSet`, `common:UUID` equal to `id`, `common:dataSetVersion` equal to `version`,
   duplicate keys absent) and `contentSha256` against the submitted bytes. No row is read and
   no lock is taken until the request itself is well formed.
4. Take advisory locks in a **fixed order across separate advisory namespaces** — identity
   namespace first, then idempotency-key namespace — so a key hash colliding with an
   identity hash can never deadlock.
5. **Actor-and-key lookup, independent of identity.** Look up the immutable receipt for
   `(actor, idempotencyKey)` **without** constraining the identity first. A key already bound
   to a *different* identity is `result_publication_replay_mismatch`, decided **before any
   insert**, so no Process row can be created and then abandoned.
6. **Exact-binding retry.** When that lookup resolves to this identity, compare the full
   request against the stored receipt and the live row — including the original
   `expectedPreparationHash`, every supplied hash and the audit reason — and on exact equality
   return the identical stored receipt with `reused: true`. Nothing is recomputed and the
   current classification is never treated as the original precondition.
7. **Only when no receipt exists for this key**, classify the row from current state and branch
   on it BEFORE recomputing anything:

| Observed state | Outcome |
| --- | --- |
| absent | insert directly at `state_code = 120` (never 0, never 100) |
| 120 without a receipt for this key | `result_publication_conflict` |
| 0 / 20 / 100 / 200 / -1 | `result_publication_conflict`; legacy 100 is never auto-upgraded |

   An existing row therefore conflicts as a conflict, not as a stale preparation. Only for an
   absent row is the fresh preparation computed, and a mismatch against
   `expectedPreparationHash` is then `result_preparation_stale`.
8. Insert the Process row, then the receipt and the audit row, in the same transaction. Row,
   receipt and audit commit or roll back together.

**Retry semantics.** A retry after a lost response must replay the **same frozen request
bytes**. It then resolves at step 6 and returns the identical receipt with `reused: true`, even
though the row is now at 120 and a freshly computed preparation would necessarily differ.
Rebuilding the request after publication instead produces a different preparation hash and is
correctly rejected as `result_publication_replay_mismatch` — that is a caller error, not a
server defect. A competing insert that loses the primary-key uniqueness race is caught and
returned as a typed `result_publication_conflict`; a raw `23505` is never surfaced, and the
loser holds no row and no receipt. Any unexpected failure after a write raises and rolls the
whole transaction back, so partial commit and false success are prohibited. A single-session
suite cannot demonstrate two-session primacy; that is proven separately in the two-client
concurrency harness.

**Semantic invariants that hold under retry and revocation.** The receipt and the audit row
carry the full semantics on every path: actor, identity, content hash and domain, role,
target state, all four attesting hashes, the preparation hash, the idempotency key and the
bounded reason. A retry returns the stored receipt verbatim rather than resynthesizing it,
and a revocation prevents a *new* call without mutating the stored evidence. It does not
delete, rewrite or hide the receipt row: the row and its audit row remain present and
byte-identical, and readback of it is **denied until the live role is restored**, because
readback re-checks `private.lca_release_is_manager()` on every call. No public routine bypasses the manager check: all three entry points re-check
`private.lca_release_is_manager()`, and the receipt table grants no browser or service
write. The implementation never writes request content into error output.

Response:

```json
{ "ok": true, "reused": false, "data": {
    "schemaVersion": "result-process.publication-receipt.v1",
    "receiptId": "<uuid>", "actorUserId": "<uuid>",
    "id": "<uuid>", "version": "NN.NN.NNN",
    "stateCode": 120, "role": "result_process", "targetState": 120,
    "contentSha256": "<64 hex>", "hashDomain": "result-process-content.v1",
    "sourceKind": "manager_attestation",
    "candidateSetHash": "<64 hex>", "sourceManifestHash": "<64 hex>",
    "executablePlanHash": "<64 hex>", "approvalHash": "<64 hex>",
    "preparationHash": "<64 hex>", "idempotencyKey": "<string>",
    "publishedAt": "<timestamptz>", "reason": "<string>" } }
```

## 6. Readback

Readback exists so Release can verify the published content and receipt without any generic
read, which is blocked for 120. It requires the **exact receipt binding** — actor, id,
version and idempotency key — and returns only that identity. It never performs an
arbitrary row lookup and never returns a list or a public surface.

Request:

```json
{ "id": "<uuid>", "version": "NN.NN.NNN", "idempotencyKey": "<string>" }
```

Response adds, to the receipt object above, the exact stored content for independent
verification:

```json
{ "ok": true, "data": {
    "receipt": { "...": "as in section 5" },
    "row": { "stateCode": 120, "contentSha256": "<64 hex>",
             "contentText": "<exact stored UTF-8 JSON text>" },
    "verified": { "rowMatchesReceipt": true, "receiptMatchesRequest": true,
                  "liveManager": true } } }
```

The server re-reads the live row, recomputes `result-process-content.v1` over the stored
bytes, and re-checks the live manager role on every call.

## 7. Errors

Errors reuse the existing repository envelope exactly, as produced by
`api.lcia_result_error` / `api.lcia_scope_closure_error`:

```json
{ "ok": false, "code": "<code>", "status": <integer>, "message": "<human text>" }
```

`status` is a **semantic class carried inside the JSON body**, mirroring the existing
commands. It is not a promise about the HTTP response code: all three RPCs are PostgREST
functions that return this body, and a caller must branch on `ok` and `code`, not on an HTTP
status. Success bodies are `{ "ok": true, "reused": <boolean>, "data": { ... } }`; prepare
and readback return `ok: true` with `data` and no `reused` key.

| Code | `status` | Meaning |
| --- | --- | --- |
| `auth_required` | 401 | no `auth.uid()` |
| `not_data_product_manager` | 403 | live manager role absent or revoked |
| `result_publish_request_invalid` | 400 | schema violation, unknown field, or forbidden field |
| `result_publish_content_invalid` | 400 | envelope/UUID/version/duplicate-key/size invalid |
| `result_content_hash_mismatch` | 400 | `contentSha256` does not match the submitted bytes |
| `result_preparation_stale` | 409 | `expectedPreparationHash` drift on a fresh preparation |
| `result_publication_conflict` | 409 | existing row state or missing receipt conflicts |
| `result_publication_replay_mismatch` | 409 | same actor+key with a different full binding |
| `result_publication_busy` | 409 | retryable: another transaction holds the actor's own row-domain fence |
| `result_publication_not_found` | 404 | readback receipt binding absent |

These are the values the implementation returns.

`result_publication_busy` is narrow and retryable. The governed row fence
`private.dataset_flow_identity_active_fence` takes a **non-blocking** advisory lock on
`dataset-flow-identity-actor:<user_id>` and raises SQLSTATE `55P03` with the exact message
`FLOW_IDENTITY_ACTIVE_SCOPE_ACTOR_FENCE_BUSY` when another transaction currently holds it. That
is contention on the actor's own row domain, not an authorization result and not a defect, so
the command converts **exactly that message** into this typed envelope; the insert
subtransaction has already rolled back at that point, so no Process row, receipt or audit row
survives. Every other `55P03` and every unexpected failure re-raises unchanged, the underlying
fence is neither relaxed nor bypassed, and the server starts **no** retry loop or background
action: the caller decides whether to re-issue the same frozen request. A consumer must treat
this code as retryable and must not treat it as a conflict requiring a new identity.

## 8. Receipt storage

Private, append-only table with a unique identity receipt and a unique
`(actor_user_id, idempotency_key)`. There is deliberately **no** unique constraint on
`(actor, planHash)`, because one release plan legitimately covers multiple Results. ACLs are
minimal: `REVOKE ALL` from `PUBLIC`, `anon` and `authenticated`; no write grant to
`service_role`; writes occur only through the definer command. No caller-settable GUC and no
publicly spoofable setting acts as a bypass.

## 9. Out of scope

No public Result API, no generic read widening, no Next or Portal frontend change, no
display expansion, no Result 100 migration, and no new role. Cross-repository transport
registration, if required outside the database, is owned by the consuming repository.
