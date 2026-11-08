local registry = require("straps.registry")
local tools = require("straps-buff.tools")
local sessions = require("straps-buff.session")
local calls, clients, buffer, context, cancelled
local browser, tab, document, node = {}, {}, {}, {}
local assertion = 0
local function check(value, message)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_BUFF_INVERT) == assertion then value = not value end
  assert(value, message)
end
teardown(function() print("ASSERTIONS=" .. assertion) end)
local function invoke(name, input)
  return vim.json.decode(tools.call(name, input, context))
end
before_each(function()
  calls, clients = {}, 0
  cancelled = false
  package.loaded["buff.api"] = { version = function() return 1 end, client = function(options)
    clients = clients + 1
    check(options.interaction == "noninteractive", "interactive client")
    return {
      inspect = function(_, request)
        calls[#calls + 1] = request
        return { browser = browser, tab = tab, document = document, node = node }
      end,
      submit = function(_, request, callback)
        calls[#calls + 1] = request
        callback({ id = {}, action = request.action, state = "completed", outcome = "succeeded", value = request.action == "evaluate" and { result = "ok" } or "ok" })
        return { id = {}, cancel_observation = function() cancelled = true end }
      end,
      release = function() calls[#calls + 1] = { action = "release" } end,
      on_observation_disposed = function() return function() end end,
    }
  end }
  buffer = vim.api.nvim_create_buf(false, true)
  context = { bufnr = buffer, await = function(start)
    local result
    start(function(value) result = value end)
    return result
  end, on_cancel = function(callback) context.cancel = callback end, cancelled = function() return false end }
end)
after_each(function() vim.api.nvim_buf_delete(buffer, { force = true }) end)
it("registers six capabilities without redefining unchanged setup", function()
  local plugin = require("straps-buff")
  plugin.setup()
  local versions = {}
  for _, spec in ipairs(tools.specs) do
    local entry = registry.get("tool." .. spec.name)
    check(entry.capability == spec.capability, "wrong capability for " .. spec.name)
    versions[spec.name] = entry.version
  end
  plugin.setup()
  for name, version in pairs(versions) do check(registry.get("tool." .. name).version == version, "setup redefined " .. name) end
end)
it("serializes provider-compatible schemas and retains variant validation", function()
  require("straps.provider").register()
  local serialized = vim.json.decode(vim.json.encode(registry.call("fn.build_tools")))
  local by_name = {}
  for _, tool in ipairs(serialized) do by_name[tool.name] = tool.input_schema end
  for name, required in pairs({ buff_inspect = "kind", buff_operate = "action", buff_export = "path" }) do
    local schema = by_name[name]
    check(schema and schema.type == "object" and not schema.anyOf and not schema.oneOf and not schema.allOf, name .. " root schema")
    check(schema.additionalProperties == false and #schema.required == 1 and schema.required[1] == required, name .. " required fields")
  end
  local function alternatives(schema, field)
    local result = {}
    for _, choice in ipairs(schema.properties[field].anyOf or { schema.properties[field] }) do
      for _, value in ipairs(choice.enum or {}) do result[value] = true end
    end
    return result
  end
  local kinds = alternatives(by_name.buff_inspect, "kind")
  for _, kind in ipairs({ "status", "tabs", "views", "operations", "list_page", "snapshot", "events", "operation", "page", "result" }) do
    check(kinds[kind], "missing inspect kind " .. kind)
  end
  local actions = alternatives(by_name.buff_operate, "action")
  for _, action in ipairs({ "start", "stop", "new_tab", "navigate", "close_tab", "snapshot", "activate", "follow", "set_control", "refresh_view", "discard_view", "observe", "unobserve" }) do
    check(actions[action], "missing action " .. action)
  end
  local limits = by_name.buff_inspect.properties.limit.anyOf
  check(limits and limits[1].maximum == 200 and limits[2].maximum == 60000, "inspect limits")
  check(by_name.buff_operate.properties.target.anyOf ~= nil, "target alternatives missing")
  check(by_name.buff_export.properties.observation and by_name.buff_export.properties.target, "export alternatives missing")
  for _, case in ipairs({
    { "buff_inspect", { kind = "result", result = "r", limit = 60000 }, true },
    { "buff_inspect", { kind = "page", snapshot = "s", limit = 201 }, false },
    { "buff_inspect", { kind = "unknown" }, false },
    { "buff_operate", { action = "navigate", target = { tab = "t" }, url = "url" }, true },
    { "buff_operate", { action = "navigate", target = { tab = "t" } }, false },
    { "buff_operate", { action = "start", extra = true }, false },
    { "buff_export", { path = "p", observation = "o" }, true },
    { "buff_export", { path = "p", target = { view = "v" } }, true },
    { "buff_export", { path = "p" }, false },
    { "buff_export", { path = "p", observation = "o", target = { view = "v" } }, false },
  }) do
    check(pcall(tools.validate, case[1], case[2]) == case[3], "validation " .. vim.inspect(case))
  end
end)
it("keeps inspection cached and resolves opaque targets for execution", function()
  local data = invoke("buff_inspect", { kind = "status" }).data
  check(type(data.browser) == "string", "browser identity exposed")
  check(#calls == 1 and calls[1].kind == "status", "inspection dispatched work")
  invoke("buff_operate", { action = "stop", target = { browser = data.browser } })
  check(calls[2].target.browser == browser, "target identity changed")
  check(calls[2].action == "stop", "stop action changed")
end)
it("rejects unknown fields and invalid action combinations before client creation", function()
  local invalid = {
    { "buff_operate", { action = "start", confirmed = true } },
    { "buff_operate", { action = "stop", target = {} } },
    { "buff_operate", { action = "navigate", target = { tab = "x" } } },
    { "buff_operate", { action = "set_control", target = { tab = "x", document = "y", node = "z" }, kind = "checkbox", value = "yes" } },
    { "buff_evaluate", { target = { tab = "x" }, sequence = 1, source = string.rep("x", 65537) } },
    { "buff_release", { browser = "x" } },
    { "buff_inspect", { kind = "page", snapshot = "x", limit = 201 } },
    { "buff_view", { kind = "page", command = "open" } },
    { "buff_view", { kind = "tabs", command = "help" } },
  }
  for _, case in ipairs(invalid) do check(not pcall(invoke, case[1], case[2]), "invalid input accepted") end
  check(clients == 0, "invalid arguments created client")
end)
it("retains evaluation results and refuses sequence reuse", function()
  local data = invoke("buff_inspect", { kind = "status" }).data
  local result = invoke("buff_evaluate", { target = { tab = data.tab }, sequence = 1, source = "1+1" })
  local token = result.data.value.result
  check(invoke("buff_inspect", { kind = "result", result = token }).text == '"ok"', "evaluation result lost")
  check(not pcall(invoke, "buff_evaluate", { target = { tab = data.tab }, sequence = 1, source = "1+1" }), "duplicate evaluation admitted")
  check(#calls == 2, "duplicate evaluation dispatched")
end)
it("cancellation detaches operation without stopping the browser", function()
  invoke("buff_operate", { action = "start" })
  context.cancel()
  check(cancelled, "cancel handler not registered")
  check(#calls == 1 and calls[1].action == "start", "cancel dispatched stop")
end)
it("release affects only the caller and never creates a browser client", function()
  invoke("buff_release", {})
  check(clients == 0, "release created client")
  invoke("buff_inspect", { kind = "status" })
  invoke("buff_release", {})
  check(calls[2].action == "release", "client not released")
  check(#calls == 2, "release dispatched additional operation")
end)
it("paginates completed snapshots without rewriting browser-controlled JSON keys", function()
  local s = sessions.get(buffer, require("buff.api"))
  local rows = {}
  for index = 1, 401 do rows[index] = { node = {}, name = tostring(index) } end
  s.client.submit = function(_, request, callback)
    local value = request.action == "snapshot" and { tab = tab, document = document, rows = rows }
      or { result = { tab = { arbitrary = "browser text" }, node = "not an identity" } }
    callback({ id = {}, action = request.action, state = "completed", outcome = "succeeded", value = value })
    return { id = {}, cancel_observation = function() end }
  end
  local t = s:store("tab", tab, true)
  local result = invoke("buff_operate", { action = "snapshot", target = { tab = t } })
  check(#result.data.value.rows == 200, "completed snapshot not paginated")
  check(result.data.value.next_offset == 201, "snapshot cursor missing")
  check(s:resolve(result.data.value.rows[1].node, "node") == rows[1].node, "snapshot node identity lost")
  local page = invoke("buff_inspect", { kind = "page", snapshot = result.data.value.token, offset = 401 })
  check(page.rows[1].name == "401", "retained snapshot page changed")
  result = invoke("buff_evaluate", { target = { tab = t }, sequence = 1, source = "arbitrary" })
  local text = invoke("buff_inspect", { kind = "result", result = result.data.value.result }).text
  check(vim.json.decode(text).node == "not an identity", "evaluation JSON tokenized")
  check(vim.json.decode(text).tab.arbitrary == "browser text", "evaluation object changed")
end)
it("bounds cached event pages and reports sequence gaps without interpreting event JSON", function()
  local s = sessions.get(buffer, require("buff.api"))
  local observation = s:store("observation", {}, true)
  s.client.inspect = function()
    local events = {}
    for index = 10, 240 do events[#events + 1] = { sequence = index, value = { node = { tab = "raw" } } } end
    return { events = events, dropped = 9, observation = s:resolve(observation, "observation") }
  end
  local result = invoke("buff_inspect", { kind = "events", observation = observation, offset = 1 }).data
  check(#result.events == 200, "event page exceeds row cap")
  check(result.gap and result.dropped == 9, "event gap missing")
  check(result.next_offset == 210, "event cursor wrong")
  check(result.events[1].value.node.tab == "raw", "event JSON tokenized")
  result = invoke("buff_inspect", { kind = "events", observation = observation, offset = 210 }).data
  check(#result.events == 31 and not result.gap, "last event page wrong")
end)
it("cancellation before submission never dispatches", function()
  context.cancelled = function() return true end
  local result = invoke("buff_operate", { action = "start" })
  check(result.data.outcome == "cancelled", "cancellation outcome missing")
  check(#calls == 0, "already cancelled context dispatched")
end)
it("retains submitted operation identities even when observation cancels before completion", function()
  local s = sessions.get(buffer, require("buff.api"))
  local identity = {}
  local removed = false
  s.client.submit = function()
    return { id = identity, cancel_observation = function() removed = true end }
  end
  context.await = function(start)
    local result
    start(function(value) result = value end)
    context.cancel()
    return result
  end
  local detached = invoke("buff_operate", { action = "start" }).data
  check(detached.observer_detached == true and detached.state == "observer_detached", "cancel did not resolve detached record")
  check(detached.outcome == "unresolved" and detached.effect == "unresolved", "cancel claimed an execution outcome")
  local list = invoke("buff_inspect", { kind = "operations" })
  check(removed, "queued cancellation not forwarded")
  check(#list.operations == 1, "submitted operation not queryable after cancellation")
  s.client.operation = function(_, id)
    check(id == identity, "operation lookup lost identity")
    return { id = id, action = "start", state = "completed", outcome = "cancelled", effect = "none" }
  end
  local record = invoke("buff_inspect", { kind = "operation", operation = list.operations[1] }).data
  check(record.outcome == "cancelled", "operation outcome lost")
end)
it("keeps evaluation result pages within byte bounds after JSON escaping", function()
  local s = sessions.get(buffer, require("buff.api"))
  local token = s:store("result", string.rep('"', 60000))
  local output = tools.call("buff_inspect", { kind = "result", result = token, limit = 60000 }, context)
  check(#output <= 65536, "escaped evaluation result exceeded output limit")
  check(vim.json.decode(output).next_offset ~= nil, "escaped result lost continuation")
end)
it("forwards every supported operation without changing its arguments", function()
  local s = sessions.get(buffer, require("buff.api"))
  local b, t, d, n = s:store("browser", browser, true), s:store("tab", tab, true),
    s:store("document", document, true), s:store("node", node, true)
  local view, observation = {}, {}
  local v, o = s:store("view", view, true), s:store("observation", observation, true)
  local requests = {
    { action = "start", options = { headless = true } },
    { action = "stop", target = { browser = b } },
    { action = "new_tab", target = { browser = b }, url = "about:blank" },
    { action = "navigate", target = { tab = t }, url = "https://example.test" },
    { action = "close_tab", target = { tab = t } },
    { action = "snapshot", target = { tab = t } },
    { action = "activate", target = { tab = t, document = d, node = n } },
    { action = "follow", target = { tab = t, document = d, node = n } },
    { action = "set_control", target = { tab = t, document = d, node = n }, kind = "text", value = "hello" },
    { action = "set_control", target = { tab = t, document = d, node = n }, kind = "checkbox", value = false },
    { action = "set_control", target = { tab = t, document = d, node = n }, kind = "select", value = { "a", "b" } },
    { action = "refresh_view", target = { view = v } },
    { action = "discard_view", target = { view = v } },
    { action = "observe", target = { tab = t }, kind = "console" },
    { action = "observe", target = { tab = t }, kind = "network" },
    { action = "unobserve", observation = o },
  }
  local originals = { browser = browser, tab = tab, document = document, node = node, view = view }
  for index, request in ipairs(requests) do
    invoke("buff_operate", request)
    check(calls[index].action == request.action, "operation action changed")
    if request.target then
      for key in pairs(request.target) do check(calls[index].target[key] == originals[key], "operation target changed") end
    end
    if request.kind then check(calls[index].kind == request.kind, "operation kind changed") end
    if request.value ~= nil then check(vim.deep_equal(calls[index].value, request.value), "control value changed") end
    if request.url then check(calls[index].url == request.url, "navigation URL changed") end
    if request.options then check(calls[index].options.headless == true, "startup option changed") end
    if request.observation then check(calls[index].observation == observation, "observation identity changed") end
  end
end)
it("expires retained resources when inspection discovers browser replacement", function()
  local old = invoke("buff_inspect", { kind = "status" }).data
  local s = sessions.get(buffer, require("buff.api"))
  local result = s:store("result", "old")
  local replacement = {}
  s.client.inspect = function() return { browser = replacement } end
  local fresh = invoke("buff_inspect", { kind = "status" }).data
  check(not pcall(s.resolve, s, old.tab, "tab"), "replacement retained old target")
  check(not pcall(s.resolve, s, result, "result"), "replacement retained old result")
  check(s:resolve(fresh.browser, "browser") == replacement, "replacement browser identity lost")
end)
it("reserves operation retention before effectful dispatch", function()
  local s = sessions.get(buffer, require("buff.api"))
  for _ = 1, sessions.limits.handles do s:store("node", {}, true) end
  check(not pcall(invoke, "buff_operate", { action = "start" }), "dispatch admitted without operation capacity")
  check(#calls == 0, "retention failure happened after dispatch")
end)
it("reserves primary resource identities and reports reconciliation capacity failures", function()
  local s = sessions.get(buffer, require("buff.api"))
  local t = s:store("tab", tab, true)
  local b = s:store("browser", browser, true)
  local cases = {
    { "buff_operate", { action = "start" }, "browser" },
    { "buff_operate", { action = "new_tab", target = { browser = b }, url = "about:blank" }, "tab" },
    { "buff_operate", { action = "observe", target = { tab = t }, kind = "console" }, "observation" },
    { "buff_operate", { action = "observe", target = { tab = t }, kind = "network" }, "observation" },
  }
  for _, kind in ipairs({ "tabs", "page", "eval", "console", "network" }) do
    cases[#cases + 1] = { "buff_view", { kind = kind, command = "open", target = { tab = t } }, "view" }
  end
  local original = sessions.limits.handles
  local ok, err = pcall(function()
    for _, case in ipairs(cases) do
      local dispatched, identity, operation = 0, {}, {}
      s.client.submit = function(_, request, callback)
        dispatched = dispatched + 1
        callback({ id = operation, action = request.action, state = "completed", outcome = "succeeded", effect = "completed",
          value = { [case[3]] = identity }, reconciliation = { views = { { view = {}, tab = {} } } } })
        return { id = operation, cancel_observation = function() end }
      end
      sessions.limits.handles = s.handle_count + 1
      check(not pcall(invoke, case[1], case[2]), "resource admitted with only operation capacity: " .. case[3])
      check(dispatched == 0, "resource dispatched before capacity check: " .. case[3])
      sessions.limits.handles = s.handle_count + 2
      local result = invoke(case[1], case[2]).data
      check(dispatched == 1, "minimal reservation blocked resource: " .. case[3])
      check(s:resolve(result.value[case[3]], case[3]) == identity, "resource identity lost at capacity: " .. case[3])
      check(s:resolve(result.id, "operation") == operation, "operation recovery identity lost")
      check(result.response_error ~= nil and result.outcome == "succeeded" and result.effect == "completed", "serialization failure hid execution outcome")
      s:remove(result.value[case[3]])
      s:remove(result.id)
    end
  end)
  sessions.limits.handles = original
  assert(ok, err)
end)
it("protects pending operation reservations from sweeping and history eviction", function()
  local s = sessions.get(buffer, require("buff.api"))
  local pending, identity = nil, {}
  s.client.submit = function(_, _, callback)
    pending = callback
    return { id = identity, cancel_observation = function() end }
  end
  context.await = function(start)
    local result
    start(function(value) result = value end)
    local token = s.reverse[identity]
    s.items[token].created = -1000
    for _ = 1, 129 do s:store("operation", {}, true) end
    check(s.items[token] ~= nil, "pending operation reservation evicted")
    pending({ id = identity, action = "start", state = "completed", outcome = "succeeded", value = { browser = {} } })
    return result
  end
  local result = invoke("buff_operate", { action = "start" }).data
  check(s:resolve(result.id, "operation") == identity, "pending recovery identity lost")
  check(type(result.value.browser) == "string", "pending primary reservation lost")
end)
it("returns operation recovery when snapshots or evaluation results cannot be retained", function()
  local s = sessions.get(buffer, require("buff.api"))
  local t = s:store("tab", tab, true)
  local original_handles, original_client = sessions.limits.handles, sessions.limits.client
  local ok, err = pcall(function()
    for _, action in ipairs({ "snapshot", "evaluate" }) do
      local operation = {}
      s.client.submit = function(_, request, callback)
        callback({ id = operation, action = action, state = "completed", outcome = "succeeded", effect = "completed",
          value = action == "snapshot" and { tab = tab, document = {}, rows = { { node = {} } } } or { result = "hello" } })
        return { id = operation, cancel_observation = function() end }
      end
      sessions.limits.handles = s.handle_count + 1
      sessions.limits.client = s.bytes + 128
      local result = action == "snapshot"
        and invoke("buff_operate", { action = action, target = { tab = t } }).data
        or invoke("buff_evaluate", { target = { tab = t }, sequence = 1, source = "hello" }).data
      check(result.outcome == "succeeded" and result.response_error ~= nil, "retention failure lost outcome: " .. action)
      check(s:resolve(result.id, "operation") == operation, "retention failure lost recovery: " .. action)
      s:remove(result.id)
    end
  end)
  sessions.limits.handles, sessions.limits.client = original_handles, original_client
  assert(ok, err)
end)
it("recovers a detached resource operation at the exact handle boundary", function()
  local s = sessions.get(buffer, require("buff.api"))
  local t = s:store("tab", tab, true)
  local operation, observation = {}, {}
  s.client.submit = function()
    return { id = operation, cancel_observation = function() end }
  end
  context.await = function(start)
    local result
    start(function(value) result = value end)
    context.cancel()
    return result
  end
  local original = sessions.limits.handles
  sessions.limits.handles = s.handle_count + 2
  local ok, err = pcall(function()
    local detached = invoke("buff_operate", { action = "observe", target = { tab = t }, kind = "console" }).data
    check(detached.observer_detached == true, "resource cancellation lost unresolved status")
    s.client.operation = function(_, id)
      return { id = id, action = "observe", state = "completed", outcome = "succeeded", value = { observation = observation },
        reconciliation = { views = { { view = {} } } } }
    end
    local completed = invoke("buff_inspect", { kind = "operation", operation = detached.id }).data
    check(s:resolve(completed.value.observation, "observation") == observation, "detached resource reservation lost")
    local repeated = invoke("buff_inspect", { kind = "operation", operation = detached.id }).data
    check(repeated.value.observation == completed.value.observation, "repeated recovery omitted existing resource")
  end)
  sessions.limits.handles = original
  assert(ok, err)
end)
it("keeps current sessions intact when inspecting historical lifecycle operations", function()
  local s = sessions.get(buffer, require("buff.api"))
  local other_buffer = vim.api.nvim_create_buf(false, true)
  local other = sessions.get(other_buffer, require("buff.api"))
  sessions.generation(51)
  s.client.generation = function() return 51 end
  local own = s:store("tab", {}, true)
  local foreign = other:store("tab", {}, true)
  local operation = s:store("operation", {}, true)
  s.client.operation = function(_, id)
    return { id = id, action = "start", state = "completed", outcome = "succeeded", value = { generation = 50, browser = {} } }
  end
  invoke("buff_inspect", { kind = "operation", operation = operation })
  local own_alive, foreign_alive = s.items[own] ~= nil, other.items[foreign] ~= nil
  local own_generation, foreign_generation = s.generation, other.generation
  vim.api.nvim_buf_delete(other_buffer, { force = true })
  check(own_alive and own_generation == 51, "historical operation invalidated querying session")
  check(foreign_alive and foreign_generation == 51, "historical operation invalidated another session")
end)
it("preserves UTF-8 characters across retained result pages", function()
  local s = sessions.get(buffer, require("buff.api"))
  local token = s:store("result", '"é😀x"')
  local first = invoke("buff_inspect", { kind = "result", result = token, limit = 4 })
  check(first.text == '"é' and first.next_offset == 4, "result page split a UTF-8 character")
  local second = invoke("buff_inspect", { kind = "result", result = token, offset = first.next_offset, limit = 4 })
  check(second.text == "😀" and second.next_offset == 8, "result continuation corrupted UTF-8")
  check(not pcall(invoke, "buff_inspect", { kind = "result", result = token, offset = 3 }), "partial UTF-8 offset admitted")
end)
it("translates cached snapshots and forwards view and export requests", function()
  local s = sessions.get(buffer, require("buff.api"))
  local t = s:store("tab", tab, true)
  local view, observation = {}, {}
  local v, o = s:store("view", view, true), s:store("observation", observation, true)
  invoke("buff_inspect", { kind = "snapshot", tab = t })
  check(calls[1].target.tab == tab and calls[1].tab == nil, "cached snapshot target mismatch")
  invoke("buff_view", { kind = "page", command = "open", target = { tab = t } })
  check(calls[2].action == "view" and calls[2].target.tab == tab, "view target mismatch")
  invoke("buff_view", { kind = "page", command = "help", target = { view = v } })
  check(calls[3].command == "help" and calls[3].target.view == view, "view help mismatch")
  invoke("buff_export", { observation = o, path = "/tmp/buff-log" })
  check(calls[4].action == "export" and calls[4].observation == observation, "observation export mismatch")
  invoke("buff_export", { target = { view = v }, path = "/tmp/buff-log" })
  check(calls[5].target.view == view and calls[5].path == "/tmp/buff-log", "view export mismatch")
end)
it("reclaims repeated tab and view lists before exhausting retention", function()
  local s = sessions.get(buffer, require("buff.api"))
  local original = sessions.limits.client
  local ok, err = pcall(function()
    sessions.limits.client = 128 * 1024
    local first, latest, identity
    for index = 1, 12 do
      local kind = index % 2 == 1 and "tabs" or "views"
      local key = kind == "tabs" and "tab" or "view"
      local rows = {}
      for row = 1, 450 do rows[row] = { [key] = key == "tab" and tab or node, title = string.rep("x", 40), index = row } end
      s.client.inspect = function() return { [kind] = rows } end
      latest = invoke("buff_inspect", { kind = kind }).data
      first = first or latest.token
      identity = identity or latest[kind][1][key]
    end
    check(not pcall(s.resolve, s, first, "list"), "repeated reads retained oldest list")
    check(s:resolve(identity, "tab") == tab, "list eviction removed independent identity")
    check(invoke("buff_inspect", { kind = "list_page", token = latest.token, offset = latest.next_offset }).rows[1].index == 201,
      "latest continuation lost after repeated reads")
  end)
  sessions.limits.client = original
  assert(ok, err)
end)
it("traverses retained lists in order through identity expiration and capacity retry", function()
  local s = sessions.get(buffer, require("buff.api"))
  for _, kind in ipairs({ "tabs", "views" }) do
    local key = kind == "tabs" and "tab" or "view"
    local rows = {}
    for index = 1, 450 do rows[index] = { [key] = {}, index = index, title = "row" .. index } end
    s.client.inspect = function() return { [kind] = rows } end
    local first = invoke("buff_inspect", { kind = kind }).data
    local page, ordered, stable, seen = first, true, true, {}
    local count = 0
    while page do
      for _, row in ipairs(page[kind] or page.rows) do
        count = count + 1
        ordered = ordered and row.index == count
        seen[row.index] = (seen[row.index] or 0) + 1
      end
      stable = stable and page.revision == first.revision and page.total == 450
      if not page.next_offset then break end
      page = invoke("buff_inspect", { kind = "list_page", token = first.token, offset = page.next_offset })
    end
    local unique = count == 450
    for index = 1, 450 do unique = unique and seen[index] == 1 end
    check(ordered, kind .. " traversal changed order")
    check(unique, kind .. " traversal omitted or duplicated rows")
    check(stable, kind .. " traversal changed revision or total")
    local expired = first[kind][1][key]
    s.items[expired].created = -1000
    local recovered = invoke("buff_inspect", { kind = "list_page", token = first.token, offset = 1, limit = 1 })
    check(s.items[expired] == nil and s:resolve(recovered.rows[1][key], key) == rows[1][key], "retained list did not regenerate expired identity")
    rows[201][key] = {}
    local pending = rows[201]
    first = invoke("buff_inspect", { kind = kind }).data
    local original = sessions.limits.handles
    sessions.limits.handles = s.handle_count
    local request = { kind = "list_page", token = first.token, offset = 201, limit = 1 }
    local ok, err = pcall(invoke, "buff_inspect", request)
    local retained = s.items[first.token] ~= nil
    s:remove(recovered.rows[1][key])
    local retry_ok, retried = pcall(invoke, "buff_inspect", request)
    sessions.limits.handles = original
    check(not ok and tostring(err):find("handle limit reached", 1, true) ~= nil, "late page did not report handle exhaustion")
    check(retained, "failed late page removed continuation")
    check(retry_ok and retried.token == first.token and retried.rows[1].index == 201
      and s:resolve(retried.rows[1][key], key) == pending[key], "same continuation retry failed after freeing capacity")
  end
end)
it("rejects aggregate oversized rows after bounding individual fields", function()
  local s = sessions.get(buffer, require("buff.api"))
  for _, kind in ipairs({ "tabs", "views" }) do
    local key = kind == "tabs" and "tab" or "view"
    local row = { [key] = {} }
    for index = 1, 12 do row["field" .. index] = string.rep("x", 16000) end
    s.client.inspect = function() return { [kind] = { row } } end
    local ok, err = pcall(invoke, "buff_inspect", { kind = kind })
    check(not ok and tostring(err):find("row exceeds response limit", 1, true) ~= nil, "aggregate oversized row was not rejected")
    local bounded = sessions.bound_row(row)
    local shortened = true
    for index = 1, 12 do shortened = shortened and #bounded["field" .. index] <= 8192 end
    check(shortened and #bounded.truncation == 12, "individual oversized fields were not bounded")
  end
end)
it("retains immutable bounded tab and view collections with oversized UTF-8 fields", function()
  local s = sessions.get(buffer, require("buff.api"))
  for _, kind in ipairs({ "tabs", "views" }) do
    local key = kind == "tabs" and "tab" or "view"
    local rows = {}
    for index = 1, 24 do rows[index] = { [key] = {}, title = string.rep('é😀"', 2000), index = index } end
    s.client.inspect = function() return { [kind] = rows, revision = 17 } end
    local output = tools.call("buff_inspect", { kind = kind }, context)
    local first = vim.json.decode(output).data
    check(#output <= 65536 and first.total == 24, "list response exceeds bound or loses total")
    check(first.next_offset ~= nil and first.revision ~= nil, "list continuation missing")
    check(first[kind][1].truncation[1].original_bytes == #rows[1].title, "field truncation metadata missing")
    check(s:resolve(first[kind][1][key], key) == rows[1][key], "list identity changed")
    local expected = rows[first.next_offset][key]
    rows[first.next_offset].title = "changed"
    rows[first.next_offset][key] = {}
    rows[25] = { [key] = {}, title = "new" }
    local next_page = invoke("buff_inspect", { kind = "list_page", token = first.token, offset = first.next_offset })
    check(next_page.total == 24 and next_page.revision == first.revision, "list changed between pages")
    check(next_page.rows[1].title ~= "changed", "retained field mutated")
    check(s:resolve(next_page.rows[1][key], key) == expected, "retained identity mutated")
    check(#vim.json.encode(next_page) <= 65536, "continued list response oversized")
  end
end)
it("consumes failed and unknown evaluation sequences before admitting intentional repeats", function()
  local s = sessions.get(buffer, require("buff.api"))
  local token = s:store("tab", tab, true)
  for index, outcome in ipairs({ "failed", "unknown" }) do
    s.client.submit = function(_, request, callback)
      calls[#calls + 1] = request
      callback({ id = {}, action = "evaluate", outcome = outcome })
      return { id = {}, cancel_observation = function() end }
    end
    local input = { target = { tab = token }, sequence = index, source = "throw 1" }
    check(invoke("buff_evaluate", input).data.outcome == outcome, "evaluation outcome changed")
    check(not pcall(invoke, "buff_evaluate", input), "failed or uncertain sequence reused")
    check(#calls == index, "duplicate evaluation dispatched")
  end
  check(s.last_sequence == 2, "higher intentional sequence not consumed")
end)
it("removes observation tokens only after successful unsubscribe", function()
  local s = sessions.get(buffer, require("buff.api"))
  local token = s:store("observation", {}, true)
  invoke("buff_operate", { action = "unobserve", observation = token })
  check(s.items[token] == nil, "unsubscribe retained observation handle")
end)
it("invalidates tokens on stopped generation before decoding a retained target", function()
  local s = sessions.get(buffer, require("buff.api"))
  local generation = 31
  s.client.generation = function() return generation end
  local old = invoke("buff_inspect", { kind = "status" }).data
  local token = s:store("result", "old")
  s:sequence(5)
  generation = 32
  s.client.inspect = function() return { state = "stopped", generation = generation } end
  local stopped = invoke("buff_inspect", { kind = "status" }).data
  check(stopped.state == "stopped" and stopped.browser == nil, "stopped status changed")
  check(s.items[old.tab] == nil and s.items[token] == nil, "stop retained tokens without browser identity")
  check(not pcall(s.sequence, s, 5), "stop reset evaluation sequence")
  check(not pcall(invoke, "buff_operate", { action = "close_tab", target = { tab = old.tab } }), "old target survived stop")
end)
it("allows targetless stop to reach the validating Buff API", function()
  invoke("buff_operate", { action = "stop" })
  check(calls[1].action == "stop" and calls[1].target == nil, "startup stop target fabricated")
end)
it("preserves truncated snapshot metadata through cached and submitted retained pages", function()
  local s = sessions.get(buffer, require("buff.api"))
  local t = s:store("tab", tab, true)
  for _, source in ipairs({ "cached", "submitted" }) do
    for _, truncated in ipairs({ true, false }) do
      local snapshot = { rows = {}, browser = browser, tab = tab, document = document, revision = 73 }
      if truncated then snapshot.truncated, snapshot.limit, snapshot.bytes = true, 1048576, 1049000 end
      s.client.inspect = function() return snapshot end
      s.client.submit = function(_, request, callback)
        callback({ id = {}, action = request.action, state = "completed", outcome = "succeeded", value = snapshot })
        return { id = {}, cancel_observation = function() end }
      end
      local first = source == "cached" and invoke("buff_inspect", { kind = "snapshot", tab = t }).data
        or invoke("buff_operate", { action = "snapshot", target = { tab = t } }).data.value
      local retained = invoke("buff_inspect", { kind = "page", snapshot = first.token })
      for index, page in ipairs({ first, retained }) do
        local label = source .. " page " .. index
        if truncated then
          check(page.truncated == true, label .. " lost snapshot truncation")
          check(page.limit == 1048576, label .. " lost snapshot limit")
          check(page.bytes == 1049000, label .. " lost snapshot bytes")
          check(#page.rows == 0 and page.total == 0, label .. " changed empty truncated snapshot")
        else
          check(page.truncated == nil and page.limit == nil and page.bytes == nil, label .. " invented empty snapshot truncation")
        end
      end
    end
  end
end)
it("omits expired generation values from late completion and historical inspection", function()
  local s = sessions.get(buffer, require("buff.api"))
  local generation = 1
  s.client.generation = function() return generation end
  local identity = {}
  local record = { id = identity, action = "snapshot", state = "completed", outcome = "succeeded",
    resource_generation = 1, value = { browser = browser, tab = tab, document = document, rows = { { node = node } } },
    reconciliation = { state = "completed", views = { { view = {}, tab = tab, stale = true } } } }
  s.client.submit = function(_, _, callback)
    generation = 2
    sessions.generation(generation)
    callback(record)
    return { id = identity, cancel_observation = function() end }
  end
  s.client.operation = function(_, id) assert(id == identity, "foreign operation identity"); return record end
  local result = invoke("buff_operate", { action = "start" }).data
  check(s:resolve(result.id, "operation") == identity, "expired completion changed operation identity")
  check(result.resources_expired == true and result.value == nil, "late completion exposed obsolete resource value")
  local retained = invoke("buff_inspect", { kind = "operation", operation = result.id }).data
  check(retained.resources_expired == true and retained.value == nil, "historical inspection exposed obsolete value")
  check(retained.outcome == "succeeded" and retained.resource_generation == 1, "expired resources changed operation history")
  check(retained.id == result.id, "historical response changed operation token")
  check(retained.reconciliation.state == "completed" and #retained.reconciliation.views == 0, "expired reconciliation published resources")
  local resources = false
  for _, item in pairs(s.items) do if item.kind ~= "operation" then resources = true end end
  check(not resources, "obsolete completion recreated resource retention")
  check(record.value.tab == tab and record.resources_expired == nil, "conversion mutated Buff history")
end)

it("reports incompatible dependencies and registry collisions", function()
  local plugin = require("straps-buff")
  plugin.setup()
  package.loaded["buff.api"].version = function() return 2 end
  check(not pcall(plugin.setup), "incompatible API accepted")
  package.loaded["buff.api"].version = function() return 1 end
  local spec = registry.get("tool.buff_operate")
  registry.define(spec, { scope = "global" })
  check(not pcall(plugin.setup), "collision silently overwritten")
end)
