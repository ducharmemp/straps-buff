local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")
local dispatched, prompts, inspect_calls, released, buffers = {}, 0, 0, 0, {}
local original_confirm = vim.fn.confirm
local browser = {}
package.loaded["buff.api"] = { version = function() return 1 end, client = function()
  return {
    inspect = function() inspect_calls = inspect_calls + 1; return { browser = browser } end,
    submit = function(_, request, callback)
      dispatched[#dispatched + 1] = request.action
      callback({ id = {}, action = request.action, outcome = "succeeded", state = "completed" })
      return { id = {}, cancel_observation = function() end }
    end,
    release = function() released = released + 1 end,
    on_observation_disposed = function() return function() end end,
  }
end }
require("straps-buff").setup()
_G.buff_permission_guard = {}
registry.define({ name = "hook.guard.buff_test", kind = "hook", source = [[
return function(op, name)
  if name ~= "buff_operate" then return end
  if op == "before" and _G.buff_permission_guard.before then return false, "test before denial" end
  if op == "after" and _G.buff_permission_guard.after then return false, "test after denial" end
end
]] })
local assertion = 0
local function check(value, message)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_BUFF_INVERT) == assertion then value = not value end
  assert(value, message)
end
teardown(function() print("ASSERTIONS=" .. assertion) end)
local function script(calls)
  _G.buff_permission_script = calls
  _G.buff_permission_turns = {}
  registry.define({ name = "fn.provider", kind = "fn", source = [[
return function(req, ctx)
  local turn = (_G.buff_permission_turns[ctx.bufnr] or 0) + 1
  _G.buff_permission_turns[ctx.bufnr] = turn
  local call = _G.buff_permission_script[turn]
  if call then return {stop_reason='tool_use',content={{type='tool_use',id='b'..turn,name=call.name,input=call.input}}} end
  return {stop_reason='end_turn',content={{type='text',text='done'}}}
end
]] }, { scope = "global" })
end
local function new()
  local buffer = state.new_session()
  buffers[#buffers + 1] = buffer
  state.append_text(buffer, "exercise browser tools")
  return buffer
end
local function run(buffer)
  loop.start(buffer)
  check(vim.wait(10000, function() return not loop.running(buffer) end, 10), "model-origin loop did not finish")
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end
before_each(function()
  dispatched, prompts, inspect_calls, released = {}, 0, 0, 0
  _G.buff_permission_guard = {}
  vim.fn.confirm = function() prompts = prompts + 1; return 2 end
end)
after_each(function()
  vim.fn.confirm = original_confirm
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
  buffers = {}
end)
it("denies execution before dispatch while cached inspection stays permission-free", function()
  script({ { name = "buff_operate", input = { action = "start" } }, { name = "buff_inspect", input = { kind = "status" } } })
  local text = run(new())
  check(#dispatched == 0, "denied operation dispatched")
  check(prompts == 1, "wrong confirmation count")
  check(inspect_calls == 1, "cached inspection not executed")
  check(text:find("denied", 1, true) ~= nil, "denial missing from transcript")
end)
it("exact operate grant admits start stop close and discard without extra prompts", function()
  local buffer = new()
  local s = require("straps-buff.session").get(buffer, require("buff.api"))
  local b = s:store("browser", browser, true)
  local t = s:store("tab", {}, true)
  local v = s:store("view", {}, true)
  registry.grant(buffer, registry.tool_grant_key("buff_operate"))
  registry.grant(buffer, registry.tool_grant_key("buff_release"))
  require("straps-buff").setup()
  script({ { name = "buff_operate", input = { action = "start" } },
    { name = "buff_operate", input = { action = "stop", target = { browser = b } } },
    { name = "buff_operate", input = { action = "close_tab", target = { tab = t } } },
    { name = "buff_operate", input = { action = "discard_view", target = { view = v } } },
    { name = "buff_evaluate", input = { target = { tab = t }, sequence = 1, source = "1" } },
    { name = "buff_release", input = {} } })
  run(buffer)
  check(table.concat(dispatched, ",") == "start,stop,close_tab,discard_view", "exact grant dispatched wrong operations")
  check(prompts == 1, "operate prompted again or evaluation inherited grant")
  check(released == 1, "release did not release own client")
end)
it("before guards prevent dispatch and after guards retain their result policy", function()
  local buffer = new()
  registry.grant(buffer, registry.tool_grant_key("buff_operate"))
  _G.buff_permission_guard.before = true
  script({ { name = "buff_operate", input = { action = "start" } } })
  local text = run(buffer)
  check(#dispatched == 0, "before guard bypassed")
  check(text:find("test before denial", 1, true) ~= nil, "before denial missing")
  _G.buff_permission_guard = { after = true }
  local second = new()
  registry.grant(second, registry.tool_grant_key("buff_operate"))
  script({ { name = "buff_operate", input = { action = "start" } } })
  text = run(second)
  check(#dispatched == 1, "after guard prevented execution")
  check(text:find("test after denial", 1, true) ~= nil, "after policy missing")
  check(prompts == 0, "guards changed exact grant")
end)
it("readonly child runs inspection and denies operation through the model loop", function()
  local parent = new()
  registry.grant(parent, "cap:spawn")
  _G.buff_permission_turns = {}
  registry.define({ name = "fn.provider", kind = "fn", source = [[
return function(req, ctx)
  local n = (_G.buff_permission_turns[ctx.bufnr] or 0) + 1
  _G.buff_permission_turns[ctx.bufnr] = n
  local child = vim.b[ctx.bufnr].straps_parent ~= nil
  local calls
  if child then
    _G.buff_readonly_child = ctx.bufnr
    calls = {{name='buff_inspect',input={kind='status'}},{name='buff_operate',input={action='start'}}}
  else calls = {{name='spawn',input={task='exercise readonly browser tools',readonly=true}}} end
  local call = calls[n]
  if call then return {stop_reason='tool_use',content={{type='tool_use',id='r'..n,name=call.name,input=call.input}}} end
  return {stop_reason='end_turn',content={{type='text',text='done'}}}
end
]] }, { scope = "global" })
  _G.buff_readonly_child = nil
  run(parent)
  check(vim.wait(10000, function() return _G.buff_readonly_child and not loop.running(_G.buff_readonly_child) end, 10), "child did not finish")
  local child = _G.buff_readonly_child
  buffers[#buffers + 1] = child
  local text = table.concat(vim.api.nvim_buf_get_lines(child, 0, -1, false), "\n")
  check(inspect_calls == 1, "readonly inspection denied")
  check(#dispatched == 0, "readonly child dispatched operation")
  check(text:find("readonly subagent: buff_operate is not allowed", 1, true) ~= nil, "readonly denial missing")
end)
it("keeps evaluate view and export grants distinct across sessions", function()
  local buffer = new()
  local s = require("straps-buff.session").get(buffer, require("buff.api"))
  local tab = s:store("tab", {}, true)
  local observation = s:store("observation", {}, true)
  for _, name in ipairs({ "buff_evaluate", "buff_view", "buff_export" }) do
    registry.grant(buffer, registry.tool_grant_key(name))
  end
  script({ { name = "buff_evaluate", input = { target = { tab = tab }, sequence = 1, source = "1" } },
    { name = "buff_view", input = { kind = "tabs", command = "open" } },
    { name = "buff_export", input = { observation = observation, path = "/tmp/buff-permissions" } } })
  run(buffer)
  check(table.concat(dispatched, ",") == "evaluate,view,export", "granted tools did not dispatch")
  check(prompts == 0, "exact grants prompted")
  local second = new()
  run(second)
  check(#dispatched == 3, "another session inherited exact grants")
  check(prompts == 3, "ungranted tools did not each prompt")
end)
it("resolves cancellation through the model loop before the backstop", function()
  local buffer = new()
  local s = require("straps-buff.session").get(buffer, require("buff.api"))
  local detached = 0
  local identity = {}
  s.client.submit = function()
    vim.schedule(function() loop.stop(buffer) end)
    return { id = identity, cancel_observation = function() detached = detached + 1 end }
  end
  local previous = straps.config.stop_backstop_ms
  straps.config.stop_backstop_ms = 60000
  registry.grant(buffer, registry.tool_grant_key("buff_operate"))
  script({ { name = "buff_operate", input = { action = "start" } } })
  loop.start(buffer)
  local finished = vim.wait(2000, function() return not loop.running(buffer) end, 10)
  straps.config.stop_backstop_ms = previous
  check(finished, "cancel depended on Straps backstop")
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  check(detached == 1, "Buff observer not detached once")
  check(text:find("observer_detached", 1, true) ~= nil, "detached result missing from model transcript")
  check(text:find('unresolved', 1, true) ~= nil, "cancel claimed completed execution")
  local token = s.reverse[identity]
  check(token ~= nil and s:resolve(token, "operation") == identity, "cancel lost operation token")
end)
it("tool redefinition invalidates exact grants", function()
  local buffer = new()
  registry.grant(buffer, registry.tool_grant_key("buff_operate"))
  local spec = registry.get("tool.buff_operate")
  registry.define(spec, { scope = "global" })
  script({ { name = "buff_operate", input = { action = "start" } } })
  run(buffer)
  check(#dispatched == 0, "stale exact grant executed new definition")
  check(prompts == 1, "new definition did not prompt")
end)
