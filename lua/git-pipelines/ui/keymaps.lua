local M = {}

---@param ui GitPipelinesUiState
---@return GitPipelinesLineMeta|nil
local function current_meta(ui)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return ui.line_meta[line]
end

---@param buf integer
---@param params table
function M.setup(buf, params)
  local ui = params.ui
  local open_url = params.open_url
  local on_refresh = params.on_refresh
  local on_send_prs = params.on_send_prs
  local on_summarize_failed_log = params.on_summarize_failed_log
  local on_rerun_failed_workflow = params.on_rerun_failed_workflow
  local selected_in_state_order = params.selected_in_state_order
  local toggle_selected = params.toggle_selected
  local update_pr_line = params.update_pr_line

  local map_opts = function(desc)
    return { buffer = buf, silent = true, desc = desc }
  end

  local close_window = function()
    if ui.win and vim.api.nvim_win_is_valid(ui.win) then
      vim.api.nvim_win_close(ui.win, true)
    end
  end

  local open_current_url = function()
    local meta = current_meta(ui)
    if meta and meta.url then
      open_url(meta.url)
    end
  end

  vim.keymap.set('n', 'q', close_window, map_opts('Close git pipelines window'))
  vim.keymap.set('n', '<Esc>', close_window, map_opts('Close git pipelines window'))

  vim.keymap.set('n', 'r', function()
    on_refresh()
  end, map_opts('Refresh git pipelines'))

  vim.keymap.set('n', 'o', open_current_url, map_opts('Open selected pipeline URL'))
  vim.keymap.set('n', '<CR>', open_current_url, map_opts('Open selected pipeline URL'))

  vim.keymap.set('n', 'L', function()
    local meta = current_meta(ui)
    if on_summarize_failed_log then
      on_summarize_failed_log(meta and meta.pr, meta and meta.workflow)
    end
  end, map_opts('Summarize full failed workflow log with CodeCompanion'))

  vim.keymap.set('n', 'R', function()
    local meta = current_meta(ui)
    if on_rerun_failed_workflow then
      on_rerun_failed_workflow(meta and meta.pr, meta and meta.workflow)
    end
  end, map_opts('Rerun failed workflow'))

  vim.keymap.set('n', 'n', function()
    local meta = current_meta(ui)
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
    local meta = current_meta(ui)
    if meta and meta.pr then
      toggle_selected(meta.pr)
      update_pr_line(meta.pr)
    end
  end, map_opts('Toggle PR selection'))
end

return M
