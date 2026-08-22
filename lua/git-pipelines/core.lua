local autocmds = require 'git-pipelines.autocmds'
local commands = require 'git-pipelines.commands'
local defaults = require 'git-pipelines.defaults'
local github = require 'git-pipelines.github'
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
---@field send_to_nprd? fun(prs: GitPipelinesItem|GitPipelinesItem[]|nil)
---@field request_copilot_review? fun(pr: GitPipelinesItem|nil)
---@field show_copilot_review_comments? fun(pr: GitPipelinesItem|nil)
---@field show_failed_workflow_log? fun(pr: GitPipelinesItem|nil, workflow: GitPipelinesWorkflow|nil)
---@field rerun_failed_workflow? fun(pr: GitPipelinesItem|nil, workflow: GitPipelinesWorkflow|nil)
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

  ---@param prs GitPipelinesItem|GitPipelinesItem[]|nil
  function M.send_to_nprd(prs)
    nprd.send(prs, opts, notify)
  end

  ---@param pr GitPipelinesItem|nil
  function M.request_copilot_review(pr)
    if not pr then
      notify('Put cursor on a pull request row', vim.log.levels.WARN)
      return
    end

    notify('Requesting Copilot review…')
    github.request_copilot_review(pr, function(err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      notify(string.format('Requested Copilot review for %s#%s', pr.repo, tostring(pr.number)))
    end)
  end

  ---@param pr GitPipelinesItem|nil
  function M.show_copilot_review_comments(pr)
    if not pr then
      notify('Put cursor on a pull request row', vim.log.levels.WARN)
      return
    end

    notify('Fetching Copilot review comments…')
    github.fetch_copilot_review_comments(pr, function(comments, err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end
      if not comments or #comments == 0 then
        notify(string.format('No Copilot review comments found for %s#%s', pr.repo, tostring(pr.number)))
        return
      end

      local lines = { string.format('Copilot review comments — %s#%s', pr.repo, tostring(pr.number)), '' }
      for index, comment in ipairs(comments) do
        local line = comment.line or comment.original_line
        local location = comment.path or 'general comment'
        if line then
          location = string.format('%s:%s', location, tostring(line))
        end
        table.insert(lines, string.format('%d. %s', index, location))
        vim.list_extend(lines, vim.split(comment.body, '\n', { plain = true }))
        if comment.html_url then
          table.insert(lines, comment.html_url)
        end
        table.insert(lines, '')
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'git-pipelines-copilot-review'
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false

      local width = math.min(math.max(60, vim.o.columns - 8), 110)
      local height = math.min(#lines, math.max(8, vim.o.lines - 6))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(1, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        border = opts.float.border,
        style = 'minimal',
        title = ' Copilot Review ',
        title_pos = 'center',
      })
      vim.wo[win].wrap = true
      vim.wo[win].cursorline = true
      for _, lhs in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', lhs, function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end, { buffer = buf, silent = true, desc = 'Close Copilot review comments' })
      end
    end)
  end

  ---@param pr GitPipelinesItem|nil
  ---@param workflow GitPipelinesWorkflow|nil
  function M.show_failed_workflow_log(pr, workflow)
    if not pr or not workflow then
      notify('Put cursor on a failed workflow row', vim.log.levels.WARN)
      return
    end

    notify('Fetching failed workflow log…')
    github.fetch_failed_workflow_log_raw(pr.repo, workflow, function(log, err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local lines = {
        string.format('Failed workflow log — %s#%s', pr.repo, tostring(pr.number)),
        string.format('Workflow: %s', workflow.name or 'workflow'),
        string.format('Run id: %s', tostring(workflow.id)),
        '',
      }
      vim.list_extend(lines, vim.split(log or '', '\n', { plain = true }))

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'git-pipelines-workflow-log'
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false

      local width = math.min(math.max(60, vim.o.columns - 8), 140)
      local height = math.min(#lines, math.max(8, vim.o.lines - 6))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(1, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        border = opts.float.border,
        style = 'minimal',
        title = ' Failed Workflow Log ',
        title_pos = 'center',
      })
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = true
      for _, lhs in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', lhs, function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end, { buffer = buf, silent = true, desc = 'Close failed workflow log' })
      end
    end)
  end

  ---@deprecated Use show_failed_workflow_log instead.
  M.summarize_failed_log = M.show_failed_workflow_log

  ---@param pr GitPipelinesItem|nil
  ---@param workflow GitPipelinesWorkflow|nil
  function M.rerun_failed_workflow(pr, workflow)
    if not pr or not workflow then
      notify('Put cursor on a failed workflow row', vim.log.levels.WARN)
      return
    end

    notify('Requesting failed workflow rerun…')
    github.rerun_failed_workflow(pr.repo, workflow, function(err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      notify('Failed workflow rerun requested')
      M.refresh(true)
    end)
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
    on_send_prs = function(prs)
      M.send_to_nprd(prs)
    end,
    on_request_copilot_review = function(pr)
      M.request_copilot_review(pr)
    end,
    on_show_copilot_review_comments = function(pr)
      M.show_copilot_review_comments(pr)
    end,
    on_show_failed_workflow_log = function(pr, workflow)
      M.show_failed_workflow_log(pr, workflow)
    end,
    on_rerun_failed_workflow = function(pr, workflow)
      M.rerun_failed_workflow(pr, workflow)
    end,
  }

  statusline.install_default(opts)
  commands.setup(M)
  autocmds.setup(state, M.refresh)
  refresh_module.start_timer(state, M.refresh)
end

return M
