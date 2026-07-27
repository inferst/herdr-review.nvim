vim.opt.rtp:prepend(vim.fn.getcwd())

local plenary_path = vim.env.PLENARY_PATH or "deps/plenary.nvim"
vim.opt.rtp:prepend(plenary_path)
