local util = require 'git-pipelines.util'

local M = {}

---@alias GitPipelinesJsonCallback fun(payload: table|nil, err: string|nil)

---@param message string
local function log_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = 'git-pipelines' })
end

---@param cmd string[]
---@return string
local function format_command(cmd)
  return table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ')
end

---@param cmd string[]
---@param result vim.SystemCompleted
---@return string
local function command_error(cmd, result)
  local stderr = util.trim(result.stderr)
  local stdout = util.trim(result.stdout)
  local code = result.code == nil and 'unknown' or tostring(result.code)

  if stderr ~= '' then
    return string.format('%s\nExit code: %s\nCommand: %s', stderr, code, format_command(cmd))
  end

  if stdout ~= '' then
    return string.format('%s\nExit code: %s\nCommand: %s', stdout, code, format_command(cmd))
  end

  return string.format('GitHub request failed with exit code %s\nCommand: %s', code, format_command(cmd))
end

local search_query = [[
query($searchQuery: String!, $limit: Int!, $cursor: String) {
  search(query: $searchQuery, type: ISSUE, first: $limit, after: $cursor) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        number
        title
        url
        updatedAt
        isDraft
        headRefOid
        headRefName
        repository {
          nameWithOwner
        }
      }
    }
  }
}
]]

---@param item GitPipelinesItem
---@return string
local function repo_key(item)
  return string.format('%s#%s', item.repo, item.number)
end

---@param value unknown
---@param list unknown[]|nil
---@return boolean
local function value_in_list(value, list)
  if value == nil or value == '' then
    return false
  end

  for _, candidate in ipairs(list or {}) do
    if candidate == value then
      return true
    end
  end

  return false
end

---@param value string|nil
---@param patterns string[]|nil
---@return boolean
local function matches_pattern_list(value, patterns)
  if value == nil or value == '' then
    return false
  end

  for _, pattern in ipairs(patterns or {}) do
    if type(pattern) == 'string' and pattern ~= '' then
      local ok, matched = pcall(function()
        return value:match(pattern) ~= nil
      end)
      if ok and matched then
        return true
      end
    end
  end

  return false
end

---@param item GitPipelinesItem
---@param blacklist GitPipelinesBlacklist|nil
---@return boolean
local function is_blacklisted(item, blacklist)
  blacklist = blacklist or {}
  local full_pr = repo_key(item)

  if value_in_list(full_pr, blacklist.prs) then
    return true
  end

  if value_in_list(item.number, blacklist.prs) or value_in_list(tostring(item.number), blacklist.prs) then
    return true
  end

  if value_in_list(item.repo, blacklist.repos) then
    return true
  end

  if matches_pattern_list(item.title, blacklist.title_patterns) then
    return true
  end

  if matches_pattern_list(item.head_ref_name or '', blacklist.branch_patterns) then
    return true
  end

  return false
end

---@param summary_state GitPipelinesSummaryState|nil
---@return integer
local function summary_rank(summary_state)
  local ranks = {
    fail = 1,
    pending = 2,
    missing = 3,
    unknown = 4,
    pass = 5,
  }

  return ranks[summary_state] or 99
end

---@param workflow_state GitPipelinesWorkflowState|nil
---@return integer
local function workflow_rank(workflow_state)
  local ranks = {
    fail = 1,
    pending = 2,
    pass = 3,
    unknown = 4,
  }

  return ranks[workflow_state] or 99
end

---@param run table
---@return GitPipelinesWorkflowState
local function workflow_state(run)
  if run.status and run.status ~= 'completed' then
    return 'pending'
  end

  local conclusion = run.conclusion
  if conclusion == 'success' or conclusion == 'neutral' or conclusion == 'skipped' then
    return 'pass'
  end

  if conclusion == 'failure'
      or conclusion == 'timed_out'
      or conclusion == 'cancelled'
      or conclusion == 'action_required'
      or conclusion == 'startup_failure'
      or conclusion == 'stale'
  then
    return 'fail'
  end

  return 'unknown'
end

---@param run table
---@return string
local function workflow_label(run)
  if run.status and run.status ~= 'completed' then
    return run.status
  end

  return run.conclusion or run.status or 'unknown'
end

---@param item GitPipelinesItem
local function summarize_workflows(item)
  local pending = 0
  local passing = 0
  local failing = 0

  for _, workflow in ipairs(item.workflows) do
    if workflow.state == 'pending' then
      pending = pending + 1
    elseif workflow.state == 'fail' then
      failing = failing + 1
    elseif workflow.state == 'pass' then
      passing = passing + 1
    end
  end

  item.pending_count = pending
  item.passing_count = passing
  item.failing_count = failing

  if failing > 0 then
    item.summary_state = 'fail'
  elseif pending > 0 then
    item.summary_state = 'pending'
  elseif passing > 0 then
    item.summary_state = 'pass'
  else
    item.summary_state = 'missing'
  end
end

---@param cmd string[]
---@param cb GitPipelinesJsonCallback
local function json_command(cmd, cb)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      local err = command_error(cmd, result)
      log_error(err)
      cb(nil, err)
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok then
      local err = 'Failed to decode JSON from gh: ' .. tostring(decoded)
      log_error(err)
      cb(nil, err)
      return
    end

    cb(decoded, nil)
  end))
end

---@param cmd string[]
---@param cb fun(output: string|nil, err: string|nil)
local function text_command(cmd, cb)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      local err = command_error(cmd, result)
      log_error(err)
      cb(nil, err)
      return
    end

    cb(result.stdout or '', nil)
  end))
end

---@param search_term string
---@param cursor string|nil
---@param limit integer
---@param cb fun(items: GitPipelinesItem[]|nil, page_info: table|nil, err: string|nil)
local function graphql_page(search_term, cursor, limit, cb)
  local cmd = {
    'gh',
    'api',
    'graphql',
    '-f',
    'query=' .. search_query,
    '-F',
    'searchQuery=' .. search_term,
    '-F',
    'limit=' .. tostring(limit),
  }

  if cursor then
    table.insert(cmd, '-F')
    table.insert(cmd, 'cursor=' .. cursor)
  end

  json_command(cmd, function(payload, err)
    if err then
      cb(nil, nil, err)
      return
    end

    local search = payload and payload.data and payload.data.search
    if not search then
      cb(nil, nil, 'Missing search data from GitHub')
      return
    end

    local page = {}
    for _, node in ipairs(search.nodes or {}) do
      if node.repository and node.repository.nameWithOwner and node.headRefOid then
        table.insert(page, {
          repo = node.repository.nameWithOwner,
          number = node.number,
          title = node.title,
          url = node.url,
          updated_at = node.updatedAt,
          is_draft = node.isDraft,
          head_sha = node.headRefOid,
          head_ref_name = node.headRefName,
          workflows = {},
        })
      end
    end

    local page_info = search.pageInfo or {}
    cb(page, page_info, nil)
  end)
end

---@param opts GitPipelinesConfig
---@param cb fun(items: GitPipelinesItem[]|nil, err: string|nil)
function M.fetch_pull_requests(opts, cb)
  local seen = {}
  local out = {}
  local queries = vim.deepcopy(opts.search_queries or {})

  if vim.tbl_isempty(queries) then
    queries = { 'is:pr is:open author:@me archived:false' }
  end

  local function consume_query(index)
    local search_term = queries[index]
    if not search_term or #out >= opts.pr_limit then
      cb(out, nil)
      return
    end

    local function consume_page(cursor)
      local remaining = opts.pr_limit - #out
      if remaining <= 0 then
        cb(out, nil)
        return
      end

      graphql_page(search_term, cursor, math.min(opts.page_size, remaining), function(items, page_info, err)
        if err then
          cb(nil, err)
          return
        end

        for _, item in ipairs(items or {}) do
          local key = repo_key(item)
          if not seen[key] and not is_blacklisted(item, opts.blacklist) then
            seen[key] = true
            table.insert(out, item)
          end
        end

        if page_info and page_info.hasNextPage and #out < opts.pr_limit then
          consume_page(page_info.endCursor)
          return
        end

        consume_query(index + 1)
      end)
    end

    consume_page(nil)
  end

  consume_query(1)
end

---@param item GitPipelinesItem
---@param cb fun(item: GitPipelinesItem)
function M.fetch_workflows_for_pr(item, cb)
  local endpoint = string.format('repos/%s/actions/runs', item.repo)
  json_command({
    'gh',
    'api',
    '--method',
    'GET',
    '-H',
    'Accept: application/vnd.github+json',
    endpoint,
    '-f',
    'head_sha=' .. item.head_sha,
    '-f',
    'per_page=100',
  }, function(payload, err)
    if err then
      item.summary_state = 'unknown'
      item.fetch_error = err
      cb(item)
      return
    end

    local workflows = {}
    local seen = {}

    local runs = (payload and payload.workflow_runs) or {}
    for _, run in ipairs(runs) do
      local key = tostring(run.workflow_id or '')
      if key == '' then
        key = string.format('%s|%s', run.path or '', run.name or '')
      end

      if not seen[key] then
        seen[key] = true
        table.insert(workflows, {
          id = run.id,
          name = run.name or 'workflow',
          event = run.event,
          status = run.status,
          conclusion = run.conclusion,
          url = run.html_url,
          path = run.path,
          state = workflow_state(run),
          label = workflow_label(run),
          updated_at = run.updated_at,
          created_at = run.created_at,
        })
      end
    end

    item.workflows = workflows
    summarize_workflows(item)
    cb(item)
  end)
end

---@param repo string
---@param workflow GitPipelinesWorkflow
---@param cb fun(log: string|nil, err: string|nil)
function M.fetch_failed_workflow_log_raw(repo, workflow, cb)
  if not workflow or workflow.state ~= 'fail' then
    cb(nil, 'Workflow under cursor is not failed')
    return
  end

  if not workflow.id then
    cb(nil, 'Workflow run id is missing')
    return
  end

  local run_id = vim.fn.shellescape(tostring(workflow.id))
  local repo_arg = vim.fn.shellescape(repo)
  local command = string.format([[
job_ids=$(gh run view %s --repo %s --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .databaseId') || exit $?
if [ -z "$job_ids" ]; then
  exit 0
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/git-pipelines.XXXXXX") || exit $?
trap 'rm -f "$tmp"' EXIT

for job_id in $job_ids; do
  gh run view --job "$job_id" --repo %s --log > "$tmp" || exit $?
  awk '
      /Summary of all failing tests/ { found = 1; next }
      /Some files do not gain 80%% Coverage of Unit Test, please check the following list/ { found = 1; print; next }
      found && /Post job cleanup/ { exit }
      found && /Cleaning up orphan processes/ { exit }
      found
    ' "$tmp" |
    rg -n -C 40 'FAIL|AssertionError|Expected:|Received:|::error|Error:|TypeError:|ReferenceError:|Process completed with exit code|Some files do not gain 80%% Coverage of Unit Test, please check the following list'
  rg_status=$?
  if [ "$rg_status" -ne 0 ] && [ "$rg_status" -ne 1 ]; then
    exit "$rg_status"
  fi
done
]], run_id, repo_arg, repo_arg)

  text_command({ 'bash', '-lc', command }, function(output, err)
    if err then
      cb(nil, err)
      return
    end

    cb(output or '', nil)
  end)
end

---@param repo string
---@param workflow GitPipelinesWorkflow
---@param opts GitPipelinesConfig
---@param cb fun(log: string|nil, err: string|nil)
function M.fetch_failed_workflow_log(repo, workflow, opts, cb)
  M.fetch_failed_workflow_log_raw(repo, workflow, function(output, err)
    if err then
      cb(nil, err)
      return
    end

    cb(output or '', nil)
  end)
end

---@param repo string
---@param workflow GitPipelinesWorkflow
---@param cb fun(err: string|nil)
function M.rerun_failed_workflow(repo, workflow, cb)
  if not workflow or workflow.state ~= 'fail' then
    cb('Workflow under cursor is not failed')
    return
  end

  if not workflow.id then
    cb('Workflow run id is missing')
    return
  end

  text_command({
    'gh',
    'run',
    'rerun',
    tostring(workflow.id),
    '--repo',
    repo,
    '--failed',
  }, function(_, err)
    cb(err)
  end)
end

---@param pr GitPipelinesItem|nil
---@param cb fun(err: string|nil)
function M.request_copilot_review(pr, cb)
  if not pr then
    cb('No pull request selected')
    return
  end

  if util.trim(pr.repo) == '' or not pr.number then
    cb('Selected pull request is missing its repository or number')
    return
  end

  text_command({
    'gh',
    'api',
    '--method',
    'POST',
    '-H',
    'Accept: application/vnd.github+json',
    string.format('repos/%s/pulls/%s/requested_reviewers', pr.repo, tostring(pr.number)),
    '-f',
    'reviewers[]=copilot-pull-request-reviewer[bot]',
  }, function(_, err)
    cb(err)
  end)
end

---@param items GitPipelinesItem[]
function M.sort_items(items)
  table.sort(items, function(a, b)
    local a_rank = summary_rank(a.summary_state)
    local b_rank = summary_rank(b.summary_state)
    if a_rank ~= b_rank then
      return a_rank < b_rank
    end

    return (a.updated_at or '') > (b.updated_at or '')
  end)

  for _, item in ipairs(items) do
    table.sort(item.workflows, function(a, b)
      local a_rank = workflow_rank(a.state)
      local b_rank = workflow_rank(b.state)
      if a_rank ~= b_rank then
        return a_rank < b_rank
      end

      return (a.updated_at or '') > (b.updated_at or '')
    end)
  end
end

return M
