return {
  dir = vim.fn.expand '~/personal/hustles/git-pipelines.nvim',
  name = 'git-pipelines',
  event = 'VeryLazy',
  opts = {},
  keys = {
    {
      '<leader>gp',
      function()
        if _G.GitPipelines then
          _G.GitPipelines.open()
        end
      end,
      desc = 'Open Git pipelines',
    },
    {
      '<leader>gP',
      function()
        if _G.GitPipelines then
          _G.GitPipelines.refresh(true)
        end
      end,
      desc = 'Refresh Git pipelines',
    },
  },
  config = function(_, opts)
    require('git-pipelines').setup(opts)
  end,
}
