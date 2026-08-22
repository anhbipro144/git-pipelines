local keymaps = require 'git-pipelines.ui.keymaps'
local model = require 'git-pipelines.ui.model'

local M = {}

local namespace = vim.api.nvim_create_namespace('git-pipelines')

---@class GitPipelinesUiParams
---@field opts GitPipelinesConfig
---@field state GitPipelinesState
---@field icon_for fun(kind: GitPipelinesSummaryState|string): string
---@field shorten fun(text: unknown, max_width: integer): string
---@field on_refresh fun()
---@field on_send_prs fun(prs: GitPipelinesItem[]|GitPipelinesItem|nil)|nil
---@field on_request_copilot_review fun(pr: GitPipelinesItem|nil)|nil
---@field on_show_copilot_review_comments fun(pr: GitPipelinesItem|nil)|nil
---@field on_show_failed_workflow_log fun(pr: GitPipelinesItem|nil, workflow: GitPipelinesWorkflow|nil)|nil
---@field on_rerun_failed_workflow fun(pr: GitPipelinesItem|nil, workflow: GitPipelinesWorkflow|nil)|nil

local function define_highlights()
  vim.api.nvim_set_hl(0, 'GitPipelinesTitle', { default = true, link = 'Title' })
  vim.api.nvim_set_hl(0, 'GitPipelinesSeparator', { default = true, link = 'Comment' })
  vim.api.nvim_set_hl(0, 'GitPipelinesHeader', { default = true, link = 'Function' })
  vim.api.nvim_set_hl(0, 'GitPipelinesSummary', { default = true, link = 'Normal' })
  vim.api.nvim_set_hl(0, 'GitPipelinesPass', { default = true, link = 'DiagnosticOk' })
  vim.api.nvim_set_hl(0, 'GitPipelinesPending', { default = true, link = 'DiagnosticWarn' })
  vim.api.nvim_set_hl(0, 'GitPipelinesFail', { default = true, link = 'DiagnosticError' })
  vim.api.nvim_set_hl(0, 'GitPipelinesError', { default = true, link = 'DiagnosticError' })
  vim.api.nvim_set_hl(0, 'GitPipelinesMuted', { default = true, link = 'Normal' })
end

---@param url string|nil
local function open_url(url)
  if not url or url == '' then
    return
  end

  if vim.ui and vim.ui.open then
    vim.ui.open(url)
    return
  end

  vim.fn.jobstart({ 'xdg-open', url }, { detach = true })
end

---@param params GitPipelinesUiParams
---@return GitPipelinesUi
function M.new(params)
  local opts = params.opts
  local state = params.state
  local icon_for = params.icon_for
  local shorten = params.shorten

  ---@type GitPipelinesUiState
  local ui = {
    buf = nil,
    win = nil,
    line_meta = {},
    pr_lines = {},
    resize_autocmd = nil,
  }

  ---@type table<string, GitPipelinesItem>
  local selected_prs = {}

  local self = {}

  ---@param item GitPipelinesItem
  ---@return boolean
  local function is_selected(item)
    return selected_prs[model.pr_key(item)] ~= nil
  end

  ---@param item GitPipelinesItem
  local function toggle_selected(item)
    local key = model.pr_key(item)
    if selected_prs[key] then
      selected_prs[key] = nil
    else
      selected_prs[key] = item
    end
  end

  ---@return GitPipelinesItem[]
  local function selected_in_state_order()
    local prs = {}
    for _, item in ipairs(state.items) do
      if is_selected(item) then
        table.insert(prs, item)
      end
    end

    return prs
  end

  local function prune_selected()
    local active = {}
    for _, item in ipairs(state.items) do
      active[model.pr_key(item)] = true
    end

    for key in pairs(selected_prs) do
      if not active[key] then
        selected_prs[key] = nil
      end
    end
  end

  ---@return integer
  local function create_buffer()
    if ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
      return ui.buf
    end

    local buf = vim.api.nvim_create_buf(false, true)
    ui.buf = buf

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'git-pipelines'
    vim.bo[buf].modifiable = false

    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        if ui.resize_autocmd then
          pcall(vim.api.nvim_del_autocmd, ui.resize_autocmd)
        end

        ui.buf = nil
        ui.win = nil
        ui.line_meta = {}
        ui.pr_lines = {}
        ui.resize_autocmd = nil
      end,
    })

    return buf
  end

  ---@param lines string[]
  ---@return table
  local function window_config(lines)
    local width = 60
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
    end

    local max_width = math.floor(vim.o.columns * opts.float.width)
    local max_height = math.floor(vim.o.lines * opts.float.height)
    width = math.min(width, max_width)
    local height = math.min(#lines, max_height)

    return {
      relative = 'editor',
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(1, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      border = opts.float.border,
      style = 'minimal',
      title = opts.float.title,
      title_pos = 'center',
    }
  end

  ---@param buf integer
  ---@param lines string[]
  local function open_window(buf, lines)
    local config = window_config(lines)

    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      vim.api.nvim_win_set_config(ui.win, config)
    else
      ui.win = vim.api.nvim_open_win(buf, true, config)
    end

    vim.wo[ui.win].cursorline = true
    vim.wo[ui.win].winfixbuf = true
    vim.wo[ui.win].wrap = false

    if not ui.resize_autocmd then
      ui.resize_autocmd = vim.api.nvim_create_autocmd('VimResized', {
        callback = function()
          self.schedule_render()
        end,
      })
    end
  end

  ---@param buf integer
  ---@param rows GitPipelinesUiRow[]
  local function apply_highlights(buf, rows)
    define_highlights()
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

    for index, item in ipairs(rows) do
      if item.highlight and item.text ~= '' then
        vim.api.nvim_buf_add_highlight(buf, namespace, item.highlight, index - 1, 0, -1)
      end
    end
  end

  ---@param buf integer
  local function setup_keymaps(buf)
    keymaps.setup(buf, {
      ui = ui,
      open_url = open_url,
      on_refresh = params.on_refresh,
      on_send_prs = params.on_send_prs,
      on_request_copilot_review = params.on_request_copilot_review,
      on_show_copilot_review_comments = params.on_show_copilot_review_comments,
      on_show_failed_workflow_log = params.on_show_failed_workflow_log,
      on_rerun_failed_workflow = params.on_rerun_failed_workflow,
      selected_in_state_order = selected_in_state_order,
      toggle_selected = toggle_selected,
      update_pr_line = function(item)
        self.update_pr_line(item)
      end,
    })
  end

  function self.schedule_render()
    if ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
      vim.schedule(function()
        if ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
          self.render_float()
        end
      end)
    end
  end

  ---@param item GitPipelinesItem
  function self.update_pr_line(item)
    if not ui.buf or not vim.api.nvim_buf_is_valid(ui.buf) then
      self.schedule_render()
      return
    end

    local line = ui.pr_lines[model.pr_key(item)]
    if not line then
      self.schedule_render()
      return
    end

    vim.bo[ui.buf].modifiable = true
    vim.api.nvim_buf_set_lines(ui.buf, line - 1, line, false,
      { model.pr_header(item, is_selected(item), icon_for, shorten) })
    vim.bo[ui.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(ui.buf, namespace, line - 1, line)
    vim.api.nvim_buf_add_highlight(ui.buf, namespace, model.item_highlight(item), line - 1, 0, -1)
    vim.cmd.redraw()
  end

  function self.render_float()
    local needs_keymaps = not (ui.buf and vim.api.nvim_buf_is_valid(ui.buf))
    local buf = create_buffer()
    if needs_keymaps then
      setup_keymaps(buf)
    end

    prune_selected()
    local rows = model.build({
      opts = opts,
      state = state,
      icon_for = icon_for,
      shorten = shorten,
      is_selected = is_selected,
    })

    local lines, line_meta, pr_lines = model.render_lines(rows)
    ui.line_meta = line_meta
    ui.pr_lines = pr_lines

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    apply_highlights(buf, rows)
    open_window(buf, lines)
  end

  function self.open()
    self.render_float()
  end

  return self
end

return M
