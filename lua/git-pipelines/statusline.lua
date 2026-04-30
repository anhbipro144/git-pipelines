local M = {}

---@param state GitPipelinesState
---@param icon_for fun(kind: GitPipelinesSummaryState|string): string
---@return string
function M.render(state, icon_for)
  if not state.enabled then
    return string.format('CI %s', icon_for 'disabled')
  end

  if state.loading and state.last_sync == nil then
    return string.format('CI %s', icon_for 'pending')
  end

  if state.error and state.last_sync == nil then
    return 'CI ?'
  end

  local counts = state.counts
  if counts.total == 0 then
    return 'PRs 0'
  end

  local chunks = {
    string.format('PRs %d', counts.total),
  }

  if counts.passing > 0 then
    table.insert(chunks, string.format('%s%d', icon_for 'pass', counts.passing))
  end
  if counts.pending > 0 then
    table.insert(chunks, string.format('%s%d', icon_for 'pending', counts.pending))
  end
  if counts.failing > 0 then
    table.insert(chunks, string.format('%s%d', icon_for 'fail', counts.failing))
  end
  if counts.missing > 0 and counts.passing == 0 and counts.pending == 0 and counts.failing == 0 then
    table.insert(chunks, string.format('%s%d', icon_for 'missing', counts.missing))
  end
  if state.loading then
    table.insert(chunks, icon_for 'pending')
  end
  if state.error then
    table.insert(chunks, '?')
  end

  return table.concat(chunks, ' ')
end

---@param opts GitPipelinesConfig
function M.install_default(opts)
  if not opts.install_default_statusline then
    return
  end

  if vim.o.statusline ~= '' then
    return
  end

  vim.o.statusline = table.concat({
    ' %<%f %h%m%r',
    '%=',
    ' %{v:lua.GitPipelines.statusline()}',
    '  %y %p%% %l:%c ',
  })
end

return M
