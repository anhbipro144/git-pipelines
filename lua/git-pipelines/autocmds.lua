local M = {}

---@param state GitPipelinesState
---@param refresh fun(force?: boolean)
function M.setup(state, refresh)
  vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
    callback = function()
      if not state.enabled or state.inflight then
        return
      end

      if not state.last_sync or os.time() - state.last_sync > 15 then
        refresh(false)
      end
    end,
  })
end

return M
