local M = {}

---@param api GitPipelinesModule
function M.setup(api)
  vim.api.nvim_create_user_command('GitPipelines', function()
    api.open()
  end, { desc = 'Open Git pipelines window' })

  vim.api.nvim_create_user_command('GitPipelinesOpen', function()
    api.open()
  end, { desc = 'Open Git pipelines window' })

  vim.api.nvim_create_user_command('GitPipelinesRefresh', function()
    api.refresh(true)
  end, { desc = 'Refresh Git pipelines now' })

  vim.api.nvim_create_user_command('GitPipelinesToggle', function()
    api.toggle()
  end, { desc = 'Toggle Git pipelines polling' })

  vim.api.nvim_create_user_command('GitPipelinesEnable', function()
    api.enable()
  end, { desc = 'Enable Git pipelines polling' })

  vim.api.nvim_create_user_command('GitPipelinesDisable', function()
    api.disable()
  end, { desc = 'Disable Git pipelines polling' })
end

return M
