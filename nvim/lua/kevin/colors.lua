return {
  {
    "ellisonleao/gruvbox.nvim",
    priority = 1000, -- make sure it loads before other UI plugins
    config = function()
      require("gruvbox").setup({
        terminal_colors = true,
        undercurl = true,
        underline = true,
        bold = true,
        italic = {
          strings = true,
          emphasis = true,
          comments = true,
          operators = false,
          folds = true,
        },
        strikethrough = true,
        invert_selection = false,
        invert_signs = false,
        invert_tabline = false,
        inverse = true,
        contrast = "", -- "soft", "hard", or ""
        palette_overrides = {},
        overrides = {},
        dim_inactive = false,
        transparent_mode = true,
      })

      vim.o.background = "dark"
      vim.cmd.colorscheme("gruvbox")
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
