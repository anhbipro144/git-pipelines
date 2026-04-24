return {
  search_queries = {
    'is:pr is:open author:@me archived:false',
  },
  blacklist = {
    prs = { 2296, 2341 },
    repos = {},
    title_patterns = {},
    branch_patterns = {},
  },
  pr_limit = 20,
  page_size = 20,
  concurrent_requests = 4,
  refresh_ms = 30000,
  refresh_pending_ms = 10000,
  max_workflows_per_pr = 10,
  install_default_statusline = false,
  notify = true,
  icons = {
    pass = '✓',
    fail = '✗',
    pending = '…',
    missing = '∅',
    disabled = '⏸',
  },
  float = {
    width = 0.8,
    height = 0.75,
    border = 'rounded',
    title = ' Git Pipelines ',
  },
}
