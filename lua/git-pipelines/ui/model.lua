local M = {}

---@param str string|nil
---@return integer|nil
local function parse_iso_date(str)
  if not str then
    return nil
  end

  local y, m, d, h, min, s = str:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z')
  if not y then
    return nil
  end

  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(min),
    sec = tonumber(s),
  })
end

---@param seconds integer
---@return string
local function format_duration(seconds)
  if seconds < 60 then
    return string.format('%ds', seconds)
  end

  if seconds < 3600 then
    return string.format('%dm %ds', math.floor(seconds / 60), seconds % 60)
  end

  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  return string.format('%dh %dm', h, m)
end

---@param repo string
---@return string
local function repo_display_name(repo)
  return repo:match('[^/]+$') or repo
end

---@param workflow GitPipelinesWorkflow
---@return string
local function workflow_duration(workflow)
  if not workflow.created_at or not workflow.updated_at then
    return ''
  end

  local started_at = parse_iso_date(workflow.created_at)
  local updated_at = parse_iso_date(workflow.updated_at)
  if not started_at or not updated_at or updated_at < started_at then
    return ''
  end

  return string.format(' (%s)', format_duration(updated_at - started_at))
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

---@param item GitPipelinesItem
---@return string
function M.pr_key(item)
  return string.format('%s#%s', item.repo or '', tostring(item.number or ''))
end

---@param item GitPipelinesItem
---@param selected boolean
---@param icon_for fun(kind: GitPipelinesSummaryState|string): string
---@param shorten fun(text: unknown, max_width: integer): string
---@return string
function M.pr_header(item, selected, icon_for, shorten)
  local checkbox = selected and '[x]' or '[ ]'
  return string.format('%s %s %s#%d %s', checkbox, icon_for(item.summary_state), repo_display_name(item.repo),
    item.number, shorten(item.title, 80))
end

---@param item GitPipelinesItem
---@return string
function M.item_highlight(item)
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
function M.workflow_highlight(workflow)
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

---@param params table
---@return GitPipelinesUiRow[]
function M.build(params)
  local opts = params.opts
  local state = params.state
  local icon_for = params.icon_for
  local shorten = params.shorten
  local is_selected = params.is_selected

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
    string.format('Tracked PRs: %d   %s%d   %s%d   %s%d', counts.total, icon_for 'pass', counts.passing,
      icon_for 'pending', counts.pending, icon_for 'fail', counts.failing), nil, 'GitPipelinesSummary'))

  if state.last_sync then
    table.insert(rows, row('Last sync: ' .. os.date('%Y-%m-%d %H:%M:%S', state.last_sync), nil, 'GitPipelinesMuted'))
  end

  if state.error then
    table.insert(rows, row('Error: ' .. shorten(state.error, 100), nil, 'GitPipelinesError'))
  end

  table.insert(rows, row(
    'Keys: <CR>/o open, R rerun failed, L summarize log, x select, n notify, N notify bullk, r refresh',
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
    local selected = is_selected and is_selected(item) or false
    table.insert(rows, row(M.pr_header(item, selected, icon_for, shorten), { url = item.url, kind = 'pr', pr = item },
      M.item_highlight(item)))

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
        local duration_str = workflow_duration(workflow)
        local name = shorten(workflow.name, math.max(1, 66 - #duration_str)) .. duration_str
        local workflow_line = string.format('    %s %-18s %s', icon_for(workflow.state), shorten(workflow.label, 18),
          name)

        table.insert(rows,
          row(workflow_line, { url = workflow.url, kind = 'workflow', pr = item, workflow = workflow },
            M.workflow_highlight(workflow)))
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
function M.render_lines(rows)
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
        pr_lines[M.pr_key(item.meta.pr)] = index
      end
    end
  end

  return lines, line_meta, pr_lines
end

return M
