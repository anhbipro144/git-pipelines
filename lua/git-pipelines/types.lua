---@alias GitPipelinesSummaryState 'pass'|'pending'|'fail'|'missing'|'unknown'
---@alias GitPipelinesWorkflowState 'pass'|'pending'|'fail'|'unknown'

---@class GitPipelinesBlacklist
---@field prs? (integer|string)[]
---@field repos? string[]
---@field title_patterns? string[]
---@field branch_patterns? string[]

---@class GitPipelinesNprdConfig
---@field command? string
---@field space? string
---@field mention? string
---@field message? string

---@class GitPipelinesIcons
---@field pass string
---@field fail string
---@field pending string
---@field missing string
---@field disabled string

---@class GitPipelinesFloatConfig
---@field width number
---@field height number
---@field border string|string[]
---@field title string

---@class GitPipelinesUserIcons
---@field pass? string
---@field fail? string
---@field pending? string
---@field missing? string
---@field disabled? string

---@class GitPipelinesUserFloatConfig
---@field width? number
---@field height? number
---@field border? string|string[]
---@field title? string

---@class GitPipelinesUserConfig
---@field search_queries? string[]
---@field blacklist? GitPipelinesBlacklist
---@field pr_limit? integer
---@field page_size? integer
---@field concurrent_requests? integer
---@field refresh_ms? integer
---@field refresh_pending_ms? integer
---@field max_workflows_per_pr? integer
---@field install_default_statusline? boolean
---@field notify? boolean
---@field nprd_internal? GitPipelinesNprdConfig
---@field icons? GitPipelinesUserIcons
---@field float? GitPipelinesUserFloatConfig

---@class GitPipelinesConfig
---@field search_queries string[]
---@field blacklist GitPipelinesBlacklist
---@field pr_limit integer
---@field page_size integer
---@field concurrent_requests integer
---@field refresh_ms integer
---@field refresh_pending_ms integer
---@field max_workflows_per_pr integer
---@field install_default_statusline boolean
---@field notify boolean
---@field nprd_internal GitPipelinesNprdConfig
---@field icons GitPipelinesIcons
---@field float GitPipelinesFloatConfig

---@class GitPipelinesCounts
---@field total integer
---@field passing integer
---@field pending integer
---@field failing integer
---@field missing integer

---@class GitPipelinesWorkflow
---@field id integer|string|nil
---@field name string
---@field event string|nil
---@field status string|nil
---@field conclusion string|nil
---@field url string|nil
---@field path string|nil
---@field state GitPipelinesWorkflowState
---@field label string
---@field updated_at string|nil
---@field created_at string|nil

---@class GitPipelinesItem
---@field repo string
---@field number integer
---@field title string
---@field url string
---@field updated_at string|nil
---@field is_draft boolean|nil
---@field head_sha string
---@field head_ref_name string|nil
---@field workflows GitPipelinesWorkflow[]
---@field summary_state GitPipelinesSummaryState|nil
---@field pending_count integer|nil
---@field passing_count integer|nil
---@field failing_count integer|nil
---@field fetch_error string|nil

---@class GitPipelinesState
---@field items GitPipelinesItem[]
---@field counts GitPipelinesCounts
---@field enabled boolean
---@field loading boolean
---@field inflight boolean
---@field pending_refresh boolean
---@field last_sync integer|nil
---@field error string|nil
---@field generation integer
---@field timer uv.uv_timer_t|nil

---@class GitPipelinesLineMeta
---@field url string|nil
---@field kind string
---@field pr GitPipelinesItem|nil

---@class GitPipelinesUi
---@field schedule_render fun()
---@field render_float fun()
---@field open fun()

return {}
