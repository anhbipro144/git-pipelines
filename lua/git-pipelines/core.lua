local autocmds = require 'git-pipelines.autocmds'
local commands = require 'git-pipelines.commands'
local defaults = require 'git-pipelines.defaults'
local nprd = require 'git-pipelines.nprd'
local refresh_module = require 'git-pipelines.refresh'
local state_module = require 'git-pipelines.state'
local statusline = require 'git-pipelines.statusline'
local ui_module = require 'git-pipelines.ui'
local util = require 'git-pipelines.util'

---@class GitPipelinesModule
---@field _initialized? boolean
---@field setup? fun(user_opts?: GitPipelinesUserConfig)
---@field refresh? fun(force?: boolean)
---@field statusline? fun(): string
---@field render_float? fun()
---@field open? fun()
---@field send_to_nprd? fun(pr: GitPipelinesItem|nil)
---@field enable? fun()
---@field disable? fun()
---@field toggle? fun()
---@field state? fun(): GitPipelinesState

---@type GitPipelinesModule
local M = {}

---@param user_opts GitPipelinesUserConfig|nil
function M.setup(user_opts)
  if M._initialized then
    return
  end
  M._initialized = true

  ---@type GitPipelinesConfig
  local opts = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_opts or {})
  local state = state_module.new()

  _G.GitPipelines = M

  ---@type GitPipelinesUi|nil
  local ui

  ---@param message string
  ---@param level integer|nil
  local function notify(message, level)
    if not opts.notify then
      return
    end

    vim.notify(message, level or vim.log.levels.INFO, { title = 'git-pipelines' })
  end

  ---@param kind GitPipelinesSummaryState|string
  ---@return string
  local function icon_for(kind)
    return opts.icons[kind] or kind
  end

  local function redraw()
    vim.cmd 'redrawstatus'

    local ok, incline = pcall(require, 'incline')
    if ok and type(incline.refresh) == 'function' then
      incline.refresh()
    end

    if ui then
      ui.schedule_render()
    end
  end

  local function recompute_counts()
    state_module.recompute_counts(state)
  end

  M.refresh = refresh_module.new {
    opts = opts,
    state = state,
    redraw = redraw,
    recompute_counts = recompute_counts,
  }

  function M.statusline()
    return statusline.render(state, icon_for)
  end

  function M.render_float()
    if not ui then
      return
    end

    ui.render_float()
  end

  function M.open()
    if not ui then
      return
    end

    ui.open()
  end

  ---@param pr GitPipelinesItem|nil
  function M.send_to_nprd(pr)
    nprd.send(pr, opts, notify)
  end

  function M.enable()
    if state.enabled then
      return
    end

    state.enabled = true
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
    end
    notify 'Git pipelines enabled'
    M.refresh(true)
  end

  function M.disable()
    state.enabled = false
    state.loading = false
    state.pending_refresh = false
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
    end
    redraw()
    notify 'Git pipelines disabled'
  end

  function M.toggle()
    if state.enabled then
      M.disable()
    else
      M.enable()
    end
  end

  ---@return GitPipelinesState
  function M.state()
    return state_module.snapshot(state)
  end

  ui = ui_module.new {
    opts = opts,
    state = state,
    icon_for = icon_for,
    shorten = util.shorten,
    on_refresh = function()
      M.refresh(true)
    end,
    on_send_pr = function(pr)
      M.send_to_nprd(pr)
    end,
  }

  statusline.install_default(opts)
  commands.setup(M)
  autocmds.setup(state, M.refresh)
  refresh_module.start_timer(state, M.refresh)
end

return M
