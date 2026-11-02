local root = vim.fn.getcwd()
local paths = {
  root,
  vim.env.STRAPS_BUFF_BUFF_PATH or (root .. "/.deps/buff"),
  vim.env.STRAPS_BUFF_STRAPS_PATH or (root .. "/.deps/straps"),
}
for i = #paths, 1, -1 do
  assert(vim.fn.isdirectory(paths[i] .. "/lua") == 1, "Missing Lua dependency directory: " .. paths[i])
  vim.opt.runtimepath:prepend(paths[i])
end
