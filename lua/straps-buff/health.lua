local M = {}

function M.check()
  vim.health.start("straps-buff")
  local ok, api = pcall(require, "buff.api")
  if ok and type(api.version) == "function" and api.version() == 1 and type(api.client) == "function" then
    vim.health.ok("Buff API v1 available")
  else
    vim.health.error("Buff API v1 with client() is required; install the documented compatible revision")
  end
  local found, registry = pcall(require, "straps.registry")
  if not found then
    vim.health.error("Straps is missing from runtimepath")
  elseif registry.get("tool.buff_inspect") then
    vim.health.ok("Buff tools registered")
  else
    vim.health.warn("Buff tools are not registered; run setup() from trusted configuration")
  end
  vim.health.info("Browser checks do not start a browser; configure Buff separately")
end

return M
