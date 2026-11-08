local registry = require("straps.registry")
local plugin = require("straps-buff")
local assertion = 0
local function check(value, message)
  assertion = assertion + 1
  if tonumber(vim.env.STRAPS_BUFF_INVERT) == assertion then value, message = not value, "COUNTERFACTUAL=" .. assertion .. ": " .. message end
  assert(value, message)
end
teardown(function() print("ASSERTIONS=" .. assertion) end)
package.loaded["buff.api"] = { version = function() return 1 end, client = function() error("setup created a client") end }

it("requires configured Straps before changing the registry", function()
  local ok, err = pcall(plugin.setup)
  check(not ok and tostring(err):find("Straps setup must run", 1, true) ~= nil, "missing setup not rejected")
  check(registry.get("tool.buff_operate") == nil, "failed setup registered a tool")
  check(registry.get("fn.capability") == nil, "failed setup registered a classifier")
end)

it("validates collisions before adding a category", function()
  require("straps").setup({})
  check(not vim.tbl_contains(registry.call("fn.capability"), "browser"), "core defines browser category")
  registry.define({ name = "tool.buff_operate", kind = "tool", source = "return function() end" })
  local classifier = registry.get("fn.capability")
  local ok, err = pcall(plugin.setup)
  check(not ok and tostring(err):find("registry collision", 1, true) ~= nil, "collision not rejected")
  check(vim.deep_equal(registry.get("fn.capability"), classifier), "collision changed classifier")
  registry.remove("tool.buff_operate")
end)

it("preserves a custom classifier and its retained category array", function()
  _G.buff_setup_categories = { "edit", "custom" }
  registry.define({ name = "fn.capability", kind = "fn", source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name == nil then return _G.buff_setup_categories end
  if name == "custom_tool" then return input.category end
  return base(name, input)
end
]==] })
  plugin.setup()
  check(vim.deep_equal(registry.call("fn.capability"), { "edit", "custom", "browser" }), "custom categories not preserved")
  check(vim.deep_equal(_G.buff_setup_categories, { "edit", "custom" }), "base category array mutated")
  local categories = registry.call("fn.capability")
  categories[1] = "changed"
  check(registry.call("fn.capability")[1] == "edit", "enumeration shares mutable array")
  check(registry.call("fn.capability", "custom_tool", { category = "custom" }) == "custom", "custom classification changed")
  check(registry.call("fn.capability", "buff_operate", {}) == "browser", "tool metadata classification changed")
  local classifier = registry.get("fn.capability")
  plugin.setup()
  check(vim.deep_equal(registry.get("fn.capability"), classifier), "repeat setup redefined classifier")
end)

it("keeps a preexisting browser category and classifier unchanged", function()
  registry.define({ name = "fn.capability", kind = "fn", source = [==[
local base = require("straps.registry").bind("fn.capability")
return function(name, input)
  if name == nil then return { "browser", "custom" } end
  return base(name, input)
end
]==] })
  local classifier = registry.get("fn.capability")
  plugin.setup()
  check(vim.deep_equal(registry.get("fn.capability"), classifier), "existing browser classifier redefined")
  check(vim.deep_equal(registry.call("fn.capability"), { "browser", "custom" }), "existing category list changed")
end)
