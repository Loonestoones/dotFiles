return {
	{
		'ojroques/vim-oscyank',
	},
	{
		'tpope/vim-fugitive',
	},
	{
		'brenoprata10/nvim-highlight-colors',
		config = function()
			require('nvim-highlight-colors').setup({})
		end
	},
	{
		"nvim-tree/nvim-web-devicons", opts = {}
	},
	{
		'prichrd/netrw.nvim', opts = {}
	},
}
