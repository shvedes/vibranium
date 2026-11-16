--==============================================================================
-- plugins/aerial.lua  -  Symbol outline / code navigation
--
-- Plugin: stevearc/aerial.nvim
--
-- Provides a sidebar that lists all symbols (functions, classes, variables,
-- etc.) in the current buffer, organised hierarchically. Backends include
-- LSP, treesitter, man pages, and asciidoc.
--
-- Features:
--   - Toggle with <leader>a
--   - Auto-close on unfocus or buffer switch
--   - Fold management linked to the tree
--   - Function/method names get "()" appended in the outline
--   - Custom icon labels via utils/kind.lua
--   - Custom keymaps: {, } for prev/next, l and <CR> to jump and close
--==============================================================================

return {
  "stevearc/aerial.nvim",
  event = { "BufReadPost", "BufNewFile" },
  -- Command stubs: without these, :AerialToggle & co. do not exist until a
  -- buffer is read (they were unreachable from an empty buffer).
  -- Key stub: the real mapping is created in config(), which only runs once a
  -- buffer is read -- so on the dashboard (or any empty buffer) <leader>a was
  -- simply "not mapped". This stub makes the key load the plugin instead.
  keys = {
    {
      "<leader>a",
      function()
        require("aerial").toggle({ focus = true })
      end,
      desc = "Toggle aerial",
    },
  },
  cmd = {
    "AerialToggle",
    "AerialOpen",
    "AerialOpenAll",
    "AerialClose",
    "AerialCloseAll",
    "AerialNext",
    "AerialPrev",
    "AerialGo",
    "AerialInfo",
    "AerialNavToggle",
    "AerialNavOpen",
    "AerialNavClose",
  },
  config = function()
    -- Create an italic variant of a highlight group for the symbol name.
    local function set_italic_hl(name, target)
      local hl = vim.api.nvim_get_hl(0, { name = target })
      local opts = { italic = true }
      if hl.fg then opts.fg = hl.fg end
      if hl.ctermfg then opts.ctermfg = hl.ctermfg end
      vim.api.nvim_set_hl(0, name, opts)
    end
    set_italic_hl("AerialSymbolName", "Comment")

    require("aerial").setup({
      -- Backends in priority order. LSP first, then treesitter, then fallback.
      backends = { "lsp", "treesitter", "man", "asciidoc" },

      layout = {
        min_width = 30,
        max_width = 50,
        default_direction = "prefer_right",  -- Open on the right side.
        placement = "edge",
        resize_to_content = true,
      },

      -- Auto-close events.
      close_automatic_events = { "unfocus", "switch_buffer" },

      autojump = true,
      manage_folds = true,
      link_folds_to_tree = true,
      link_tree_to_folds = true,
      show_guides = false,
      highlight_on_hover = true,
      highlight_cursor = true,

      -- Use our custom kind labels module instead of default icons.
      icons = require("utils.kind"),

      -- All non-icon text uses the italic AerialSymbolName highlight.
      get_highlight = function(_, is_icon)
        if is_icon then
          return nil
        end
        return "AerialSymbolName"
      end,

      -- Append "()" to function and method names in the outline.
      post_add_all_symbols = function(_, items)
        local function add_parens(list)
          for _, item in ipairs(list) do
            if item.kind == "Function" or item.kind == "Method" then
              item.name = item.name .. "()"
            end
            if item.children then
              add_parens(item.children)
            end
          end
          return list
        end
        return add_parens(items)
      end,

      -- Which symbol kinds to display (filters out others).
      filter_kind = {
        "Class",
        "Constructor",
        "Enum",
        "Function",
        "Interface",
        "Method",
        "Module",
        "Namespace",
        "Struct",
      },

      on_attach = function(_) end,
    })

    -- Buffer-local keymaps for the aerial window.
    local aug = vim.api.nvim_create_augroup("AerialKeymaps", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "aerial",
      group = aug,
      callback = function(ev)
        vim.keymap.set("n", "{", "<cmd>AerialPrev<CR>", { buffer = ev.buf, desc = "Previous symbol" })
        vim.keymap.set("n", "}", "<cmd>AerialNext<CR>", { buffer = ev.buf, desc = "Next symbol" })
        vim.keymap.set("n", "l", function()
          require("aerial").select()
          require("aerial").close()
        end, { buffer = ev.buf, desc = "Jump and close" })
        vim.keymap.set("n", "<CR>", function()
          require("aerial").select()
          require("aerial").close()
        end, { buffer = ev.buf, desc = "Jump and close" })
      end,
    })

    -- Monkey-patch aerial.util.remove_newlines to re-add space before labels.
    -- The default strips newlines but leaves a run-on sentence.
    local util = require("aerial.util")
    local orig = util.remove_newlines
    util.remove_newlines = function(str)
      str = orig(str)
      return str:gsub("([a-z]:) ", "%1")
    end

    -- Make all Aerial*KindIcon highlights italic (matches AerialSymbolName).
    vim.schedule(function()
      for kind in pairs(require("utils.kind")) do
        local name = "Aerial" .. kind .. "Icon"
        local hl = vim.api.nvim_get_hl(0, { name = name, link = true })
        if hl.link then
          vim.api.nvim_set_hl(0, name, { link = hl.link, italic = true })
        end
      end
    end)

    -- Global mapping: <leader>a toggles the aerial window.
    vim.keymap.set("n", "<leader>a", function()
      require("aerial").toggle({ focus = true })
    end, { desc = "Toggle aerial" })
  end,
}
