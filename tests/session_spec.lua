local sessions = require("straps-buff.session")
local buffers = {}
local released
local unsubscribed, disposers
local api = { client = function()
  local client = { release = function() released = released + 1 end }
  function client:on_observation_disposed(callback)
    disposers[self] = callback
    return function() unsubscribed = unsubscribed + 1; disposers[self] = nil end
  end
  return client
end }
local function new()
  local buffer = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = buffer
  return sessions.get(buffer, api), buffer
end
local assertion = 0
local function check(value, message)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_BUFF_INVERT) == assertion then value = not value end
  assert(value, message)
end
teardown(function() print("ASSERTIONS=" .. assertion) end)
before_each(function() released, unsubscribed, disposers = 0, 0, {} end)
after_each(function()
  for _, buffer in ipairs(buffers) do if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end end
  buffers = {}
end)
it("keeps identities session-scoped and expires released handles", function()
  local first, second = new(), new()
  local identity = {}
  local token = first:store("tab", identity, true)
  check(first:resolve(token, "tab") == identity, "identity changed")
  check(first:store("tab", identity, true) == token, "identity token changed")
  check(not pcall(second.resolve, second, token, "tab"), "foreign token accepted")
  first:release()
  check(released == 1, "client not released once")
  check(not pcall(first.resolve, first, token, "tab"), "released token accepted")
  first:release()
  check(released == 1, "release repeated")
end)
it("retains four snapshots and pages at two hundred rows", function()
  local s = new()
  local rows = {}
  for index = 1, 401 do rows[index] = { text = tostring(index) } end
  local first = s:store("snapshot", { rows = rows })
  local page = s:page(first, "snapshot")
  check(#page.rows == 200, "wrong page size")
  check(page.next_offset == 201, "wrong next offset")
  check(s:page(first, "snapshot", 401).rows[1].text == "401", "last row changed")
  for _ = 1, 4 do s:store("snapshot", { rows = {} }) end
  check(not pcall(s.resolve, s, first, "snapshot"), "oldest snapshot retained")
end)
it("rejects repeated evaluation sequences across result eviction and release", function()
  local s, buffer = new()
  s:sequence(2)
  local token = s:store("result", "ok")
  s:remove(token)
  check(not pcall(s.sequence, s, 2), "duplicate accepted after result eviction")
  check(not pcall(s.sequence, s, 1), "older sequence accepted")
  s:release()
  local next_session = sessions.get(buffer, api)
  check(not pcall(next_session.sequence, next_session, 2), "release reset sequence")
  next_session:sequence(3)
  check(next_session.last_sequence == 3, "intentional repeat not admitted")
end)
it("bounds operation history and node handles independently", function()
  local s = new()
  local first = s:store("operation", {}, true)
  for _ = 1, 128 do s:store("operation", {}, true) end
  check(not pcall(s.resolve, s, first, "operation"), "old operation retained")
  check(s.handle_count == 128, "operation count unbounded")
  for _ = 129, 4096 do s:store("node", {}, true) end
  check(not pcall(s.store, s, "node", {}, true), "node handle cap exceeded")
  check(s.handle_count == 4096, "handle count exceeded cap")
end)
it("enforces client and global retention budgets", function()
  local clients = { new(), new(), new(), new(), new() }
  for index = 1, 4 do
    for _ = 1, 15 do clients[index]:store("payload", string.rep("x", 1024 * 1024)) end
    check(not pcall(clients[index].store, clients[index], "payload", string.rep("x", 2 * 1024 * 1024)), "client budget exceeded")
  end
  check(not pcall(clients[5].store, clients[5], "payload", string.rep("x", 4 * 1024 * 1024)), "global budget exceeded")
  clients[1]:release()
  check(pcall(clients[5].store, clients[5], "payload", string.rep("x", 4 * 1024 * 1024)), "release did not return global budget")
end)
it("keeps one deletion handler across repeated release and recreation", function()
  local s, buffer = new()
  local count = #vim.api.nvim_get_autocmds({ event = "BufWipeout", buffer = buffer })
  for _ = 1, 20 do s:release(); s = sessions.get(buffer, api) end
  check(#vim.api.nvim_get_autocmds({ event = "BufWipeout", buffer = buffer }) == count, "release accumulated deletion handlers")
  vim.api.nvim_buf_delete(buffer, { force = true })
  check(released == 21, "deletion did not release current client once")
end)
it("sweeps idle sessions before allocating against the global budget", function()
  local idle = new()
  local token = idle:store("payload", string.rep("x", 1024 * 1024))
  idle.items[token].created = -1000
  local active = new()
  active:store("payload", "new")
  check(idle.items[token] == nil, "idle expired allocation retained")
  check(idle.bytes == 0, "idle expired bytes still consume budget")
end)
it("retains observation handles until client disposal", function()
  local s = new()
  local identity = {}
  local token = s:store("observation", identity, true)
  s.items[token].created = -1000
  s:sweep()
  check(s:resolve(token, "observation") == identity, "active observation lost its handle")
  s:release()
  check(released == 1 and s.items[token] == nil, "observation owner not disposed on release")
end)
it("reclaims disposed observation capacity without expiring live observations", function()
  local s, other = new(), new()
  local live, dead, unrelated = {}, {}, {}
  local first = s:store("observation", live, true)
  local second = s:store("observation", dead, true)
  local kept = other:store("observation", unrelated, true)
  local held = other:store("observation", dead, true)
  s.items[first].created, s.items[second].created = -1000, -1000
  disposers[s.client](dead)
  check(s.items[first] ~= nil, "live observation expired")
  check(s.items[second] == nil, "disposed observation retained")
  check(s.handle_count == 1 and s.bytes == 128, "disposed observation capacity leaked")
  check(s.reverse[dead] == nil, "disposed observation reverse identity retained")
  check(other.items[kept] ~= nil and other.reverse[unrelated] == kept, "unrelated observation removed")
  check(other.items[held] == nil and other.reverse[dead] == nil, "holder of disposed observation retained it")
  check(other.handle_count == 1 and other.bytes == 128, "other session capacity leaked")
  check(s:store("observation", {}, true) ~= nil and s.handle_count == 2, "capacity not restored")
end)
it("unsubscribes observation disposal on release and buffer deletion", function()
  local s, buffer = new()
  local client = s.client
  check(disposers[client] ~= nil, "disposal not subscribed")
  s:release()
  check(unsubscribed == 1 and disposers[client] == nil, "release did not unsubscribe")
  s:release()
  check(unsubscribed == 1, "unsubscribe repeated")
  local next_session = sessions.get(buffer, api)
  vim.api.nvim_buf_delete(buffer, { force = true })
  check(unsubscribed == 2 and disposers[next_session.client] == nil, "deletion did not unsubscribe")
end)
it("invalidates idle resources on lifecycle generation changes without resetting sequences", function()
  local idle = new()
  sessions.generation(11)
  local token = idle:store("result", "old")
  idle:sequence(8)
  local operation = idle:store("operation", {}, true)
  vim.api.nvim_exec_autocmds("User", { pattern = "BuffLifecycle", data = { state = "stopped", generation = 12 } })
  check(idle.items[operation] ~= nil, "lifecycle discarded pending operation")
  idle:remove(operation)
  check(idle.items[token] == nil and idle.bytes == 0, "generation retained idle data")
  check(not pcall(idle.sequence, idle, 8), "generation reset evaluation sequence")
  idle:sequence(9)
  check(idle.last_sequence == 9, "generation blocked higher sequence")
end)
it("retains lists under count and byte pressure without removing identities", function()
  local s = new()
  local identity = {}
  local handle = s:store("tab", identity, true)
  local tokens = {}
  for index = 1, 4 do tokens[index] = s:store("list", { rows = { { index = index } } }) end
  local latest = s:store("list", { rows = { { index = 5 } } })
  check(s.items[tokens[1]] == nil, "oldest list survived count cap")
  check(s.items[tokens[2]] ~= nil and s.items[tokens[4]] ~= nil, "count cap evicted excess lists")
  check(s:resolve(handle, "tab") == identity, "count eviction removed identity")
  local original = sessions.limits.client
  s:remove(tokens[4])
  local bytes = s.items[tokens[2]].bytes
  sessions.limits.client = s.bytes + bytes - 1
  local ok, token = pcall(s.store, s, "list", { rows = { { index = 6 } } })
  sessions.limits.client = original
  check(ok and s.items[token] ~= nil, "byte pressure failed to reclaim own list")
  check(s.items[tokens[2]] == nil and s.items[tokens[3]] ~= nil and s.items[latest] ~= nil, "byte eviction removed excess lists")
  s.items[latest].created = -1000
  check(not pcall(s.page, s, latest, "list"), "expired list remained pageable")
end)
it("rejects oversized lists and rows without evicting continuations", function()
  local s = new()
  local tokens = {}
  for index = 1, 4 do tokens[index] = s:store("list", { rows = { { index = index } } }) end
  check(not pcall(s.store, s, "list", { rows = { { text = string.rep("x", sessions.limits.snapshot) } } }), "oversized list accepted")
  check(s:page(tokens[1], "list").rows[1].index == 1, "oversized list evicted continuation")
  local token = s:store("list", { rows = { { fields = { string.rep("x", 50000) } } } })
  check(not pcall(s.page, s, token, "list"), "oversized row accepted")
end)
it("preflights list reclamation against session and global pressure", function()
  local s, other = new(), new()
  local tokens = {}
  for index = 1, 4 do tokens[index] = s:store("list", { rows = { { index = index } } }) end
  local payload = s:store("payload", string.rep("x", 1000))
  other:store("payload", string.rep("x", 1000))
  for _, budget in ipairs({ "client", "global" }) do
    local original = sessions.limits[budget]
    sessions.limits[budget] = 500
    local ok = pcall(s.store, s, "list", { rows = { { index = 5 } } })
    sessions.limits[budget] = original
    check(not ok, budget .. " pressure accepted unreclaimable allocation")
    local intact = s.items[payload] ~= nil
    for _, token in ipairs(tokens) do intact = intact and s.items[token] ~= nil end
    check(intact, budget .. " rejection removed existing allocations")
  end
  s:remove(tokens[4])
  local original = sessions.limits.global
  sessions.limits.global = s.bytes + other.bytes + 1
  local ok = pcall(s.store, s, "list", { rows = { { index = 6 } } })
  sessions.limits.global = original
  check(ok and s.items[tokens[1]] == nil and s.items[tokens[2]] ~= nil, "global pressure failed minimal own-list reclamation")
  local limit = sessions.limits.client
  sessions.limits.client = s.bytes
  local admitted = pcall(s.store, s, "payload", "unrelated")
  sessions.limits.client = limit
  check(not admitted and s.items[tokens[2]] ~= nil, "unrelated allocation evicted list")
end)
it("preserves snapshot metadata on first and continuation pages without leaking it to lists", function()
  local s = new()
  local value = { rows = { { text = "first" }, { text = "last" } }, truncated = true, limit = 1048576, bytes = 1049000 }
  local token = s:store("snapshot", value)
  for offset = 1, 2 do
    local page = s:page(token, "snapshot", offset, 1)
    check(page.truncated == true, "snapshot page " .. offset .. " lost truncation")
    check(page.limit == 1048576, "snapshot page " .. offset .. " lost limit")
    check(page.bytes == 1049000, "snapshot page " .. offset .. " lost bytes")
  end
  local empty = s:store("snapshot", { rows = {} })
  local ordinary = s:page(empty, "snapshot")
  check(ordinary.truncated == nil and ordinary.limit == nil and ordinary.bytes == nil, "ordinary snapshot invented truncation")
  local explicit = s:store("snapshot", { rows = {}, truncated = false })
  check(s:page(explicit, "snapshot").truncated == false, "explicit non-truncation changed")
  local list = s:store("list", value)
  for offset = 1, 2 do
    local page = s:page(list, "list", offset, 1)
    check(page.truncated == nil and page.limit == nil and page.bytes == nil, "list page " .. offset .. " leaked snapshot metadata")
  end
end)
it("enforces byte limits and expires history", function()
  local s = new()
  check(not pcall(s.store, s, "snapshot", string.rep("x", sessions.limits.snapshot)), "oversized snapshot accepted")
  check(not pcall(s.store, s, "result", string.rep("x", sessions.limits.result + 1)), "oversized result accepted")
  check(not pcall(sessions.encode, { text = string.rep("x", sessions.limits.response) }), "oversized response accepted")
  local token = s:store("tab", {}, true)
  s.items[token].created = -1000
  check(not pcall(s.resolve, s, token, "tab"), "expired handle accepted")
  check(s.handle_count == 0 and s.bytes == 0, "expired bytes retained")
end)
