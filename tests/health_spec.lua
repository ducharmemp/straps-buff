it('checks dependencies and registration without creating a browser client', function()
  local saved, api, health = package.loaded['straps.registry'], package.loaded['buff.api'], vim.health
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(msg) reports[#reports + 1] = key .. ':' .. msg end end })
  package.loaded['straps.registry'] = { get = function() return {} end }
  package.loaded['buff.api'] = { version = function() return 1 end, client = function() error('health must not create a client') end }
  require('straps-buff.health').check()
  assert.is_truthy(table.concat(reports):find('ok:Buff API v1 available', 1, true))
  assert.is_truthy(table.concat(reports):find('ok:Buff tools registered', 1, true))
  reports = {}
  package.loaded['buff.api'] = { version = function() return 2 end }
  require('straps-buff.health').check()
  assert.is_truthy(table.concat(reports):find('error:Buff API v1', 1, true))
  package.loaded['straps.registry'], package.loaded['buff.api'], vim.health = saved, api, health
end)
