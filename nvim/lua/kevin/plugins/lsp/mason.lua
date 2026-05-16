return {
	"mason-org/mason-lspconfig.nvim",

	dependencies = {
		{
			"mason-org/mason.nvim",
			opts = {
				ui = {
					icons = {
						package_installed = "✓",
						package_pending = "➜",
						package_uninstalled = "✗",
					},
				},
				ensure_installed = {
					"codelldb",
					"cmakelang",
				},
			},
		},

		"neovim/nvim-lspconfig",
	},

	opts = {
		ensure_installed = {
			"html",
			"lua_ls",
			"pyright",
			"clangd",
		},
	},
}
