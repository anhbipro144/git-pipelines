local M = {}

local namespace = vim.api.nvim_create_namespace('git-pipelines')

---@class GitPipelinesUiRow
---@field text string
---@field meta GitPipelinesLineMeta|nil
---@field highlight string|nil

---@class GitPipelinesUiState
---@field buf integer|nil
---@field win integer|nil
---@field line_meta table<integer, GitPipelinesLineMeta>
---@field pr_lines table<string, integer>
---@field resize_autocmd integer|nil

---@class GitPipelinesUiParams
---@field opts GitPipelinesConfig
---@field state GitPipelinesState
---@field icon_for fun(kind: GitPipelinesSummaryState|string): string
---@field shorten fun(text: unknown, max_width: integer): string
---@field on_refresh fun()
---@field on_send_prs fun(prs: GitPipelinesItem[]|GitPipelinesItem|nil)|nil

---@param params GitPipelinesUiParams
---@return GitPipelinesUi
function M.new(params)
  local opts = params.opts
  local state = params.state
  local icon_for = params.icon_for
  local shorten = params.shorten
  local on_refresh = params.on_refresh
  local on_send_prs = params.on_send_prs

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

  ---@param repo string
  ---@return string
  local function repo_display_name(repo)
    return repo:match('[^/]+$') or repo
  end

  ---@param item GitPipelinesItem
  ---@return string
  local function pr_key(item)
    return string.format('%s#%s', item.repo or '', tostring(item.number or ''))
  end

  ---@param item GitPipelinesItem
  ---@return boolean
  local function is_selected(item)
    return selected_prs[pr_key(item)] ~= nil
  end

  ---@param item GitPipelinesItem
  local function toggle_selected(item)
    local key = pr_key(item)
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
      active[pr_key(item)] = true
    end

    for key in pairs(selected_prs) do
      if not active[key] then
        selected_prs[key] = nil
      end
    end
  end

  ---@param item GitPipelinesItem
  ---@return string
  local function pr_header(item)
    local selected = is_selected(item) and '[x]' or '[ ]'
    return string.format('%s %s %s#%d %s', selected, icon_for(item.summary_state), repo_display_name(item.repo),
      item.number, shorten(item.title, 80))
  end

  ---@param item GitPipelinesItem
  ---@return string
  local function item_highlight(item)
    if item.summary_state == 'pass' then
      return 'GitPipelinesPass'
    end
    if item.summary_state == 'pending' then
      return 'GitPipelinesPending'
    end
    if item.summary_state == 'fail' then
      return 'GitPipelinesFail'
    end

    return 'GitPipelinesHeader'
  end

  ---@param workflow GitPipelinesWorkflow
  ---@return string
  local function workflow_highlight(workflow)
    if workflow.state == 'pass' then
      return 'GitPipelinesPass'
    end
    if workflow.state == 'pending' then
      return 'GitPipelinesPending'
    end
    if workflow.state == 'fail' then
      return 'GitPipelinesFail'
    end

    return 'GitPipelinesMuted'
  end

  ---@param text string
  ---@param meta GitPipelinesLineMeta|nil
  ---@param highlight string|nil
  ---@return GitPipelinesUiRow
  local function row(text, meta, highlight)
    return {
      text = text,
      meta = meta,
      highlight = highlight,
    }
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

  ---@param buf integer
  local function setup_keymaps(buf)
    local map_opts = function(desc)
      return { buffer = buf, silent = true, desc = desc }
    end

    vim.keymap.set('n', 'q', function()
      if ui.win and vim.api.nvim_win_is_valid(ui.win) then
        vim.api.nvim_win_close(ui.win, true)
      end
    end, map_opts('Close git pipelines window'))

    vim.keymap.set('n', '<Esc>', function()
      if ui.win and vim.api.nvim_win_is_valid(ui.win) then
        vim.api.nvim_win_close(ui.win, true)
      end
    end, map_opts('Close git pipelines window'))

    vim.keymap.set('n', 'r', function()
      on_refresh()
    end, map_opts('Refresh git pipelines'))

    vim.keymap.set('n', 'o', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if meta and meta.url then
        open_url(meta.url)
      end
    end, map_opts('Open selected pipeline URL'))

    vim.keymap.set('n', '<CR>', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if meta and meta.url then
        open_url(meta.url)
      end
    end, map_opts('Open selected pipeline URL'))

    vim.keymap.set('n', 'n', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if on_send_prs then
        on_send_prs(meta and meta.pr)
      end
    end, map_opts('Send PR under cursor to NPRD Internal'))

    vim.keymap.set('n', 'N', function()
      if on_send_prs then
        on_send_prs(selected_in_state_order())
      end
    end, map_opts('Send selected PRs to NPRD Internal'))

    vim.keymap.set('n', 'x', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if meta and meta.pr then
        toggle_selected(meta.pr)
        self.update_pr_line(meta.pr)
      end
    end, map_opts('Toggle PR selection'))
  end

  ---@return GitPipelinesUiRow[]
  local function build_model()
    prune_selected()

    ---@type GitPipelinesUiRow[]
    local rows = {}
    local counts = state.counts
    local title = opts.float.title

    if state.loading then
      title = opts.float.title .. ' refreshing '
    end

    table.insert(rows, row(title, nil, 'GitPipelinesTitle'))
    table.insert(rows, row(string.rep('─', math.max(60, vim.fn.strdisplaywidth(title))), nil, 'GitPipelinesSeparator'))
    table.insert(rows, row(
      string.format('v1 Tracked PRs: %d   %s%d   %s%d   %s%d', counts.total, icon_for 'pass', counts.passing,
        icon_for 'pending', counts.pending, icon_for 'fail', counts.failing), nil, 'GitPipelinesSummary'))

    if state.last_sync then
      table.insert(rows, row('Last sync: ' .. os.date('%Y-%m-%d %H:%M:%S', state.last_sync), nil, 'GitPipelinesMuted'))
    end

    if state.error then
      table.insert(rows, row('Error: ' .. shorten(state.error, 100), nil, 'GitPipelinesError'))
    end

    table.insert(rows, row('Keys: <CR>/o open, x select, n notify cursor PR, N notify selected, r refresh, q close',
      nil, 'GitPipelinesMuted'))
    table.insert(rows, row('', nil, nil))

    if vim.tbl_isempty(state.items) then
      if state.loading then
        table.insert(rows, row('Fetching pull requests from GitHub…', nil, 'GitPipelinesMuted'))
      else
        table.insert(rows, row('No matching pull requests found.', nil, 'GitPipelinesMuted'))
      end

      return rows
    end

    for _, item in ipairs(state.items) do
      table.insert(rows, row(pr_header(item), { url = item.url, kind = 'pr', pr = item }, item_highlight(item)))

      local summary = string.format('  workflows: %d   %s%d   %s%d   %s%d%s', #item.workflows, icon_for 'pass',
        item.passing_count or 0, icon_for 'pending', item.pending_count or 0, icon_for 'fail', item.failing_count or 0,
        item.is_draft and '   draft' or '')
      table.insert(rows, row(summary, { kind = 'summary', pr = item }, 'GitPipelinesSummary'))

      if item.fetch_error then
        table.insert(rows,
          row('  error: ' .. shorten(item.fetch_error, 92), { kind = 'error', pr = item }, 'GitPipelinesError'))
      elseif vim.tbl_isempty(item.workflows) then
        table.insert(rows, row('  no workflow runs found for the current PR head SHA', { kind = 'empty', pr = item },
          'GitPipelinesMuted'))
      else
        local limit = math.min(opts.max_workflows_per_pr, #item.workflows)
        for index = 1, limit do
          local workflow = item.workflows[index]
          local workflow_line = string.format('    %s %-18s %s', icon_for(workflow.state), shorten(workflow.label, 18),
            shorten(workflow.name, 66))
          table.insert(rows, row(workflow_line, { url = workflow.url, kind = 'workflow', pr = item },
            workflow_highlight(workflow)))
        end

        if #item.workflows > limit then
          table.insert(rows, row(string.format('    … and %d more workflow(s)', #item.workflows - limit),
            { kind = 'overflow', pr = item }, 'GitPipelinesMuted'))
        end
      end

      table.insert(rows, row('', nil, nil))
    end

    return rows
  end

  ---@param rows GitPipelinesUiRow[]
  ---@return string[] lines
  ---@return table<integer, GitPipelinesLineMeta> line_meta
  ---@return table<string, integer> pr_lines
  local function render_lines(rows)
    ---@type string[]
    local lines = {}
    ---@type table<integer, GitPipelinesLineMeta>
    local line_meta = {}
    ---@type table<string, integer>
    local pr_lines = {}

    for index, item in ipairs(rows) do
      lines[index] = item.text
      if item.meta then
        line_meta[index] = item.meta

        if item.meta.kind == 'pr' and item.meta.pr then
          pr_lines[pr_key(item.meta.pr)] = index
        end
      end
    end

    return lines, line_meta, pr_lines
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

  ---@param lines string[]
  ---@return table
  local function resize_window(lines)
    local width = 60
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
    end

    local max_width = math.floor(vim.o.columns * opts.float.width)
    local max_height = math.floor(vim.o.lines * opts.float.height)
    width = math.min(width, max_width)
    local height = math.min(#lines, max_height)
    local row_pos = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
    local col = math.max(1, math.floor((vim.o.columns - width) / 2))

    return {
      relative = 'editor',
      row = row_pos,
      col = col,
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
    local win_config = resize_window(lines)

    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      vim.api.nvim_win_set_config(ui.win, win_config)
    else
      ui.win = vim.api.nvim_open_win(buf, true, win_config)
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

    local line = ui.pr_lines[pr_key(item)]
    if not line then
      self.schedule_render()
      return
    end

    vim.bo[ui.buf].modifiable = true
    vim.api.nvim_buf_set_lines(ui.buf, line - 1, line, false, { pr_header(item) })
    vim.bo[ui.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(ui.buf, namespace, line - 1, line)
    vim.api.nvim_buf_add_highlight(ui.buf, namespace, item_highlight(item), line - 1, 0, -1)
    vim.cmd.redraw()
  end

  function self.render_float()
    local needs_keymaps = not (ui.buf and vim.api.nvim_buf_is_valid(ui.buf))
    local buf = create_buffer()
    if needs_keymaps then
      setup_keymaps(buf)
    end

    local rows = build_model()
    local lines, line_meta, pr_lines = render_lines(rows)
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
