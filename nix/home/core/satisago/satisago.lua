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

local function satisago_root()
  local r = vim.g.satisago_root
  if type(r) ~= 'string' or r == '' then
    vim.notify('satisago: g:satisago_root not set', vim.log.levels.ERROR)
    return nil
  end
  return r
end

local subcommands = {
  open = function()
    local r = satisago_root(); if not r then return end
    vim.cmd.edit(vim.fn.fnameescape(r .. '/projects/current/'))
  end,
  pull = function()
    local r = satisago_root(); if not r then return end
    vim.notify('satisago: git pull...')
    vim.system(
      { 'git', 'pull' },
      { cwd = r, text = true },
      vim.schedule_wrap(function(obj)
        local msg = (obj.stdout or '') .. (obj.stderr or '')
        local lvl = obj.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        vim.notify('satisago git pull:\n' .. msg, lvl)
      end)
    )
  end,
}

vim.api.nvim_create_user_command('Satisago', function(opts)
  local sub = opts.fargs[1] or 'open'
  local fn = subcommands[sub]
  if not fn then
    vim.notify('satisago: unknown subcommand: ' .. sub, vim.log.levels.ERROR)
    return
  end
  fn()
end, {
  nargs = '?',
  complete = function(arglead)
    local out = {}
    for name in pairs(subcommands) do
      if name:sub(1, #arglead) == arglead then table.insert(out, name) end
    end
    return out
  end,
})

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
