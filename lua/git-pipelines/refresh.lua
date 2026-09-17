local github = require 'git-pipelines.github'
local util = require 'git-pipelines.util'

local M = {}

---@param opts GitPipelinesConfig
---@return string[]
local function configured_reviewer_logins(opts)
  local config = opts.nprd_internal or {}
  local logins = {}
  local seen = {}

  local function add(login)
    login = util.trim(login)
    local key = string.lower(login)
    if login ~= '' and not seen[key] then
      seen[key] = true
      table.insert(logins, login)
    end
  end

  add(config.github_login)
  for _, reviewer in ipairs(config.reviewers or {}) do
    add(reviewer.github_login)
  end

  return logins
end

---@class GitPipelinesRefreshParams
---@field opts GitPipelinesConfig
---@field state GitPipelinesState
---@field redraw fun()
---@field recompute_counts fun()

---@param params GitPipelinesRefreshParams
---@return fun(force?: boolean)
function M.new(params)
  local opts = params.opts
  local state = params.state
  local redraw = params.redraw
  local recompute_counts = params.recompute_counts
  local reviewer_logins = configured_reviewer_logins(opts)
  local refresh

  ---@param success boolean
  ---@param err string|nil
  local function finish(success, err)
    state.inflight = false
    state.loading = false
    if success then
      state.error = nil
      state.last_sync = os.time()
    elseif err then
      state.error = err
    end

    redraw()

    if state.timer and not state.timer:is_closing() and state.enabled then
      local interval = opts.refresh_ms
      if state.counts.pending > 0 then
        interval = opts.refresh_pending_ms
      end
      state.timer:stop()
      state.timer:start(interval, 0, vim.schedule_wrap(function()
        refresh(false)
      end))
    end

    if state.pending_refresh then
      state.pending_refresh = false
      vim.schedule(function()
        refresh(true)
      end)
    end
  end

  ---@param force boolean|nil
  refresh = function(force)
    if not state.enabled and not force then
      return
    end

    if not util.has_gh() then
      state.error = 'gh CLI is not installed or not on $PATH'
      redraw()
      return
    end

    if state.inflight then
      state.pending_refresh = true
      return
    end

    state.inflight = true
    state.loading = true
    state.generation = state.generation + 1
    local generation = state.generation
    redraw()

    github.fetch_pull_requests(opts, function(items, err)
      if generation ~= state.generation then
        return
      end

      if err then
        finish(false, err)
        return
      end

      items = items or {}
      if vim.tbl_isempty(items) then
        state.items = {}
        recompute_counts()
        finish(true)
        return
      end

      local hydrated = {}
      local next_index = 1
      local active = 0

      local function maybe_finish()
        if next_index > #items and active == 0 then
          github.sort_items(hydrated)
          state.items = hydrated
          recompute_counts()
          finish(true)
        end
      end

      local function launch_more()
        while active < opts.concurrent_requests and next_index <= #items do
          local item = items[next_index]
          next_index = next_index + 1
          active = active + 1

          github.fetch_workflows_for_pr(item, function(pr_item)
            if generation ~= state.generation then
              return
            end

            github.fetch_reviewer_approval(pr_item, reviewer_logins, function(approved, approved_by, review_err)
              if generation ~= state.generation then
                return
              end

              pr_item.review_approved = approved
              pr_item.approved_by = approved_by
              if review_err then
                pr_item.review_error = review_err
              end

              active = active - 1
              table.insert(hydrated, pr_item)
              if active == 0 or #hydrated == #items then
                github.sort_items(hydrated)
                state.items = vim.deepcopy(hydrated)
                recompute_counts()
                redraw()
              end

              launch_more()
              maybe_finish()
            end)
          end)
        end
      end

      launch_more()
      maybe_finish()
    end)
  end

  return refresh
end

---@param state GitPipelinesState
---@param refresh fun(force?: boolean)
function M.start_timer(state, refresh)
  state.timer = vim.uv.new_timer()
  state.timer:start(0, 0, vim.schedule_wrap(function()
    refresh(false)
  end))
end

return M
