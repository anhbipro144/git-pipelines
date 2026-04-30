local util = require 'git-pipelines.util'

local M = {}

---@param pr_url string
---@param config GitPipelinesNprdConfig
---@return string
local function message_for(pr_url, config)
  local message = config.message or 'Nhờ a <{mention}> check giúp e <{url}|PR này> nha'
  local rendered = message:gsub('{mention}', config.mention or ''):gsub('{url}', pr_url)

  return rendered
end

---@param pr GitPipelinesItem|nil
---@param opts GitPipelinesConfig
---@param notify fun(message: string, level?: integer)
function M.send(pr, opts, notify)
  if type(pr) ~= 'table' or util.trim(pr.url) == '' then
    notify('No pull request selected', vim.log.levels.WARN)
    return
  end

  local config = opts.nprd_internal or {}
  local command = util.trim(config.command or 'gog')
  local space = util.trim(config.space or '')

  if command == '' or space == '' then
    notify('NPRD Internal chat command is not configured', vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(command) ~= 1 then
    notify(command .. ' CLI is not installed or not on $PATH', vim.log.levels.ERROR)
    return
  end

  local label = string.format('%s#%s', pr.repo or 'PR', tostring(pr.number or ''))
  local message = message_for(pr.url, config)

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
      notify('Sent ' .. label .. ' to NPRD Internal')
      return
    end

    local err = util.trim(result.stderr)
    if err == '' then
      err = util.trim(result.stdout)
    end
    notify(err ~= '' and err or 'Failed to send PR to NPRD Internal', vim.log.levels.ERROR)
  end))
end

return M
