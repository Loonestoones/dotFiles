return {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
	-- NOTE: In the new version, it is 'nvim-treesitter' NOT 'nvim-treesitter.configs'
	local ts = require("nvim-treesitter")

	ts.setup({
	    -- Optional: setup install directory
	    -- install_dir = vim.fn.stdpath("data") .. "/treesitter",
	})

	-- In the new version, you install languages like this:
	ts.install({ "lua", "vim", "vimdoc", "query", "python", "c", "cpp" })

	-- IMPORTANT: Highlighting is now handled differently. 
	-- If it doesn't turn on automatically, add this:
	vim.api.nvim_create_autocmd("FileType", {
	    callback = function()
		pcall(vim.treesitter.start)
	    end,
	})
    end,
}
