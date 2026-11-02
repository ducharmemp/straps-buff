local M = {}
local sessions = {}
local serial = 0
local total_bytes = 0
local generation
local limits = {
  response = 64 * 1024, snapshot = 1024 * 1024, snapshots = 4, rows = 200,
  source = 64 * 1024, result = 256 * 1024, history = 128, age = 600,
  handles = 4096, logs = 2000, log_bytes = 2 * 1024 * 1024,
  client = 16 * 1024 * 1024, global = 64 * 1024 * 1024,
}
M.limits = limits

local function now()
  return vim.uv.hrtime() / 1e9
end

local function encoded(value)
  local ok, text = pcall(vim.json.encode, value)
  assert(ok, "straps-buff: result is not JSON-serializable")
  return text
end

local Session = {}
Session.__index = Session

function Session:remove(token)
  local item = self.items[token]
  if not item then return false end
  self.items[token] = nil
  if item.reservation then self:remove(item.reservation) end
  self.bytes = self.bytes - item.bytes
  total_bytes = total_bytes - item.bytes
  if item.identity then
    self.reverse[item.value] = nil
    self.handle_count = self.handle_count - 1
  end
  return true
end

function Session:sweep()
  local cutoff = now() - limits.age
  for token, item in pairs(self.items) do
    if not item.reserved and item.kind ~= "observation" and item.created < cutoff then self:remove(token) end
  end
end

function M.dispose_observation(identity)
  for _, s in pairs(sessions) do
    local token = s.reverse[identity]
    if token and s.items[token] and s.items[token].kind == "observation" then s:remove(token) end
  end
end

function M.sweep()
  for _, s in pairs(sessions) do s:sweep() end
end

function M.generation(value)
  if value == nil then return end
  generation = value
  for _, s in pairs(sessions) do
    if s.generation ~= nil and s.generation ~= value then
      for token, item in pairs(s.items) do
        if item.kind ~= "operation" and not item.reserved then s:remove(token) end
      end
    end
    s.generation = value
  end
end

function Session:store(kind, value, identity)
  assert(not self.released, "straps-buff: session released")
  M.sweep()
  if identity and self.reverse[value] then return self.reverse[value] end
  local bytes = identity and 128 or kind == "result" and type(value) == "string" and #value or #encoded(value)
  local maximum = (kind == "snapshot" or kind == "list") and limits.snapshot or kind == "result" and limits.result or limits.client
  assert(bytes <= maximum, "straps-buff: " .. kind .. " exceeds retention limit")
  if kind == "list" then
    local entries, reclaimed = {}, 0
    for token, item in pairs(self.items) do
      if item.kind == "list" then entries[#entries + 1] = { token = token, bytes = item.bytes, serial = item.serial } end
    end
    table.sort(entries, function(a, b) return a.serial < b.serial end)
    local count = 0
    while #entries - count >= limits.snapshots or self.bytes + bytes - reclaimed > limits.client
      or total_bytes + bytes - reclaimed > limits.global do
      count = count + 1
      local item = entries[count]
      assert(item, "straps-buff: retention budget exhausted; release resources")
      reclaimed = reclaimed + item.bytes
    end
    for index = 1, count do self:remove(entries[index].token) end
  end
  local capacity = kind == "snapshot" and limits.snapshots or (kind == "operation" or kind == "result") and limits.history or nil
  if capacity then
    local entries = {}
    for token, item in pairs(self.items) do
      if item.kind == kind and not item.reserved then entries[#entries + 1] = { token = token, created = item.created } end
    end
    table.sort(entries, function(a, b) return a.created < b.created end)
    while #entries >= capacity do self:remove(table.remove(entries, 1).token) end
  end
  if identity and self.handle_count >= limits.handles then
    error("straps-buff: handle limit reached; release resources or wait for expiration")
  end
  assert(self.bytes + bytes <= limits.client and total_bytes + bytes <= limits.global,
    "straps-buff: retention budget exhausted; release resources")
  self.next_token = self.next_token + 1
  local token = self.prefix .. ":" .. kind .. ":" .. self.next_token
  self.items[token] = { kind = kind, value = value, bytes = bytes, created = now(), serial = self.next_token, identity = identity }
  self.bytes = self.bytes + bytes
  total_bytes = total_bytes + bytes
  if identity then self.reverse[value] = token; self.handle_count = self.handle_count + 1 end
  return token
end

function Session:bind(token, value)
  local item = assert(self.items[token], "straps-buff: reservation expired")
  local existing = self.reverse[value]
  if existing then self:remove(token); return existing end
  self.reverse[item.value] = nil
  item.value, item.reserved = value, nil
  self.reverse[value] = token
  return token
end

function Session:resolve(token, kind)
  self:sweep()
  local item = self.items[token]
  assert(item and item.kind == kind, "straps-buff: expired, foreign, or invalid " .. kind .. " token")
  return item.value
end

function Session:sequence(value)
  assert(type(value) == "number" and value % 1 == 0 and value > self.last_sequence and value <= 9007199254740991,
    "straps-buff: sequence must be a strictly increasing safe positive integer; never retry an uncertain evaluation")
  self.last_sequence = value
end

function M.bound_row(row)
  local copy = vim.deepcopy(row)
  for _, key in ipairs({ "browser", "tab", "document", "node", "view" }) do copy[key] = row[key] end
  local truncated = {}
  local function shorten(value, path)
    for key, field in pairs(value) do
      local name = path == "" and tostring(key) or path .. "." .. key
      if type(field) == "string" and #encoded(field) > 8192 then
        local last = math.min(#field, 8190)
        while last > 0 do
          local byte = field:byte(last + 1)
          if byte and byte >= 128 and byte < 192 then last = last - 1
          elseif #encoded(field:sub(1, last)) > 8192 then last = math.floor(last / 2)
          else break end
        end
        value[key] = field:sub(1, last)
        truncated[#truncated + 1] = { field = name, original_bytes = #field, retained_bytes = last }
      elseif type(field) == "table" and key ~= "browser" and key ~= "tab" and key ~= "document"
        and key ~= "node" and key ~= "view" then shorten(field, name) end
    end
  end
  shorten(copy, "")
  if #truncated > 0 then copy.truncation = truncated end
  return copy
end

function Session:page(token, kind, offset, count)
  local value = self:resolve(token, kind)
  offset, count = offset or 1, count or limits.rows
  local rows = value.rows or value
  assert(type(rows) == "table" and vim.islist(rows), "straps-buff: retained value has no rows")
  assert(type(offset) == "number" and offset % 1 == 0 and offset >= 1
    and type(count) == "number" and count % 1 == 0 and count >= 1 and count <= limits.rows,
    "straps-buff: page offset must be positive and limit must be 1..200")
  local result = { token = token, offset = offset, total = #rows, rows = {}, untrusted = true,
    browser = value.browser, tab = value.tab, document = value.document, revision = value.revision }
  if kind == "snapshot" then
    result.truncated, result.limit, result.bytes = value.truncated, value.limit, value.bytes
  end
  local bytes = #encoded(result)
  for index = offset, math.min(#rows, offset + count - 1) do
    local size = #encoded(rows[index]) + 1
    if bytes + size > limits.response - (kind == "list" and 16384 or 1024) then
      if #result.rows == 0 then error("straps-buff: row exceeds response limit") end
      break
    end
    result.rows[#result.rows + 1] = rows[index]
    bytes = bytes + size
  end
  local next_row = offset + #result.rows
  if next_row <= #rows then result.next_offset = next_row end
  return result
end

function Session:release()
  if self.released then return end
  self.released = true
  for token in pairs(self.items) do self:remove(token) end
  self.unsubscribe()
  self.client:release()
end

vim.api.nvim_create_autocmd("User", { pattern = "BuffLifecycle", callback = function(event)
  M.generation(event.data and event.data.generation)
end })

function M.get(bufnr, api)
  assert(type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr), "straps-buff: valid Straps session required")
  if sessions[bufnr] and not sessions[bufnr].released then return sessions[bufnr] end
  local previous = sessions[bufnr]
  local last_sequence = previous and previous.last_sequence or 0
  serial = serial + 1
  local self = setmetatable({ prefix = "b" .. serial, items = {}, reverse = {}, bytes = 0,
    next_token = 0, handle_count = 0, last_sequence = last_sequence, generation = generation,
    client = api.client({ name = "straps:" .. bufnr, interaction = "noninteractive" }),
  }, Session)
  self.unsubscribe = self.client:on_observation_disposed(M.dispose_observation)
  sessions[bufnr] = self
  if not previous then
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = bufnr, once = true, callback = function()
      if sessions[bufnr] then sessions[bufnr]:release() end
      sessions[bufnr] = nil
    end })
  end
  return self
end

function M.release(bufnr)
  local session = sessions[bufnr]
  if session then session:release() end
end

function M.encode(value)
  local text = encoded(value)
  assert(#text <= limits.response, "straps-buff: response exceeds 64KiB; request a smaller page")
  return text
end

return M
