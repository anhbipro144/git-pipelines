local defaults = require 'git-pipelines.defaults'
local github = require 'git-pipelines.github'
local ui_module = require 'git-pipelines.ui'
local util = require 'git-pipelines.util'

local M = {}

function M.setup(user_opts)
  if M._initialized then
    return
  end
  M._initialized = true

  local opts = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_opts or {})

  local state = {
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

  _G.GitPipelines = M

  local ui

  local function notify(message, level)
    if not opts.notify then
      return
    end

    vim.notify(message, level or vim.log.levels.INFO, { title = 'git-pipelines' })
  end

  local function icon_for(kind)
    return opts.icons[kind] or kind
  end

  local function recompute_counts()
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

  local function finish_refresh(success, err)
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
        M.refresh(false)
      end))
    end

    if state.pending_refresh then
      state.pending_refresh = false
      vim.schedule(function()
        M.refresh(true)
      end)
    end
  end

  function M.refresh(force)
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
        finish_refresh(false, err)
        return
      end

      items = items or {}
      if vim.tbl_isempty(items) then
        state.items = {}
        recompute_counts()
        finish_refresh(true)
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
          finish_refresh(true)
        end
      end

      local function launch_more()
        while active < opts.concurrent_requests and next_index <= #items do
          local item = items[next_index]
          next_index = next_index + 1
          active = active + 1

          github.fetch_workflows_for_pr(item, function(pr_item)
            active = active - 1
            if generation ~= state.generation then
              return
            end

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
        end
      end

      launch_more()
      maybe_finish()
    end)
  end

  function M.statusline()
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

  function M.render_float()
    ui.render_float()
  end

  function M.open()
    ui.open()
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

  function M.state()
    return vim.deepcopy(state)
  end

  local function install_default_statusline()
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

  local function setup_commands()
    vim.api.nvim_create_user_command('GitPipelines', function()
      M.open()
    end, { desc = 'Open Git pipelines window' })

    vim.api.nvim_create_user_command('GitPipelinesOpen', function()
      M.open()
    end, { desc = 'Open Git pipelines window' })

    vim.api.nvim_create_user_command('GitPipelinesRefresh', function()
      M.refresh(true)
    end, { desc = 'Refresh Git pipelines now' })

    vim.api.nvim_create_user_command('GitPipelinesToggle', function()
      M.toggle()
    end, { desc = 'Toggle Git pipelines polling' })

    vim.api.nvim_create_user_command('GitPipelinesEnable', function()
      M.enable()
    end, { desc = 'Enable Git pipelines polling' })

    vim.api.nvim_create_user_command('GitPipelinesDisable', function()
      M.disable()
    end, { desc = 'Disable Git pipelines polling' })
  end

  local function setup_autocmds()
    vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
      callback = function()
        if not state.enabled or state.inflight then
          return
        end

        if not state.last_sync or os.time() - state.last_sync > 15 then
          M.refresh(false)
        end
      end,
    })
  end

  local function setup_timer()
    state.timer = vim.uv.new_timer()
    state.timer:start(0, 0, vim.schedule_wrap(function()
      M.refresh(false)
    end))
  end

  ui = ui_module.new {
    opts = opts,
    state = state,
    icon_for = icon_for,
    shorten = util.shorten,
    on_refresh = function()
      M.refresh(true)
    end,
  }

  install_default_statusline()
  setup_commands()
  setup_autocmds()
  setup_timer()
end

return M
