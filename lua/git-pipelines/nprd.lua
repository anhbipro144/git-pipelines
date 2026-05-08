local util = require 'git-pipelines.util'

local M = {}

---@param repo string|nil
---@return string
local function repo_display_name(repo)
  if not repo or repo == '' then
    return 'PR'
  end

  return repo:match('[^/]+$') or repo
end

---@param pr GitPipelinesItem
---@return string
local function pr_label(pr)
  return string.format('%s#%s', repo_display_name(pr.repo), tostring(pr.number or ''))
end

---@param pr GitPipelinesItem
---@return string
local function pr_link(pr)
  return string.format('<%s|%s>', pr.url, pr_label(pr))
end

---@param pr_url string
---@param config GitPipelinesNprdConfig
---@return string
local function message_for(pr_url, config)
  local message = config.message or 'Nhờ a <{mention}> check giúp e <{url}|PR này> nha'
  local rendered = message:gsub('{mention}', config.mention or ''):gsub('{url}', pr_url)

  return rendered
end

---@param prs GitPipelinesItem[]
---@param config GitPipelinesNprdConfig
---@return string
local function message_for_prs(prs, config)
  if #prs == 1 then
    return message_for(prs[1].url, config)
  end

  local messages = {}
  local mention = util.trim(config.mention or '')
  table.insert(messages, string.format('Nhờ a <%s> check giúp e mấy PRs này nha :', mention))
  table.insert(messages, '')

  for _, pr in ipairs(prs) do
    table.insert(messages, pr_link(pr))
  end

  return table.concat(messages, '\n')
end

---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  text = tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n')

  for line in (text .. '\n'):gmatch('(.-)\n') do
    table.insert(lines, line)
  end

  if #lines == 0 then
    return { '' }
  end

  return lines
end

---@param message string
---@param count integer
---@param on_confirm fun()
local function confirm_send(message, count, on_confirm)
  local preview = split_lines(message)
  local title = count == 1 and ' Send PR to NPRD Internal ' or ' Send PRs to NPRD Internal '
  local lines = { 'Preview message:', '' }

  for _, line in ipairs(preview) do
    table.insert(lines, line)
  end

  table.insert(lines, '')
  table.insert(lines, 'Press <CR>/y to send, q/<Esc>/n to cancel')

  local width = 50
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 4)
  end

  local max_width = math.max(40, math.floor(vim.o.columns * 0.8))
  local max_height = math.max(8, math.floor(vim.o.lines * 0.6))
  width = math.min(width, max_width)
  local height = math.min(#lines, max_height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = 'rounded',
    style = 'minimal',
    title = title,
    title_pos = 'center',
  })

  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    elseif vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local function confirm()
    close()
    on_confirm()
  end

  local keymap_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', '<CR>', confirm, keymap_opts)
  vim.keymap.set('n', 'y', confirm, keymap_opts)
  vim.keymap.set('n', 'q', close, keymap_opts)
  vim.keymap.set('n', '<Esc>', close, keymap_opts)
  vim.keymap.set('n', 'n', close, keymap_opts)
end

---@param pr_or_prs GitPipelinesItem|GitPipelinesItem[]|nil
---@return GitPipelinesItem[]
local function normalize_prs(pr_or_prs)
  if type(pr_or_prs) ~= 'table' then
    return {}
  end

  if pr_or_prs.url ~= nil then
    return { pr_or_prs }
  end

  local prs = {}
  for _, pr in ipairs(pr_or_prs) do
    if type(pr) == 'table' then
      table.insert(prs, pr)
    end
  end

  return prs
end

---@param pr_or_prs GitPipelinesItem|GitPipelinesItem[]|nil
---@param opts GitPipelinesConfig
---@param notify fun(message: string, level?: integer)
function M.send(pr_or_prs, opts, notify)
  local prs = normalize_prs(pr_or_prs)
  if #prs == 0 then
    notify('No pull request selected', vim.log.levels.WARN)
    return
  end

  for _, pr in ipairs(prs) do
    if util.trim(pr.url) == '' then
      notify('Selected pull request is missing a URL', vim.log.levels.WARN)
      return
    end
  end

  local config = opts.nprd_internal or {}
  local command = util.trim(config.command or 'gog')
  local space = util.trim(config.space or '')

  if command == '' or space == '' then
    notify('Chat command is not configured', vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(command) ~= 1 then
    notify(command .. ' CLI is not installed or not on $PATH', vim.log.levels.ERROR)
    return
  end

  local labels = {}
  for _, pr in ipairs(prs) do
    table.insert(labels, pr_label(pr))
  end
  local message = message_for_prs(prs, config)

  confirm_send(message, #prs, function()
    vim.system({
      command,
      'chat',
      'messages',
      'send',
      space,
      '--text',
      message,
    }, { text = true }, vim.schedule_wrap(function(result)
      if result.code == 0 then
        notify('Sent ' .. table.concat(labels, ', ') .. ' to NPRD Internal')
        return
      end

      local err = util.trim(result.stderr)
      if err == '' then
        err = util.trim(result.stdout)
      end
      notify(err ~= '' and err or 'Failed to send PR to NPRD Internal', vim.log.levels.ERROR)
    end))
  end)
end

return M
