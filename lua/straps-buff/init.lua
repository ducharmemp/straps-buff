local M = {}
local installed = {}

function M.setup(options)
  assert(options == nil or (type(options) == "table" and next(options) == nil), "straps-buff: setup accepts no options; configure Buff separately")
  local ok, api = pcall(require, "buff.api")
  assert(ok, "straps-buff: Buff API v1 is required; install the compatible Buff revision before setup")
  assert(type(api.version) == "function" and api.version() == 1 and type(api.client) == "function",
    "straps-buff: incompatible Buff API; expected version 1 with client()")
  local found, registry = pcall(require, "straps.registry")
  assert(found and type(registry.define) == "function" and type(registry.get) == "function",
    "straps-buff: Straps registry is required; install Straps before setup")
  assert(registry.active_scope() == nil, "straps-buff: setup must run from trusted configuration outside a Straps session")
  local specs = require("straps-buff.tools").specs
  for _, spec in ipairs(specs) do
    local name = "tool." .. spec.name
    local existing = registry.get(name)
    if existing then
      assert(installed[name] and vim.deep_equal(existing, installed[name]), "straps-buff: registry collision at " .. name)
    else
      assert(not installed[name], "straps-buff: registered tool was removed: " .. name)
    end
  end
  for _, spec in ipairs(specs) do
    local name = "tool." .. spec.name
    if not installed[name] then
      registry.define({ name = name, kind = "tool", capability = spec.capability, doc = spec.doc,
        input_schema = spec.schema,
        source = ('return function(input, ctx) return require("straps-buff.tools").call(%q, input, ctx) end'):format(spec.name),
      }, { scope = "global" })
      installed[name] = registry.get(name)
    end
  end
  return M
end

return M
