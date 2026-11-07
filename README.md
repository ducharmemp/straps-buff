# straps-buff

straps-buff exposes Buff through six Straps tools. Buff owns the browser and editable `browser://` buffers; Straps owns tool admission. The local adapter and Buff API prerequisite pass the Linux suites on Neovim 0.11.5 and 0.12.6, including sandboxed Chromium. Non-host runtime acceptance remains outstanding. Development dependencies use pinned upstream sources.

## Installation

- Neovim 0.11 or 0.12 with LuaJIT.
- [Straps](https://github.com/ducharmemp/straps) revision `7396033c8f3b59d0664a030e5cbd6457e77e9ef7`.
- [Buff](https://github.com/ducharmemp/buff.nvim) revision `45ad0cb763138be7eeb03436bd34f0add7036257`, providing API v1.
- Chromium or Chrome with its sandbox enabled. Linux development shells provide Chromium. On macOS, install Chrome separately and set `BUFF_CHROME` to its executable path; macOS runtime acceptance is pending.

Install Buff, Straps, and straps-buff as separate plugins on Neovim's runtimepath. The Nix package contains only straps-buff; `.deps` is excluded. Configure Buff separately, then call from trusted Neovim configuration, outside a Straps session:

```lua
require("straps-buff").setup()
```

`setup()` also accepts an empty table; it rejects other options. It checks for Buff API version 1 and the Straps registry. Repeating unchanged setup preserves registry entries and grants; a conflicting tool definition raises an error. Setup neither grants permissions nor replaces guards.

### Nixvim

Import the flake module into your Nixvim configuration:

```nix
{
  imports = [ inputs.straps-buff.nixvimModules.default ];
  plugins.straps-buff.enable = true;
  plugins.buff.settings.headless = false;
}
```

The module assumes Straps is already installed and configured by your Nixvim configuration. It imports and enables the pinned Buff module, installs Buff and the adapter, and calls adapter setup after normal-priority dependency setup. It does not install, enable, or configure Straps. Buff settings remain configurable through `plugins.buff.settings`. `plugins.straps-buff.package` overrides the adapter package. Explicitly disabling Buff while enabling the adapter fails a configuration assertion. Linux adds Chromium to the runtime packages; macOS requires an installed Chrome executable configured through `plugins.buff.settings.chrome`. Avoid importing another copy of the Buff module; keep your existing Straps module import and configuration.

For development, enable the host direnv shell hook and run `direnv allow` from this checkout. `.envrc` enters the default Nix shell and prepares pinned dependencies. Both `nix develop` shells also prepare dependencies; unchanged pins preserve local edits. See CONTRIBUTING.md for setup and manual refresh.

## Admission and shared browser

| Tool | Capability | Scope |
| --- | --- | --- |
| `buff_inspect` | `read` | Cached status, tabs, views, snapshots, operation records, results, and logs |
| `buff_operate` | `exec` | Lifecycle, tabs, controls, snapshots, refresh, discard, and log observation |
| `buff_evaluate` | `exec` | Arbitrary page JavaScript |
| `buff_view` | `exec` | Human browser buffers, contextual help, and view navigation |
| `buff_export` | `edit` | Exclusive log export, mode `0600`, refusing overwrite |
| `buff_release` | `read` | Release caller resources without stopping the browser |

An exact `buff_operate` grant includes start, stop, tab close, and unsaved-buffer discard without secondary prompts or ownership restrictions. Admission comes from trusted Straps execution context, never a model argument. Human Buff operations retain their prompts, and existing Straps guards remain active. The browser is shared across sessions: an admitted stop affects other users of that browser.

Inspection reads caches; it does not start a browser, request a fresh snapshot, or evaluate JavaScript. Use an admitted operation to obtain fresh browser data. Page text, evaluation results, and logs are untrusted and may contain secrets; no complete redaction guarantee exists.

## Tool arguments

All inputs are objects. Unknown properties are rejected. Tokens are opaque strings belonging to the calling Straps session; obtain them from responses rather than constructing them. A token field accepts 1–128 bytes. Unless stated otherwise, string arguments accept 1–65536 bytes. Scalar text/select control values accept 0–65536 bytes.

### `buff_inspect`

| `kind` | Other fields | Result |
| --- | --- | --- |
| `status` | None | API version, lifecycle state, browser token, uncertainty, scheduler state |
| `tabs` | None | First retained page of cached tab entries, browser token, and list revision |
| `views` | None | First retained page of view tokens, tab tokens, kind, buffer number, modified/stale/blocked/error state |
| `list_page` | Required `token`; optional `offset`, `limit` | Retained tab/view list rows |
| `operations` | None | Caller-retained operation tokens and `expires_after_seconds` |
| `operation` | Required `operation` token | Current operation record |
| `snapshot` | Required `tab` token | Cached snapshot's first page; envelope omits `data` when absent |
| `page` | Required `snapshot` token; optional `offset`, `limit` | Retained snapshot rows |
| `events` | Required `observation` token; optional `offset`, `limit` | Retained observed events and loss metadata |
| `result` | Required `result` token; optional `offset`, `limit` | Chunk of retained JSON-encoded evaluation result |

`tabs` and `views` retain a bounded copy of the cached list. Their first page uses `tabs` or `views` for its rows and includes `kind`, `token`, `offset`, `total`, `revision`, optional `browser`, and optional `next_offset`. Request subsequent pages with `kind = "list_page"`, the returned `token`, and `offset = next_offset`; these responses use `rows` and have no `data` wrapper. Offsets are one-based row positions; limits are 1–200 rows, default 200. The retained list and revision stay unchanged across pages. String fields whose JSON encoding exceeds 8192 bytes are shortened at UTF-8 boundaries; row `truncation` entries report `field`, `original_bytes`, and `retained_bytes`.
`page` offsets are one-based row positions, default 1; limits are 1–200 rows, default 200. A page includes `token`, `offset`, `total`, `rows`, `browser`, `tab`, `document`, `revision`, and, when more rows remain, `next_offset`. Pass the returned `token` as the next request's `snapshot`. Retained pages refer to the same snapshot, even after a later browser refresh; they do not establish that its node tokens remain actionable.

`events` offsets are inclusive event sequence numbers, default 1; limits are 1–200 events, default 200. Responses include `events`, `dropped`, `gap`, `revision`, and an optional `next_offset`, plus browser/tab/observation context. `gap` means the requested offset precedes the oldest retained event. Events arrive and expire between requests, so log pagination is not a frozen snapshot. An event too large for a response raises an error; export logs instead.

`result` offsets are one-based byte positions, default 1; limits are 1–60000 bytes, default 8000. Responses contain `result`, `text`, `total_bytes`, and optional `next_offset`. Concatenate `text` chunks before decoding the result JSON. UTF-8 characters are not split; an offset inside a character or a limit too small for one character raises an error. JSON escaping can reduce the returned chunk below the requested limit.

### `buff_operate`

Every request requires `action`. In the table, target fields occur inside `target = { ... }`. A tab target permits an optional browser token; a node target requires tab, document, and node tokens and permits a browser token. View targets require a view token and permit a browser token.

| `action` | Fields |
| --- | --- |
| `start` | Optional `options = { headless = boolean }` |
| `stop` | Target with `browser` required except during startup, when target may be omitted |
| `new_tab` | Required target with `browser`; required `url` |
| `navigate` | Required tab target; required `url` |
| `close_tab`, `snapshot` | Required tab target |
| `activate`, `follow` | Required node target |
| `set_control` | Required node target, `kind`, `value` |
| `refresh_view`, `discard_view` | Required view target |
| `observe` | Required tab target; `kind = "console"` or `"network"` |
| `unobserve` | Required `observation` token |

For `set_control`, `kind = "text"` takes a string of 0–65536 bytes, `checkbox` takes a boolean, and `select` takes a string of 0–65536 bytes or an array of at most 200 nonempty strings. Buff checks whether the target control supports editing. `refresh_view` rejects unsaved edits; `discard_view` authorizes discarding them. `observe` returns an observation token for subsequent cached event retrieval or export.

### Other tools

`buff_evaluate` requires `target = { tab = token, browser = optional_token }`, `sequence`, and nonempty `source` up to 64 KiB. `sequence` must be an integer from 1 to 9007199254740991, greater than every sequence previously consumed by the session. It is consumed before submission, including submissions that fail. Every intentional repeat after success or error needs a new sequence. Resource release does not reset the session sequence. No automatic retry occurs.

`buff_view` requires `kind = "tabs" | "page" | "eval" | "console" | "network"` and `command = "open" | "help" | "next" | "previous"`. `open` requires a target tab except for `tabs`; other commands require a target view. Its target object permits browser, tab, document, node, and view token fields. These operations change the human's editor view and may request browser data.

`buff_export` requires `path` and either `observation` or `target = { view = token, browser = optional_token }`. Only console/network views are exportable. Paths resolve in Neovim's working directory unless absolute. Export creates a new file with mode `0600` and refuses existing files. A failed partial write can leave a partial file; inspect the operation's effect and byte count before recovery.

`buff_release` takes `{}` and returns `{ "released": true }`. It removes the caller's handles and retained snapshots/results, releases log subscriptions, cancels queued owned operations, and detaches from running work. It never stops the browser. Wiping the Straps session buffer also releases resources.

## Responses and recovery

Tools return JSON strings. API-derived data uses `{ "untrusted": true, "data": ... }`. Retained `page`, `list_page`, and `result` requests return their page object without the `data` wrapper; `operations` returns `{ "operations": [...], "expires_after_seconds": 600 }`.

Retained Buff operation records contain an `id` token, `serial`, `action`, `state`, `effect`, and `completed_steps`. Completion can add `outcome`, `value`, `error`, and `reconciliation`. Record states are `queued`, `running`, or `completed`; outcomes include `succeeded`, `failed`, `cancelled`, `rejected`, and `unknown`. Inspect `effect` and per-view reconciliation state rather than treating successful dispatch as proof of the intended page outcome. Evaluation completion replaces `value` with `{ "result": token, "bytes": n }`; a result over 256 KiB instead reports `truncated`, its byte count, and an error without retaining the result.

Adapter submission responses can differ from retained records. Cancellation after submission returns `id`, `action`, `state = "observer_detached"`, `outcome = "unresolved"`, `effect = "unresolved"`, and `observer_detached = true`; inspect the retained operation for its eventual completion. Cancellation before submission returns only `{ "outcome": "cancelled" }` inside the data envelope. If response conversion fails after dispatch, the adapter returns available identity and operation fields plus `response_error` and `recovery`, and may omit `serial` or `completed_steps`. The operation may have taken effect; free capacity and inspect its record rather than retrying it.

Cancellation before dispatch removes queued work. Cancellation after dispatch detaches the observer while Buff completes execution and reconciliation; cancellation does not undo effects. If cancellation prevents receipt of an operation id, call `buff_inspect` with `kind = "operations"`, then inspect the returned operation tokens. Tokens can expire before their Buff records, and Buff history can expire before adapter tokens.

For an `unknown` outcome, inspect cached status and operation records. Do not repeat uncertain JavaScript or assume a fresh snapshot proves a timed-out promise stopped. Buff's uncertainty barrier rejects further non-recovery submissions. Stop the browser using its browser token, await confirmed completion, then start a replacement and obtain new tokens. Calling start on the existing browser does not establish replacement. Browser replacement invalidates old identities; cached inspection discovers new browser/tab tokens. During startup, stop may omit its target because no browser token may exist yet. Cancelling the startup observer leaves startup running; submit stop and await completion before starting a replacement. Buff rejects targetless stop outside startup.

An unexpected backend disconnect advances the generation and invalidates browser resources, including observations in idle sessions. Operation history and evaluation sequence counters remain. Cached stopped status omits the browser token; tabs/views are empty. Replacement waits for process/profile cleanup. Cleanup failure retains ownership and rejects replacement. A later start retries cleanup and starts a replacement only after cleanup succeeds. Historical responses whose `resource_generation` differs from the current generation omit `value`, clear `reconciliation.views`, and include `resources_expired = true`, preventing historical resources from becoming live tokens again.

## Bounds and release limitations

- Responses: 64 KiB after JSON encoding. A snapshot row larger than a page raises an error.
- Retained snapshots: at most four, each at most 1 MiB. Adapter retention overflow raises an error. Buff replaces snapshots over its own 1 MiB bound with empty rows and `truncated = true`; adapter snapshot pages preserve `truncated`, `limit`, and the original `bytes` count on initial and retained reads. An empty truncated page does not establish an empty document.
- Evaluation source: 64 KiB; retained result: 256 KiB; at most 128 retained results and 128 operation tokens per session.
- Identity handles: 4096 per session. Tokens expire 600 seconds after creation; reads do not renew them. Capacity eviction can expire them sooner. Observation handles remain until unsubscribe/disposal, release, or browser generation change.
- Accounted adapter retention: 16 MiB per session and 64 MiB globally; these are accounting budgets, not process memory limits. Identity handles count as 128 bytes each.
- Adapter event output retains at most 2000 events and 2 MiB before pagination. Buff's API applies its own lower log byte bound and can drop events before the adapter sees them; inspect `dropped` and `gap`.

Tabs and views share at most four retained lists, each at most 1 MiB after field shortening. New lists evict the caller's oldest lists when the count or byte budgets require it. A rejected list allocation preserves existing continuations. List eviction does not remove identity handles obtained from its pages. An oversized list or a row that cannot fit in one response raises an error. Expired list tokens require a new tabs/views inspection; expired identity handles require cached rediscovery or a new admitted snapshot/observation. Use `buff_release` when unrelated retained resources exhaust budgets, then obtain new tokens; release also removes operation discovery records.

Screenshots, remote attachment, persistent profiles, additional browsers, cross-origin frame controls, password entry, and trusted keyboard input remain outside Buff's supported contract. See [DESIGN.md](DESIGN.md) for the implementation boundary and [CONTRIBUTING.md](CONTRIBUTING.md) for verification commands. The contracts above have Linux runtime coverage recorded in CONTRIBUTING.md; non-host acceptance remains unverified.
