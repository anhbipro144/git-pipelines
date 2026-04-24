local M = {}

function M.new(params)
  local opts = params.opts
  local state = params.state
  local icon_for = params.icon_for
  local shorten = params.shorten
  local on_refresh = params.on_refresh

  local ui = {
    buf = nil,
    win = nil,
    line_meta = {},
  }

  local self = {}

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

  local function ensure_float_buffer()
    if ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
      return ui.buf
    end

    ui.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[ui.buf].buftype = 'nofile'
    vim.bo[ui.buf].bufhidden = 'wipe'
    vim.bo[ui.buf].swapfile = false
    vim.bo[ui.buf].filetype = 'git-pipelines'
    vim.bo[ui.buf].modifiable = false

    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = ui.buf,
      once = true,
      callback = function()
        ui.buf = nil
        ui.win = nil
        ui.line_meta = {}
      end,
    })

    vim.keymap.set('n', 'q', function()
      if ui.win and vim.api.nvim_win_is_valid(ui.win) then
        vim.api.nvim_win_close(ui.win, true)
      end
    end, { buffer = ui.buf, silent = true, desc = 'Close git pipelines window' })

    vim.keymap.set('n', '<Esc>', function()
      if ui.win and vim.api.nvim_win_is_valid(ui.win) then
        vim.api.nvim_win_close(ui.win, true)
      end
    end, { buffer = ui.buf, silent = true, desc = 'Close git pipelines window' })

    vim.keymap.set('n', 'r', function()
      on_refresh()
    end, { buffer = ui.buf, silent = true, desc = 'Refresh git pipelines' })

    vim.keymap.set('n', 'o', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if meta and meta.url then
        open_url(meta.url)
      end
    end, { buffer = ui.buf, silent = true, desc = 'Open selected pipeline URL' })

    vim.keymap.set('n', '<CR>', function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local meta = ui.line_meta[line]
      if meta and meta.url then
        open_url(meta.url)
      end
    end, { buffer = ui.buf, silent = true, desc = 'Open selected pipeline URL' })

    return ui.buf
  end

  local function build_lines()
    local lines = {}
    local line_meta = {}
    local counts = state.counts
    local title = opts.float.title
    if state.loading then
      title = opts.float.title .. ' refreshing '
    end

    table.insert(lines, title)
    table.insert(lines, string.rep('─', math.max(60, vim.fn.strdisplaywidth(title))))
    table.insert(lines,
      string.format('Tracked PRs: %d   %s%d   %s%d   %s%d', counts.total, icon_for 'pass', counts.passing,
        icon_for 'pending', counts.pending, icon_for 'fail', counts.failing))

    if state.last_sync then
      table.insert(lines, 'Last sync: ' .. os.date('%Y-%m-%d %H:%M:%S', state.last_sync))
    end
    if state.error then
      table.insert(lines, 'Error: ' .. shorten(state.error, 100))
    end

    table.insert(lines, 'Keys: <CR>/o open, r refresh, q close')
    table.insert(lines, '')

    if vim.tbl_isempty(state.items) then
      if state.loading then
        table.insert(lines, 'Fetching pull requests from GitHub…')
      else
        table.insert(lines, 'No matching pull requests found.')
      end

      return lines, line_meta
    end

    for _, item in ipairs(state.items) do
      local header = string.format('%s %s#%d %s', icon_for(item.summary_state), item.repo, item.number,
        shorten(item.title, 80))
      table.insert(lines, header)
      line_meta[#lines] = { url = item.url, kind = 'pr' }

      local summary = string.format('  workflows: %d   %s%d   %s%d   %s%d%s', #item.workflows, icon_for 'pass',
        item.passing_count or 0, icon_for 'pending', item.pending_count or 0, icon_for 'fail', item.failing_count or 0,
        item.is_draft and '   draft' or '')
      table.insert(lines, summary)

      if item.fetch_error then
        table.insert(lines, '  error: ' .. shorten(item.fetch_error, 92))
      elseif vim.tbl_isempty(item.workflows) then
        table.insert(lines, '  no workflow runs found for the current PR head SHA')
      else
        local limit = math.min(opts.max_workflows_per_pr, #item.workflows)
        for index = 1, limit do
          local workflow = item.workflows[index]
          local workflow_line = string.format('    %s %-18s %s', icon_for(workflow.state), shorten(workflow.label, 18),
            shorten(workflow.name, 66))
          table.insert(lines, workflow_line)
          line_meta[#lines] = { url = workflow.url, kind = 'workflow' }
        end

        if #item.workflows > limit then
          table.insert(lines, string.format('    … and %d more workflow(s)', #item.workflows - limit))
        end
      end

      table.insert(lines, '')
    end

    return lines, line_meta
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

  function self.render_float()
    local buf = ensure_float_buffer()
    local lines, line_meta = build_lines()
    ui.line_meta = line_meta

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local width = 60
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
    end

    local max_width = math.floor(vim.o.columns * opts.float.width)
    local max_height = math.floor(vim.o.lines * opts.float.height)
    width = math.min(width, max_width)
    local height = math.min(#lines, max_height)
    local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
    local col = math.max(1, math.floor((vim.o.columns - width) / 2))

    local win_config = {
      relative = 'editor',
      row = row,
      col = col,
      width = width,
      height = height,
      border = opts.float.border,
      style = 'minimal',
      title = opts.float.title,
      title_pos = 'center',
    }

    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      vim.api.nvim_win_set_config(ui.win, win_config)
    else
      ui.win = vim.api.nvim_open_win(buf, true, win_config)
    end

    vim.wo[ui.win].cursorline = true
    vim.wo[ui.win].winfixbuf = true
    vim.wo[ui.win].wrap = false
  end

  function self.open()
    self.render_float()
  end

  return self
end

return M
