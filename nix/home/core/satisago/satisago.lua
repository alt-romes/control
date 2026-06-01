-- satisago: nvim integrations for the satisago tree.
-- In .md files under vim.g.satisago_root, fold contiguous completed-todo
-- blocks. Open with `zo`/`za`, edit inside, close with `zc`.

local function in_root(name)
  local r = vim.g.satisago_root
  if type(r) ~= 'string' or r == '' or name == '' then return false end
  if r:sub(-1) ~= '/' then r = r .. '/' end
  return name:sub(1, #r) == r
end

local function is_done(line)
  return line:match('^%s*%- %[[xX]%] ') ~= nil
end

-- foldexpr: called per line, returns its fold level (builds the folds).
function _G.satisago_foldexpr()
  -- is_done ? fold level = 1 : fold level = 0
  return is_done(vim.fn.getline(vim.v.lnum)) and '1' or '0'
end

-- foldtext: called per closed fold, returns the single line shown in its place.
function _G.satisago_foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  local indent = vim.fn.getline(vim.v.foldstart):match('^(%s*)') or ''
  return ('%s… See %d completed to-do%s'):format(indent, n, n == 1 and '' or 's')
end

vim.api.nvim_create_autocmd('BufWinEnter', {
  group = vim.api.nvim_create_augroup('Satisago', { clear = true }),
  pattern = '*.md',
  callback = function(args)
    if not in_root(vim.api.nvim_buf_get_name(args.buf)) then return end
    vim.opt_local.foldmethod = 'expr'
    vim.opt_local.foldexpr = 'v:lua.satisago_foldexpr()'
    vim.opt_local.foldtext = 'v:lua.satisago_foldtext()'
    vim.opt_local.foldenable = true
    vim.opt_local.foldminlines = 0
    vim.opt_local.fillchars:append({ fold = ' ' })
  end,
})
