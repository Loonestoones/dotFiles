return {
  {
    "ellisonleao/gruvbox.nvim",
    priority = 1000,
    config = function()
      require("gruvbox").setup({
        contrast = "hard",
        transparent_mode = false,
      })

      vim.o.background = "dark"
      vim.cmd.colorscheme("gruvbox")
      -- enable_transparency()
    end,
  },
  {
      "nvim-lualine/lualine.nvim",
      dependencies = {
	  "nvim-tree/nvim-web-devicons",
      },
      opts = {
	  theme = "gruvbox",
      }
  },
}
