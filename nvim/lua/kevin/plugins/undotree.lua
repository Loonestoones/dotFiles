return {
  "jiaoshijie/undotree",
  opts = {
    -- your options
  },
  keys = {
    { "<leader>u", "<cmd>lua require('undotree').toggle()<cr>" },
  },
  config = function(_, opts)
    -- Enable persistent undo
    vim.opt.undofile = true
    vim.opt.undodir = vim.fn.expand("~/AppData/Local/nvim/undo")

    -- Create the directory if it doesn't exist
    local undodir = vim.fn.expand("~/AppData/Local/nvim/undo")
    if vim.fn.isdirectory(undodir) == 0 then
      vim.fn.mkdir(undodir, "p")
    end

    require("undotree").setup(opts)
  end,
}
