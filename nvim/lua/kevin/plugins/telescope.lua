return {
  "nvim-telescope/telescope.nvim",
  version = "*",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    local builtin = require("telescope.builtin")

    vim.keymap.set("n", "<leader>pf", builtin.find_files, {})
    vim.keymap.set("n", "<C-p>", builtin.git_files, {})
    vim.keymap.set('n', '<leader>ps', builtin.live_grep, { desc = 'Telescope live grep' })
    vim.keymap.set('n', '<leader>ph', builtin.help_tags, { desc = 'Telescope help tags' })
  end,
}
