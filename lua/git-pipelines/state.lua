local M = {}

---@return GitPipelinesState
function M.new()
  return {
    items = {},
    counts = {
      total = 0,
      passing = 0,
      pending = 0,
      failing = 0,
      missing = 0,
    },
    enabled = true,
    loading = false,
    inflight = false,
    pending_refresh = false,
    last_sync = nil,
    error = nil,
    generation = 0,
    timer = nil,
  }
end

---@param state GitPipelinesState
function M.recompute_counts(state)
  local counts = {
    total = #state.items,
    passing = 0,
    pending = 0,
    failing = 0,
    missing = 0,
  }

  for _, item in ipairs(state.items) do
    if item.summary_state == 'pass' then
      counts.passing = counts.passing + 1
    elseif item.summary_state == 'pending' then
      counts.pending = counts.pending + 1
    elseif item.summary_state == 'fail' then
      counts.failing = counts.failing + 1
    else
      counts.missing = counts.missing + 1
    end
  end

  state.counts = counts
end

---@param state GitPipelinesState
---@return GitPipelinesState
function M.snapshot(state)
  return {
    items = vim.deepcopy(state.items),
    counts = vim.deepcopy(state.counts),
    enabled = state.enabled,
    loading = state.loading,
    inflight = state.inflight,
    pending_refresh = state.pending_refresh,
    last_sync = state.last_sync,
    error = state.error,
    generation = state.generation,
    timer = state.timer,
  }
end

return M
