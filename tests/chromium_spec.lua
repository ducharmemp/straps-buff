require("straps").setup({})
local registry = require("straps.registry")
local session_buffer
local sequence = 0
local checks = {}
local exports = {}
local inflight = {}
local restorations = {}
local transports = {}
local session_buffers = {}
local deliveries = {}

local function hold_callback(holder, callback, ...)
  local values, delivered = { ... }, false
  holder.deliver = function()
    if delivered then return end
    delivered = true
    callback(unpack(values))
  end
  deliveries[#deliveries + 1] = holder
end

local function wrap(owner, name, replacement)
  local original = owner[name]
  owner[name] = replacement(original)
  restorations[#restorations + 1] = function() owner[name] = original end
end

local function capture_transport(hold_version)
  wrap(require("buff.transport"), "start", function(original)
    return function(...)
      local options = ...
      local transport, err = original(...)
      if transport then
        transport.test_options = options
        transports[#transports + 1] = transport
        if hold_version then
          wrap(transport, "request", function(request)
            return function(self, method, params, session, callback, effect)
              return request(self, method, params, session, function(...)
                if method == "Browser.getVersion" then
                  hold_callback(hold_version, callback, ...)
                else callback(...) end
              end, effect)
            end
          end)
        end
      end
      return transport, err
    end
  end)
end

local function check(name, condition)
  checks[#checks + 1] = name
  if vim.env.BUFF_CHECK_LIST == "1" then print("CHECK " .. name) end
  if vim.env.BUFF_COUNTERFACTUAL == name then condition = not condition end
  assert(condition, "CHECK " .. name)
end

local function begin_invoke(name, input)
  local finished, succeeded, result = false, nil, nil
  local cancelled = false
  local call = {}
  inflight[#inflight + 1] = call
  local cancellations = {}
  local thread
  local function resume(...)
    local ok, value = coroutine.resume(thread, ...)
    if not ok then finished, succeeded, result = true, false, value end
  end
  local context = {
    bufnr = session_buffer,
    cancelled = function() return cancelled end,
    on_cancel = function(fn) cancellations[#cancellations + 1] = fn end,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local values = { ... }
        vim.schedule(function() resume(unpack(values)) end)
      end)
      local value = coroutine.yield()
      cancellations = {}
      return value
    end,
  }
  thread = coroutine.create(function()
    succeeded, result = pcall(registry.call, "tool." .. name, input, context)
    finished = true
  end)
  call.cancel = function()
    cancelled = true
    for _, cancel in ipairs(cancellations) do pcall(cancel) end
  end
  call.finished = function() return finished end
  call.wait = function()
    if not vim.wait(30000, function() return finished end, 5) then
      call.cancel()
      error("tool deadline: " .. name)
    end
    if not succeeded then error(result) end
    return vim.json.decode(result)
  end
  resume()
  return call
end

local function invoke(name, input)
  return begin_invoke(name, input).wait()
end

local function inspect(input)
  local value = invoke("buff_inspect", input)
  return value.data or value
end

local function operate(action, fields)
  local result = invoke("buff_operate", vim.tbl_extend("force", { action = action }, fields or {})).data
  if result.outcome ~= "succeeded" then error(action .. ": " .. vim.inspect(result)) end
  return result
end

local function evaluate(target, source)
  sequence = sequence + 1
  local result = invoke("buff_evaluate", { target = target, source = source, sequence = sequence }).data
  if result.outcome ~= "succeeded" then error("evaluate: " .. vim.inspect(result)) end
  return vim.json.decode(inspect({ kind = "result", result = result.value.result }).text)
end

local function fixture(name)
  return vim.uri_from_fname(vim.fn.getcwd() .. "/tests/fixtures/" .. name)
end

local function cleanup()
  for _, call in ipairs(inflight) do if not call.finished() then call.cancel() end end
  inflight = {}
  for index = #restorations, 1, -1 do pcall(restorations[index]) end
  restorations = {}
  for _, holder in ipairs(deliveries) do pcall(holder.deliver) end
  deliveries = {}
  for _, transport in ipairs(transports) do pcall(transport.stop, transport, function() end) end
  local captured = #transports > 0
  local cleaned = vim.wait(10000, function()
    for _, transport in ipairs(transports) do
      if vim.uv.kill(transport.pid, 0) or vim.fn.isdirectory(transport.profile) == 1 then return false end
    end
    return true
  end, 10)
  local session = require("buff").controller()
  if session then
    local stopped = false
    require("buff")._stop(function() stopped = true end)
    cleaned = vim.wait(10000, function() return stopped end, 10) and cleaned
  end
  transports = {}
  for _, buf in ipairs(session_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  session_buffers = {}
  for _, path in ipairs(exports) do vim.fn.delete(path) end
  exports = {}
  if session_buffer and vim.api.nvim_buf_is_valid(session_buffer) then
    local ok, status = pcall(inspect, { kind = "status" })
    if ok and status.browser then pcall(operate, "stop", { target = { browser = status.browser } }) end
    pcall(invoke, "buff_release", {})
    vim.api.nvim_buf_delete(session_buffer, { force = true })
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):match("^browser://") then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  if captured then check("failure-test-cleanup", cleaned) end
end

local function setup_failure_test(timeout)
  require("buff").setup({ chrome = vim.env.BUFF_CHROME, headless = true, timeout = timeout or 10000 })
  require("straps-buff").setup()
  session_buffer = vim.api.nvim_create_buf(false, true)
  session_buffers[#session_buffers + 1] = session_buffer
  sequence = 0
end

local function start_page()
  local browser = operate("start", { options = { headless = true } }).value.browser
  local tab = operate("new_tab", { target = { browser = browser }, url = fixture("index.html") }).value.tab
  return { browser = browser, tab = tab }
end

local function stopped_transport(transport)
  return vim.wait(10000, function()
    return not vim.uv.kill(transport.pid, 0) and vim.fn.isdirectory(transport.profile) == 0
  end, 10)
end

local function backend_read(id, source)
  local finished, failure, value = false, nil, nil
  require("buff").controller().backend.evaluate(id, source, function(err, result)
    failure, value, finished = err, result, true
  end)
  assert(vim.wait(10000, function() return finished end, 5), "backend read deadline")
  assert(not failure, failure)
  return value
end

describe("registered tools with real Chromium", function()
  after_each(cleanup)
  it("cancels startup observation and performs targetless cleanup before replacement", function()
    setup_failure_test()
    local held = {}
    capture_transport(held)
    local straps = require("straps").setup({})
    local directory = vim.fn.tempname()
    local previous_directory, previous_backstop = straps.config.session_dir, straps.config.stop_backstop_ms
    straps.config.session_dir, straps.config.stop_backstop_ms = directory, 60000
    restorations[#restorations + 1] = function()
      straps.config.session_dir, straps.config.stop_backstop_ms = previous_directory, previous_backstop
      vim.fn.delete(directory, "rf")
    end
    local state, loop = require("straps.state"), require("straps.loop")
    vim.api.nvim_buf_delete(session_buffer, { force = true })
    session_buffer = state.new_session()
    session_buffers[#session_buffers + 1] = session_buffer
    state.append_text(session_buffer, "Start the test browser")
    registry.define({ name = "fn.provider", kind = "fn", source = [[
return function()
  return { stop_reason = "tool_use", content = { { type = "tool_use", id = "browser-start", name = "buff_operate",
    input = { action = "start", options = { headless = true } } } } }
end
]] }, { scope = session_buffer })
    registry.grant(session_buffer, registry.tool_grant_key("buff_operate"))
    restorations[#restorations + 1] = function() if loop.running(session_buffer) then loop.stop(session_buffer) end end
    loop.start(session_buffer)
    assert(vim.wait(10000, function() return held.deliver ~= nil end, 5), "startup version response deadline")
    local transport = transports[#transports]
    check("startup-real-process", vim.uv.kill(transport.pid, 0) == 0 and vim.fn.isdirectory(transport.profile) == 1)
    loop.stop(session_buffer)
    check("startup-model-loop-cancelled", vim.wait(2000, function() return not loop.running(session_buffer) end, 5))
    local transcript = table.concat(vim.api.nvim_buf_get_lines(session_buffer, 0, -1, false), "\n")
    check("startup-cancel-detaches", transcript:find("observer_detached", 1, true) ~= nil and transcript:find("unresolved", 1, true) ~= nil)
    local operations = inspect({ kind = "operations" }).operations
    check("startup-operation-discoverable", #operations == 1)
    local detached = { id = operations[1] }
    check("startup-cancel-keeps-starting", inspect({ kind = "status" }).state == "starting")
    local stop = invoke("buff_operate", { action = "stop" }).data
    check("startup-targetless-stop", stop.outcome == "succeeded" and inspect({ kind = "status" }).state == "stopped")
    check("startup-stop-removes-process-profile", stopped_transport(transport))
    held.deliver()
    local record = inspect({ kind = "operation", operation = detached.id })
    check("startup-retained-failure", record.state == "completed" and record.outcome == "failed")
    for index = #restorations, 1, -1 do restorations[index]() end
    restorations = {}
    local replacement = operate("start", { options = { headless = true } }).value
    check("startup-replacement-running", replacement.state == "running" and type(replacement.browser) == "string")
    operate("stop", { target = { browser = replacement.browser } })
  end)

  it("invalidates a disconnected real browser and replaces its process", function()
    setup_failure_test()
    capture_transport()
    local target = start_page()
    local absent = invoke("buff_inspect", { kind = "snapshot", tab = target.tab })
    check("disconnect-uncached-snapshot-omits-data", absent.untrusted == true and absent.data == nil)
    local transport = transports[#transports]
    local snapshot = operate("snapshot", { target = target }).value
    check("disconnect-document-resolves-before-kill", inspect({ kind = "page", snapshot = snapshot.token }).token == snapshot.token)
    local first = session_buffer
    local s = require("straps-buff.session").get(first, require("buff.api"))
    local generation = s.client:generation()
    sequence = sequence + 1
    local evaluation = invoke("buff_evaluate", { target = target, sequence = sequence, source = "17" }).data
    local result = evaluation.value.result
    session_buffer = vim.api.nvim_create_buf(false, true)
    session_buffers[#session_buffers + 1] = session_buffer
    local idle = require("straps-buff.session").get(session_buffer, require("buff.api"))
    local idle_browser = inspect({ kind = "status" }).browser
    local listed = inspect({ kind = "tabs" })
    local idle_tab
    for _, tab in ipairs(listed.tabs) do if tab.url == fixture("index.html") then idle_tab = tab.tab end end
    local observation = operate("observe", { target = { browser = idle_browser, tab = idle_tab }, kind = "console" }).value.observation
    check("disconnect-idle-observation-live", inspect({ kind = "events", observation = observation }).observation == observation)
    session_buffer = first
    assert(vim.uv.kill(transport.pid, "sigkill") == 0)
    check("disconnect-process-profile-removed", stopped_transport(transport))
    check("disconnect-status-stopped", vim.wait(10000, function() return inspect({ kind = "status" }).state == "stopped" end, 5))
    check("disconnect-generation-advances", s.client:generation() > generation)
    local idle_resources, idle_bytes, idle_handles = false, 0, 0
    for _, item in pairs(idle.items) do
      if item.kind ~= "operation" then idle_resources = true end
      idle_bytes = idle_bytes + item.bytes
      if item.identity then idle_handles = idle_handles + 1 end
    end
    check("disconnect-idle-resources-released", not idle_resources and idle.bytes == idle_bytes and idle.handle_count == idle_handles)
    local idle_reverse_resources = false
    for _, token in pairs(idle.reverse) do
      if not idle.items[token] or idle.items[token].kind ~= "operation" then idle_reverse_resources = true end
    end
    check("disconnect-idle-reverse-resources-released", not idle_reverse_resources and idle.items[observation] == nil and idle.items[listed.token] == nil)
    check("disconnect-no-live-browser", inspect({ kind = "status" }).browser == nil)
    check("disconnect-no-live-tabs", #inspect({ kind = "tabs" }).tabs == 0)
    check("disconnect-no-live-views", #inspect({ kind = "views" }).views == 0)
    check("disconnect-old-browser-invalid", not pcall(invoke, "buff_operate", { action = "snapshot", target = target }))
    check("disconnect-old-document-invalid", not pcall(inspect, { kind = "page", snapshot = snapshot.token }))
    check("disconnect-old-result-invalid", not pcall(inspect, { kind = "result", result = result }))
    check("disconnect-sequence-preserved", not pcall(s.sequence, s, 1))
    local record = inspect({ kind = "operation", operation = evaluation.id })
    check("disconnect-operation-history-preserved", record.state == "completed" and record.outcome == "succeeded")
    local identities = false
    for _, item in pairs(s.items) do if item.identity and item.kind ~= "operation" then identities = true end end
    check("disconnect-history-no-live-identities", not identities)
    local replacement = start_page()
    check("disconnect-old-target-invalid-after-replacement", not pcall(invoke, "buff_operate", { action = "snapshot", target = target }))
    check("disconnect-replacement-token", replacement.browser ~= target.browser)
    check("disconnect-replacement-executes", evaluate(replacement, "document.title") == "Adapter fixture")
  end)

  it("preserves oversized snapshot truncation metadata from real Chromium", function()
    setup_failure_test()
    capture_transport()
    local target = start_page()
    evaluate(target, [[document.body.innerHTML = '<main>' + Array.from({length: 6000}, (_, i) => '<p>' + i + ' ' + 'x'.repeat(220) + '</p>').join('') + '</main>'; true]])
    local snapshot = operate("snapshot", { target = target }).value
    check("oversized-snapshot-truncated", snapshot.truncated == true)
    check("oversized-snapshot-original-bytes", type(snapshot.bytes) == "number" and snapshot.bytes > 1048576)
    check("oversized-snapshot-limit", snapshot.limit == 1048576)
    check("oversized-snapshot-empty-rows", #snapshot.rows == 0 and snapshot.total == 0)
    local cached = inspect({ kind = "snapshot", tab = target.tab })
    check("oversized-snapshot-cached-metadata", cached.truncated == true and cached.bytes == snapshot.bytes and cached.limit == snapshot.limit)
    local retained = inspect({ kind = "page", snapshot = snapshot.token })
    check("oversized-snapshot-retained-metadata", retained.truncated == true and retained.bytes == snapshot.bytes and retained.limit == snapshot.limit)
  end)

  it("retains a real evaluation timeout and blocks retries until stop start recovery", function()
    setup_failure_test()
    capture_transport()
    local target = start_page()
    transports[#transports].test_options.timeout = 500
    local backend = require("buff").controller().backend
    local tabs, listed
    backend.list_tabs(function(err, value) assert(not err, err); tabs, listed = value, true end)
    assert(vim.wait(10000, function() return listed end, 5))
    local id
    for _, tab in ipairs(tabs) do if tab.url == fixture("index.html") then id = tab.id end end
    assert(id, "fixture target missing")
    sequence = sequence + 1
    local unknown = invoke("buff_evaluate", { target = target, sequence = sequence,
      source = "window.timeoutCount = (window.timeoutCount || 0) + 1; new Promise(() => {})" }).data
    check("timeout-unknown-outcome", unknown.outcome == "unknown" and unknown.effect == "unknown")
    check("timeout-real-deadline", unknown.error.message:find("CDP deadline exceeded: Runtime.evaluate", 1, true) ~= nil)
    check("timeout-observable-effect", backend_read(id, "window.timeoutCount") == 1)
    local record = inspect({ kind = "operation", operation = unknown.id })
    check("timeout-retained-unknown", record.state == "completed" and record.outcome == "unknown")
    check("timeout-status-barrier", inspect({ kind = "status" }).uncertainty ~= nil)
    sequence = sequence + 1
    local rejected = invoke("buff_evaluate", { target = target, sequence = sequence, source = "window.timeoutCount += 1" }).data
    check("timeout-retry-rejected", rejected.outcome == "rejected" and rejected.error.code == "uncertain_browser")
    check("timeout-retry-no-effect", backend_read(id, "window.timeoutCount") == 1)
    local transport = transports[#transports]
    operate("stop", { target = { browser = target.browser } })
    check("timeout-stop-process-profile-removed", stopped_transport(transport))
    local replacement = start_page()
    check("timeout-recovery-new-browser", replacement.browser ~= target.browser and inspect({ kind = "status" }).uncertainty == nil)
    check("timeout-recovery-executes", evaluate(replacement, "window.recovered = 7") == 7)
  end)

  it("invalidates another session resources when the shared browser stops", function()
    setup_failure_test()
    capture_transport()
    local target = start_page()
    local first = session_buffer
    session_buffer = vim.api.nvim_create_buf(false, true)
    session_buffers[#session_buffers + 1] = session_buffer
    local second_status = inspect({ kind = "status" })
    local second_tab
    for _, tab in ipairs(inspect({ kind = "tabs" }).tabs) do if tab.url == fixture("index.html") then second_tab = tab.tab end end
    assert(second_tab, "shared fixture tab missing")
    local second_target = { browser = second_status.browser, tab = second_tab }
    local snapshot = operate("snapshot", { target = second_target }).value
    check("shared-stop-document-resolves-before-stop", inspect({ kind = "page", snapshot = snapshot.token }).token == snapshot.token)
    local observation = operate("observe", { target = second_target, kind = "console" }).value.observation
    check("shared-stop-observation-resolves-before-stop", inspect({ kind = "events", observation = observation }).observation == observation)
    local second = session_buffer
    session_buffer = first
    operate("stop", { target = { browser = target.browser } })
    session_buffer = second
    check("shared-stop-status", inspect({ kind = "status" }).state == "stopped")
    check("shared-stop-target-invalid", not pcall(invoke, "buff_operate", { action = "snapshot", target = second_target }))
    check("shared-stop-snapshot-invalid", not pcall(inspect, { kind = "page", snapshot = snapshot.token }))
    check("shared-stop-observation-invalid", not pcall(inspect, { kind = "events", observation = observation }))
    local replacement = start_page()
    check("shared-stop-replacement-executes", evaluate(replacement, "document.title") == "Adapter fixture")
    session_buffer = first
  end)

  it("detaches during real reconciliation and retains the completed page effect", function()
    setup_failure_test()
    capture_transport()
    local target = start_page()
    local held = {}
    local backend = require("buff").controller().backend
    wrap(backend, "list_tabs", function(original)
      return function(callback)
        original(function(...)
          hold_callback(held, callback, ...)
        end)
      end
    end)
    sequence = sequence + 1
    local evaluation = begin_invoke("buff_evaluate", { target = target, sequence = sequence,
      source = "window.reconciliationCount = (window.reconciliationCount || 0) + 1" })
    assert(vim.wait(10000, function() return held.deliver ~= nil end, 5), "reconciliation response deadline")
    check("reconciliation-pending", not evaluation.finished())
    evaluation.cancel()
    local detached = evaluation.wait().data
    check("reconciliation-cancel-detaches", detached.state == "observer_detached" and detached.outcome == "unresolved")
    local pending = inspect({ kind = "operation", operation = detached.id })
    check("reconciliation-retained-running", pending.state == "running")
    restorations[#restorations]()
    table.remove(restorations)
    held.deliver()
    local completed
    assert(vim.wait(10000, function()
      completed = inspect({ kind = "operation", operation = detached.id })
      return completed.state == "completed"
    end, 5), "reconciliation completion deadline")
    check("reconciliation-retained-success", completed.outcome == "succeeded" and completed.effect == "completed")
    check("reconciliation-effect-once", evaluate(target, "window.reconciliationCount") == 1)
  end)
  it("runs local browser operations and exposes their observable results", function()
    require("buff").setup({ chrome = vim.env.BUFF_CHROME, headless = true, timeout = 10000 })
    require("straps-buff").setup()
    session_buffer = vim.api.nvim_create_buf(false, true)
    sequence = 0
    local before = inspect({ kind = "status" })
    check("cached-inspection-does-not-start", before.state == "stopped" and before.browser == nil)
    check("dependency-version", before.version == 1)
    local status = operate("start", { options = { headless = true } }).value
    check("start-browser-token", type(status.browser) == "string")
    local browser = { browser = status.browser }
    local tab = operate("new_tab", { target = browser, url = fixture("index.html") }).value.tab
    local target = { browser = status.browser, tab = tab }
    check("new-tab-token", type(tab) == "string")
    local listed = false
    for _, entry in ipairs(inspect({ kind = "tabs" }).tabs) do
      if entry.tab == tab and entry.url == fixture("index.html") then listed = true end
    end
    check("tab-list-local-url", listed)
    local snapshot = operate("snapshot", { target = target }).value
    local rows = {}
    for _, row in ipairs(snapshot.rows) do
      if row.kind or row.role == "button" or row.role == "link" then rows[row.name] = row end
    end
    local heading = false
    for _, row in ipairs(snapshot.rows) do
      if row.name == "Adapter fixture" and row.role == "heading" then heading = true end
    end
    check("snapshot-heading", heading)
    local function node(name)
      return { browser = status.browser, tab = tab, document = snapshot.document, node = rows[name].node }
    end
    check("snapshot-text", rows.Name.kind == "text" and rows.Name.value == "old")
    check("snapshot-checkbox", rows.Enabled.kind == "checkbox" and rows.Enabled.checked == false)
    check("snapshot-select", rows.Choice.kind == "select")
    local console = operate("observe", { target = target, kind = "console" }).value.observation
    local network = operate("observe", { target = target, kind = "network" }).value.observation
    operate("set_control", { target = node("Name"), kind = "text", value = "edited" })
    check("text-control-effect", evaluate(target, "document.querySelector('#name').value") == "edited")
    operate("set_control", { target = node("Enabled"), kind = "checkbox", value = true })
    check("checkbox-control-effect", evaluate(target, "document.querySelector('#enabled').checked") == true)
    operate("set_control", { target = node("Choice"), kind = "select", value = "b" })
    check("select-control-effect", evaluate(target, "document.querySelector('#choice').value") == "b")
    operate("activate", { target = node("Save") })
    check("activation-output", evaluate(target, "document.querySelector('#saved').textContent") == "Saved edited")
    check("activation-count", evaluate(target, "window.saveCount") == 1)
    local duplicate = pcall(invoke, "buff_evaluate", { target = target, source = "window.saveCount++", sequence = sequence })
    check("duplicate-evaluation-rejected", not duplicate)
    check("duplicate-evaluation-no-effect", evaluate(target, "window.saveCount") == 1)
    check("intentional-evaluation-first", evaluate(target, "window.saveCount += 1") == 2)
    check("intentional-evaluation-repeat", evaluate(target, "window.saveCount += 1") == 3)
    local failing_source = "window.errorCount = (window.errorCount || 0) + 1; throw new Error('fixture-exception')"
    sequence = sequence + 1
    local failed = invoke("buff_evaluate", { target = target, source = failing_source, sequence = sequence }).data
    check("evaluation-exception-outcome", failed.outcome == "failed")
    check("evaluation-exception-message", failed.error.message:find("fixture-exception", 1, true) ~= nil)
    check("evaluation-exception-effect", evaluate(target, "window.errorCount") == 1)
    sequence = sequence + 1
    local repeated = invoke("buff_evaluate", { target = target, source = failing_source, sequence = sequence }).data
    check("evaluation-repeat-error-outcome", repeated.outcome == "failed")
    check("evaluation-repeat-error-effect", evaluate(target, "window.errorCount") == 2)
    local function event_contains(observation, text)
      local events = inspect({ kind = "events", observation = observation })
      for _, event in ipairs(events.events) do
        if vim.json.encode(event.value):find(text, 1, true) then return true end
      end
      return false
    end
    check("console-event", vim.wait(3000, function() return event_contains(console, "fixture-saved") end, 10))
    local path = vim.fn.tempname()
    exports[#exports + 1] = path
    local exported = invoke("buff_export", { observation = console, path = path }).data
    check("export-completed", exported.outcome == "succeeded")
    local contents = table.concat(vim.fn.readfile(path), "\n")
    check("export-content", contents:find("fixture-saved", 1, true) ~= nil)
    check("export-mode", vim.fn.getfperm(path) == "rw-------")
    local overwrite = invoke("buff_export", { observation = console, path = path }).data
    check("export-overwrite-refused", overwrite.outcome ~= "succeeded")
    check("export-existing-unchanged", table.concat(vim.fn.readfile(path), "\n") == contents)
    vim.fn.delete(path)
    local view = invoke("buff_view", { kind = "page", command = "open", target = target }).data
    check("page-view-open", view.outcome == "succeeded" and vim.api.nvim_buf_is_valid(view.value.bufnr))
    local buf = view.value.bufnr
    check("page-view-uri", vim.api.nvim_buf_get_name(buf):match("^browser://.+/page$") ~= nil)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved fixture edit" })
    local function view_state()
      for _, item in ipairs(inspect({ kind = "views" }).views) do if item.bufnr == buf then return item end end
    end
    check("dirty-view-reported", view_state().modified == true)
    local refresh = invoke("buff_operate", { action = "refresh_view", target = { view = view.value.view } }).data
    check("dirty-refresh-refused", refresh.outcome ~= "succeeded")
    check("dirty-edit-preserved", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "unsaved fixture edit")
    operate("discard_view", { target = { view = view.value.view } })
    check("discard-clears-modified", view_state().modified == false)
    check("discard-restores-content", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "unsaved fixture edit")
    operate("refresh_view", { target = { view = view.value.view } })
    check("refresh-view-current", not view_state().stale)
    local page_target = { view = view.value.view }
    local enabled_line
    for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if text:find("checkbox Enabled\t", 1, true) then enabled_line = line end
    end
    vim.api.nvim_win_set_cursor(0, { enabled_line, 0 })
    invoke("buff_view", { kind = "page", command = "next", target = page_target })
    check("page-next-save", vim.api.nvim_get_current_line() == "button Save")
    invoke("buff_view", { kind = "page", command = "previous", target = page_target })
    check("page-previous-enabled", vim.api.nvim_win_get_cursor(0)[1] == enabled_line)
    local page_win = vim.api.nvim_get_current_win()
    invoke("buff_view", { kind = "page", command = "help", target = page_target })
    local help_win = vim.api.nvim_get_current_win()
    check("page-help-window", help_win ~= page_win and vim.api.nvim_win_get_config(help_win).relative == "editor")
    check("page-help-content", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("previous actionable row", 1, true) ~= nil)
    vim.api.nvim_win_close(help_win, true)
    for _, kind in ipairs({ "tabs", "eval", "console", "network" }) do
      local opened = invoke("buff_view", { kind = kind, command = "open", target = target }).data
      check(kind .. "-view-open", opened.outcome == "succeeded" and vim.api.nvim_buf_is_valid(opened.value.bufnr))
      local expected = kind == "tabs" and "^browser://tabs$" or "^browser://.+/" .. kind .. "$"
      check(kind .. "-view-uri", vim.api.nvim_buf_get_name(opened.value.bufnr):match(expected) ~= nil)
      check(kind .. "-view-visible", vim.api.nvim_get_current_buf() == opened.value.bufnr)
    end
    operate("follow", { target = node("Destination") })
    check("follow-local-destination", evaluate(target, "location.href") == fixture("destination.html"))
    check("network-event", vim.wait(3000, function() return event_contains(network, "Network.") end, 10))
    local replacement = operate("snapshot", { target = target }).value
    check("replacement-document", replacement.document ~= snapshot.document)
    local stale = invoke("buff_operate", { action = "activate", target = node("Save") }).data
    check("stale-node-rejected", stale.outcome ~= "succeeded")
    operate("navigate", { target = target, url = fixture("index.html") })
    check("navigate-local-fixture", evaluate(target, "document.title") == "Adapter fixture")
    operate("unobserve", { observation = console })
    operate("unobserve", { observation = network })
    operate("close_tab", { target = target })
    local found = false
    for _, entry in ipairs(inspect({ kind = "tabs" }).tabs) do if entry.tab == tab then found = true end end
    check("closed-tab-absent", not found)
    local released = invoke("buff_release", {})
    check("release-response", released.released == true)
    local remaining = inspect({ kind = "status" })
    check("release-keeps-browser", remaining.browser ~= nil and remaining.state == "running")
    operate("stop", { target = { browser = remaining.browser } })
    check("stop-state", inspect({ kind = "status" }).state == "stopped")
    local restarted = operate("start", { options = { headless = true } }).value
    check("restart-new-browser-token", restarted.browser ~= remaining.browser)
    operate("stop", { target = { browser = restarted.browser } })
  end)
end)
