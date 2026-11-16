--==============================================================================
-- plugins/nvim_autopairs.lua  -  Auto-pair brackets, quotes, and blocks
--
-- Plugin: windwp/nvim-autopairs
--
-- Automatically inserts closing brackets/quotes when opening ones are typed.
-- Also provides:
--   - Space expansion: "(|)" + <Space> -> "( | )"
--   - Multi-line expansion: "{|}" + <CR> -> "{\n  |\n}"
--   - Fast wrap: <M-e> to wrap selected text in brackets.
--   - Lua do/then -> end blocks via treesitter awareness.
--   - Nested-spacing recovery for inner pairs inside spaced outer pairs.
--   - cmp integration: auto-insert "()" after accepting a function completion.
--==============================================================================

return {
  "windwp/nvim-autopairs",
  event = "InsertEnter",
  -- No nvim-cmp dependency: completion is handled by blink.cmp, which does not
  -- provide a `cmp` module, so the `confirm_done` hook below never fired and
  -- the only thing the dependency did was install/load a dead engine.
  config = function()
    local npairs = require("nvim-autopairs")
    local Rule = require("nvim-autopairs.rule")
    local cond = require("nvim-autopairs.conds")

    -- Filetypes where autopairs is disabled entirely.
    -- Shared with the recovery autocmd further down.
    local disabled_filetypes = { "TelescopePrompt", "spectre_panel" }

    npairs.setup({
      -- Only close a pair if the treesitter node at cursor actually makes
      -- sense for it (e.g. don't pair a quote inside a comment or string).
      check_ts = true,
      ts_config = {
        lua = { "string" },
        javascript = { "template_string" },
        java = false, -- Java's parser is too slow for this; skip it.
      },

      disable_filetype = disabled_filetypes,

      -- Bracket repair: if a closing bracket already exists later on the same
      -- line, typing the opener will not stack a second closer on top.
      -- Prevents "((foo)" -> "((foo))" when the line was already half-broken.
      enable_check_bracket_line = true,

      enable_bracket_in_quote = true,   -- Allow brackets like ("[") inside quotes.
      enable_afterquote = true,         -- Add pair after quote (e.g. func'').
      enable_moveright = true,

      -- Don't insert a pair if the next char is a word char or dot.
      -- E.g. typing "(" right before "bar" in "foo(|bar" won't add ")".
      ignored_next_char = "[%w%.]",

      break_undo = true,  -- Undo doesn't nuke both the pair and edits in one step.

      -- Multiline expansion: pressing <CR> with the cursor between an empty
      -- pair expands it to:
      --   {
      --     |
      --   }
      -- with correct indentation.
      map_cr = true,

      -- <BS> between an empty pair "(|)" deletes both delimiters at once.
      map_bs = true,

      -- Fast wrap: select/position + <M-e>, then type a key to jump the
      -- closing delimiter out to wrap everything up to that point.
      fast_wrap = {
        map = "<M-e>",
        chars = { "{", "[", "(", '"', "'" },
        pattern = [=[[%'%"%>%]%)%}%,]]=],
        end_key = "$",
        keys = "qwertyuiopzxcvbnmasdfghjkl",
        check_comma = true,
        highlight = "Search",
        highlight_grey = "Comment",
        offset = 0,
      },
    })

    --==========================================================================
    -- SPACE EXPANSION
    -- Typing a space inside an empty pair, "(|)", expands it to "( | )".
    -- Typing a second space, or the actual closing character, steps out.
    --==========================================================================
    local brackets = { { "(", ")" }, { "[", "]" }, { "{", "}" } }

    npairs.add_rules({
      Rule(" ", " ")
        :with_pair(function(opts)
          local pair = opts.line:sub(opts.col - 1, opts.col)
          return vim.tbl_contains({ "()", "[]", "{}" }, pair)
        end)
        :with_move(cond.none())
        :with_cr(cond.none())
        :with_del(function(opts)
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local context = opts.line:sub(col - 1, col + 2)
          return vim.tbl_contains({ "(  )", "[  ]", "{  }" }, context)
        end),
    })

    for _, bracket in pairs(brackets) do
      npairs.add_rules({
        Rule(bracket[1] .. " ", " " .. bracket[2])
          :with_pair(cond.none())
          :with_move(function(opts)
            return opts.char == bracket[2]
          end)
          :with_cr(cond.none())
          :with_del(cond.none()),
      })
    end

    --==========================================================================
    -- LUA do/then -> end, gated on treesitter
    --==========================================================================
    local ts_conds = require("nvim-autopairs.ts-conds")

    npairs.add_rules({
      Rule("then", "end", "lua"):with_pair(ts_conds.is_ts_node({ "if_statement" })),
      Rule("do", "end", "lua"):with_pair(
        ts_conds.is_ts_node({ "for_statement", "while_statement", "repeat_statement" })
      ),
    })

    --==========================================================================
    -- NESTED-SPACING RECOVERY
    -- "a = { |}" + '"' yields "a = { "|"}" (new pair flush against outer "}").
    -- This restores the space: "a = { "|" }". Works for any pairable delimiter
    -- in either direction, re-checking itself on every change so both sides
    -- converge if both need fixing.
    --==========================================================================
    local pairables = {
      ["("] = ")",  [")"] = "(",
      ["["] = "]",  ["]"] = "[",
      ["{"] = "}",  ["}"] = "{",
      ['"'] = '"',  ["'"] = "'",
      ["`"] = "`",
    }
    local outer_open = { ["("] = true, ["["] = true, ["{"] = true }
    local outer_close = { [")"] = true, ["]"] = true, ["}"] = true }

    local function normalize_nested_spacing()
      if vim.fn.mode() ~= "i" or not vim.bo.modifiable then
        return
      end
      if vim.tbl_contains(disabled_filetypes, vim.bo.filetype) then
        return
      end

      local win = vim.api.nvim_get_current_win()
      local row, col = unpack(vim.api.nvim_win_get_cursor(win))
      local line = vim.api.nvim_get_current_line()

      -- col is 0-indexed; character at cursor = line:sub(col+1).
      local left1, right1 = line:sub(col, col), line:sub(col + 1, col + 1)
      if left1 == "" or right1 == "" or pairables[left1] ~= right1 then
        return
      end

      local left2, right2 = line:sub(col - 1, col - 1), line:sub(col + 2, col + 2)

      -- undojoin merges this corrective edit into the same undo step as
      -- the keystroke that caused it, so a single `u` undoes both.
      if outer_close[right2] and left2 == " " then
        pcall(vim.cmd, "undojoin")
        vim.api.nvim_buf_set_text(0, row - 1, col + 1, row - 1, col + 1, { " " })
        vim.api.nvim_win_set_cursor(win, { row, col })
      elseif outer_open[left2] and right2 == " " then
        pcall(vim.cmd, "undojoin")
        vim.api.nvim_buf_set_text(0, row - 1, col - 1, row - 1, col - 1, { " " })
        vim.api.nvim_win_set_cursor(win, { row, col + 1 })
      end
    end

    vim.api.nvim_create_autocmd("TextChangedI", {
      group = vim.api.nvim_create_augroup("autopairs_nested_spacing", { clear = true }),
      callback = normalize_nested_spacing,
    })

    -- Completion-engine integration used to live here (nvim-cmp's
    -- `confirm_done` -> insert "()" after a function completion). It could never
    -- fire with blink.cmp as the engine, and it silently pulled nvim-cmp into
    -- the session. Intentionally dropped -- see lua/plugins/blink_cmp.lua for
    -- the completion setup.
  end,
}
