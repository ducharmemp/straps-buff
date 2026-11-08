# Design contract

This document describes the adapter's source contracts for implementers and reviewers. Linux runtime suites pass on Neovim 0.11.5 and 0.12.6; non-host runtime acceptance remains outstanding. README.md defines the tool arguments, response shapes, and limits.

## Responsibilities

Buff API v1 owns lifecycle, opaque tab and document identities, page execution, mutation scheduling, reconciliation, and structured completion records. Human operations and adapter operations share Buff's scheduler. straps-buff owns six registry entries, capability declarations, session-scoped tokens, bounded responses, and caller resource retention. The adapter registers the `browser` grantable category through Straps' `fn.capability` extension mechanism.

The flake pins published Buff API v1 revision `45ad0cb763138be7eeb03436bd34f0add7036257` and Straps revision `7396033c8f3b59d0664a030e5cbd6457e77e9ef7` as source inputs. Package checks use those sources directly. The fetch-deps app copies them into ignored `.deps` directories for local tests and records the source paths only after both copies install. Development shells and `.envrc` prepare missing or changed dependencies; matching markers preserve local edits. Preparation failure aborts entry. Dependency sources remain excluded from the plugin package.

## Identity and ordering

The adapter translates opaque Buff identities into tokens scoped to the Straps session buffer. Node operations require tab, document, and node tokens. Buff takes a fresh snapshot and checks document and node identity before acting. Retained snapshot pagination preserves the original browser/tab/document/revision context; it does not refresh or revalidate those identities.

Evaluations consume strictly increasing per-session sequences before submission. The adapter allocates the next sequence when omitted; explicit sequences must exceed the consumed high-water mark. Buff API v1 still receives and validates the allocated sequence. An omitted sequence denotes a new intentional execution, including after success or failure; it does not authorize retries of uncertain execution. `buff_release` preserves the sequence high-water mark until the session buffer is wiped. Neither adapter nor API retries an uncertain evaluation.

Reconciliation belongs to the active operation. It must not queue behind that operation. Independent refreshes and tab-watch invalidations queue or coalesce. Dirty views retain edits and expose stale/blocked/error state. `refresh_view` refuses unsaved edits; `discard_view` permits discarding them through the admitted operation.

## Completion and cancellation

Submission reserves an adapter operation token before awaiting Buff. Each await registers its cancellation callback. Cancelling queued work removes it before dispatch; cancelling dispatched work detaches observation while Buff retains mutation ownership through completion and reconciliation. `buff_inspect` with `kind = "operations"` discovers retained tokens when cancellation prevented delivery of the original response. `kind = "operation"` reads the current record without waiting or dispatching browser work.

Records distinguish state, outcome, effect, completed steps, and view reconciliation. The scheduler retains bounded completion history; an adapter token does not guarantee the underlying record still exists. Session release clears adapter resources and releases owned Buff observations without stopping the browser. Browser replacement changes identity and invalidates old targets. Lifecycle generation events clear adapter browser resources while preserving operation tokens and sequence counters, including in idle sessions. Response-based browser identity comparison remains a fallback for clients without generation support; an old token must never retarget a replacement document.

Unknown effectful execution installs a browser-wide uncertainty barrier. Outcome classification comes from structured errors, including transport timeout and navigation-load deadline after acknowledgement. The barrier rejects non-recovery submissions, including snapshot/view/export submissions; cached inspection remains available. Recovery requires stop completion followed by a replacement start. A start request that keeps the existing browser does not clear uncertainty. A snapshot cannot establish that a timed-out JavaScript promise stopped. Observer cancellation alone does not install a barrier while the underlying operation can complete.

The lifecycle contract requires stop to settle startup once, wait for process exit and profile cleanup, and prevent replacement startup from racing cleanup. The adapter permits stop without a target while Buff is starting; Buff rejects targetless stop outside startup. Cancelling the startup observer does not stop the browser. The caller must submit stop and await cleanup before replacement.

An unexpected backend disconnect advances the lifecycle generation and emits a stopped event. Cached browser resources and observations are invalidated for idle sessions; operation history and evaluation sequences remain. Stopped inspection exposes no live browser, tabs, or views. The lifecycle owner retains the dead controller for physical cleanup, and replacement waits for that cleanup. Cleanup failure retains ownership and rejects replacement; a later start retries cleanup before replacement. Late reconciliation and observation-registration callbacks cannot publish obsolete resources; late subscription cleanup runs once. Historical operation values from another `resource_generation` are omitted by the adapter, reconciliation views are cleared, and `resources_expired = true` is set.

## Permissions

The six tools declare `read`, `exec`, or `browser` as listed in README.md. An exact `buff_operate` grant includes start, stop, close, and discard with no additional prompt or browser ownership restriction; a successful stop or view discard notifies the human. Admission belongs to trusted Straps execution context. Human Buff actions retain confirmation prompts. Direct registry calls bypass admission and cannot establish permission-test coverage.

Setup runs from trusted configuration outside a Straps session after Straps setup. It requires API version 1, warns about unknown option keys, and rejects registry collisions before extending the classifier. It chains `fn.capability` to add `browser` when absent, copies the delegated category array, and preserves delegated tool classification. A preexisting `browser` category leaves the classifier unchanged. Unchanged repeated calls preserve registry versions and exact grants. It does not alter guards or grant permissions. Buff configuration remains separate.

## Output and views

Resource inputs use `target`; former top-level resource fields remain deprecated aliases. `control_kind` and `log_kind` replace the overloaded operate `kind`, which remains a deprecated alias. The adapter rejects combined forms and translates canonical inputs to the unchanged Buff API v1 contract. Generated schema summaries describe both forms.

API-derived responses use a JSON `untrusted` envelope. Paginated responses expose `data.rows`, optional `data.next_offset`, and its alias `data.cursor`. Legacy top-level page fields and named row fields remain available. Result rows contain one text chunk. Compatibility copies count toward the response byte limit; page selection reserves space for those copies. Operation discovery retains the shape documented in README.md. Inspection reads cached data and does not start the browser or evaluate JavaScript. Fresh snapshots, observations, and human views require admitted operations.

Snapshot and tab/view list pagination index retained rows. Evaluation pagination indexes UTF-8-safe byte chunks of a retained JSON representation. Event pagination uses sequence numbers in a changing retained history, with dropped-event and gap metadata. These cursor types are not interchangeable. Tokens expire after ten minutes from creation or earlier capacity eviction, except observation handles, which remain until disposal, release, or browser generation change. Reads do not renew tokens. Session/global budgets account retained values and fixed-size identity charges; they do not bound all browser or Neovim memory.

Adapter snapshot retention overflow and individual oversized rows raise errors. Buff replaces snapshots over its own 1 MiB bound with empty rows and truncation metadata. Adapter snapshot pages preserve `truncated`, `limit`, and the original `bytes` count on first and retained reads, so callers can distinguish a truncated page from an empty document. Oversized evaluation results retain a UTF-8-safe 256 KiB prefix and report truncation. Tabs/views retain copies with UTF-8-safe string shortening and per-field truncation metadata. They share a four-list cap with a 1 MiB per-list bound. New list allocations preflight the caller's reclaimable lists before oldest-first eviction for count or byte pressure; rejected allocations preserve existing continuations. List eviction leaves independent identity handles intact. `list_page` reads the retained rows and translates identities without refreshing browser state.

Human views use Buff's separate browser window and `browser://` buffers. Export creates a new file with mode `0600` and refuses overwrite. Partial writes can leave partial files and report their effect and byte count. Page text, results, and logs remain untrusted data, including text that resembles instructions. Logs may contain secrets; no complete redaction guarantee exists.

## Acceptance and parked items

Acceptance requires capability coverage, model-origin permission decisions, scoped grants, read-only children, existing guards, unchanged setup, shared sessions, stale identities, dirty buffers, disconnect, startup cancellation, reconciliation, and unknown outcomes. Real sandboxed Chromium tests must assert browser effects. Every new assertion requires a counterfactual failure check, restoration, and a full per-file suite run on both Neovim inputs. CONTRIBUTING.md records the commands and observed Linux results separately.

macOS and non-host architectures require runtime acceptance on additional machines. Unsupported browser capabilities remain outside scope as listed in README.md.
