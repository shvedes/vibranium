--==============================================================================
-- plugins/trouble.lua  -  Diagnostic/quickfix/location list viewer
--
-- Plugin: folke/trouble.nvim
--
-- Provides a pretty list view for diagnostics, quickfix items, location list
-- entries, and document symbols. Rendered in a floating window with custom
-- keymaps and formatting.
--
-- Keymaps inside the trouble window:
--   j/k/[/]/{/}  - Navigate items
--   <cr>/l/o     - Jump to item and close
--   q            - Close trouble
--   <esc>        - Cancel
--
-- Global keymaps:
--   <leader>dt  - Diagnostics (buffer)
--   <leader>dT  - Diagnostics (workspace)
--   <leader>dQ  - Quickfix list
--   <leader>dL  - Location list
--   <leader>ds  - Document symbols
--
-- The capitals are deliberate. lua/plugins/lspconfig.lua binds the lowercase
-- <leader>dq (diagnostics -> loclist) and <leader>dl (line diagnostics float)
-- buffer-locally on LspAttach, and a buffer-local mapping always wins over a
-- global one -- so the previous <leader>dq/<leader>dl here were unreachable in
-- any buffer with a language server attached. Capital letters mean "open the
-- list viewer", lowercase means "run the LSP action".
--==============================================================================

-- Jump to the item under the cursor and close the trouble window.
local function jump_and_hl(view, ctx)
  if not ctx.item then return end
  view:jump(ctx.item)
  view:close()
end

return {
  "folke/trouble.nvim",
  cmd = "Trouble",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    auto_preview = false,
    auto_refresh = true,
    auto_jump = false,
    follow = true,
    focus = true,
    indent_guides = true,
    multiline = true,

    -- Custom formatters for line number and severity level columns.
    formatters = {
      line = function(ctx)
        return { text = tostring(ctx.item.pos[1]) }
      end,
      level = function(ctx)
        local severity = ctx.item.severity or vim.diagnostic.severity.ERROR
        local name = vim.diagnostic.severity[severity] or "ERROR"
        local hl = "Diagnostic" .. name:sub(1, 1) .. name:sub(2):lower()
        return { text = name:sub(1, 1), hl = hl }
      end,
    },

    preview = {
      type = "main",   -- Show preview in the main editor area.
      scratch = true,
    },

    -- Floating window dimensions and position.
    win = {
      type = "float",
      relative = "editor",
      width = 80,
      height = 30,
      border = "single", -- square, matching options.lua's winborder = "single"
      position = "center",
    },

    -- Custom keymaps for the trouble window.
    keys = {
      j = {
        action = function(view)
          view:move({ down = vim.v.count1 })
          local cur = vim.api.nvim_win_get_cursor(view.win.win)
          local col = vim.fn.getline(cur[1]):find("[A-Z]%d+")
          vim.api.nvim_win_set_cursor(view.win.win, { cur[1], (col or 2) - 1 })
        end,
        desc = "next",
      },
      k = {
        action = function(view)
          view:move({ up = vim.v.count1 })
          local cur = vim.api.nvim_win_get_cursor(view.win.win)
          local col = vim.fn.getline(cur[1]):find("[A-Z]%d+")
          vim.api.nvim_win_set_cursor(view.win.win, { cur[1], (col or 2) - 1 })
        end,
        desc = "prev",
      },
      ["]"] = "next",
      ["["] = "prev",
      ["}"] = "next",
      ["{"] = "prev",
      ["<cr>"] = jump_and_hl,
      l = jump_and_hl,
      o = jump_and_hl,
      q = "close",
      ["<esc>"] = "cancel",
    },

    -- Default mode: buffer-local diagnostics.
    modes = {
      diagnostics = {
        desc = "diagnostics",
        mode = "diagnostics",
        filter = { buf = 0 },
        format = "{level}{line}: {message}",
      },
    },
  },

  config = function(_, opts)
    require("trouble").setup(opts)

    -- Make the trouble window background transparent.
    vim.api.nvim_set_hl(0, "TroubleNormal", { bg = "NONE" })

    -- Set initial cursor column to the start of content (after severity letter).
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "trouble",
      group = vim.api.nvim_create_augroup("TroubleCursorPos", { clear = true }),
      callback = function()
        vim.api.nvim_create_autocmd("TextChanged", {
          buffer = vim.api.nvim_get_current_buf(),
          once = true,
          callback = function()
            local cur = vim.api.nvim_win_get_cursor(0)
            local col = vim.fn.getline(cur[1]):find("[A-Z]%d+")
            if col then
              vim.api.nvim_win_set_cursor(0, { cur[1], col - 1 })
            end
          end,
        })
      end,
    })
  end,

  -- Global mappings to open different trouble views.
  keys = {
    { "<leader>dt", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", desc = "Diagnostics (buffer)" },
    { "<leader>dT", "<cmd>Trouble diagnostics toggle<cr>", desc = "Diagnostics (workspace)" },
    { "<leader>dQ", "<cmd>Trouble qflist toggle<cr>", desc = "Quickfix list" },
    { "<leader>dL", "<cmd>Trouble loclist toggle<cr>", desc = "Location list" },
    { "<leader>ds", "<cmd>Trouble symbols toggle focus=false<cr>", desc = "Symbols" },
  },
}
