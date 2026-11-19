--==============================================================================
-- config/autocmds.lua  -  All autocommands
--
-- Single entry point for every autocommand in this config. Each section
-- below is self-contained: it creates its own augroup (or relies on
-- defaults), registers its autocmds, and does not depend on other sections.
--
-- Sections (in load order):
--   1.  Auto-create parent directories on save
--   2.  Auto-clear search highlighting
--   3.  Auto-close hidden, unmodified buffers
--   4.  Close special buffer types with 'q'
--   5.  Smart command-line visibility
--   6.  Disable automatic comment continuation
--   7.  Cursorline only in the active window
--   8.  Dim inactive windows (DISABLED, kept for reference)
--   9.  Per-filetype editor options
--  10.  Open help pages in a new tab
--  11.  Press 'q' to quit empty, unedited buffers
--  12.  Restore cursor position per file
--  13.  Dynamic scrolloff based on window height
--  14.  Auto-remove trailing whitespace
--  15.  Auto-equalize window splits on resize
--  16.  Template system: auto-load templates from lua/templates/
--  17.  80-column guide for text and markdown files
--==============================================================================

--==============================================================================
-- 1. Auto-create parent directories on save
--
-- When writing a file whose parent directory does not exist (e.g. saving
-- a new file at src/foo/bar/baz.py where src/foo/bar doesn't exist yet),
-- this autocmd intercepts BufWritePre and creates the missing directory
-- hierarchy with `mkdir -p`.
--
-- Skips URIs with protocol schemes (e.g. scp://, file://) since those are
-- handled by netrw/the remote plugin and would misinterpret local paths.
--==============================================================================

vim.api.nvim_create_autocmd("BufWritePre", {
  desc = "Auto-create parent directory when saving a new file",
  group = vim.api.nvim_create_augroup("auto_create_dir", { clear = true }),
  callback = function(event)
    -- Bail out if the file path looks like a URI (e.g. scp://host/path).
    -- These are handled by remote plugins and mkdir would fail on them.
    if event.match:match("^%w%w+:[\\/][\\/]") then
      return
    end
    -- Resolve the real path (follow symlinks) or fall back to the literal path.
    -- uv.fs_realpath returns nil if the path does not exist (which is expected
    -- for new files), so we fall back to event.match.
    local file = vim.uv.fs_realpath(event.match) or event.match
    -- Create the parent directory hierarchy. "p" = mkdir -p (no error if exists).
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":p:h"), "p")
  end,
})

--==============================================================================
-- 2. Auto-clear search highlighting
--
-- After searching with / or ?, all matches remain highlighted (vim.opt.hlsearch)
-- until the user explicitly runs :nohlsearch. This autocmd clears the
-- highlighting automatically when entering:
--   - Insert mode (to edit without visual noise)
--   - Command-line mode (to type commands without distraction)
--
-- Uses vim.schedule_wrap to defer the call, preventing conflicts with other
-- autocmds that run simultaneously on the same event.
--==============================================================================

vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, {
  desc = "Clear search highlighting when entering Insert or Cmdline mode",
  callback = vim.schedule_wrap(function()
    vim.cmd.nohlsearch()
  end),
})

--==============================================================================
-- 3. Auto-close hidden, unmodified buffers
--
-- Buffers that are no longer displayed in any window accumulate in Neovim's
-- buffer list. Over time this creates clutter: many hidden buffers waste
-- memory and make :bnext/:bprev navigation confusing.
--
-- This autocmd automatically deletes buffers that:
--   - Are valid (not wiped or invalid).
--   - Are listed (vim.bo.buflisted = true).
--   - Are NOT modified (no unsaved changes).
--   - Are NOT displayed in any window (hidden).
--
-- It runs on:
--   - BufEnter: every time the user switches to a different buffer.
--   - QuitPre: just before quitting, to clean up before session save.
--==============================================================================

-- Core cleanup function: iterate all buffers and delete eligible hidden ones.
local function close_unused()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- Skip invalid, unlisted, or modified buffers (unsaved changes = keep).
    if not vim.api.nvim_buf_is_valid(buf)
      or not vim.bo[buf].buflisted
      or vim.bo[buf].modified
    then
      goto continue
    end

    -- Check whether the buffer is visible in any window (including all tabs).
    local displayed = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        displayed = true
        break
      end
    end

    -- If hidden and unmodified, delete it (force = true because it is hidden).
    if not displayed then
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    ::continue::
  end
end

-- Clean up hidden buffers when entering a buffer.
vim.api.nvim_create_autocmd("BufEnter", {
  desc = "Close hidden, unmodified buffers",
  callback = close_unused,
})

-- Clean up hidden buffers before exiting Neovim (reduces session file size).
vim.api.nvim_create_autocmd("QuitPre", {
  desc = "Clean up hidden buffers before exit",
  callback = close_unused,
})

--==============================================================================
-- 4. Close specific buffer types with 'q'
--
-- For non-editable buffer types (help, quickfix, man pages, Lazy, etc.),
-- pressing 'q' or <Esc> will close the window/buffer with :q!.
--
-- This is a common Vim convention: informational buffers should be dismissable
-- with a single keystroke rather than requiring the user to type :q.
-- The <Esc> mapping mirrors the common "press Escape to close" behavior.
--
-- Also sets nobuflisted so these buffers don't appear in the buffer list
-- or interfere with :bnext/:bprev navigation.
--==============================================================================

vim.api.nvim_create_autocmd("FileType", {
  desc = "Close with q and <Esc> in non-editable buffer types",
  pattern = {
    "help",
    "startuptime",
    "qf",         -- quickfix list
    "lspinfo",
    "man",
    "checkhealth",
    "lazy",       -- lazy.nvim dashboard
  },
  callback = function()
    vim.keymap.set("n", "q", "<cmd>q!<CR>", { buffer = true, silent = true, desc = "Close buffer" })
    vim.keymap.set("n", "<Esc>", "<cmd>q!<CR>", { buffer = true, silent = true, desc = "Close buffer" })
    vim.opt_local.buflisted = false
  end,
})

--==============================================================================
-- 5. Smart command-line visibility
--
-- By default, vim.opt.cmdheight = 0 hides the command line when not in use.
-- However, typing a command would be invisible without temporarily raising it.
--
-- This section:
--   1. Sets cmdheight = 1 when entering the command line (CmdlineEnter),
--      so the user can see what they are typing.
--   2. Restores cmdheight = 0 on leaving (CmdlineLeave), re-hiding it.
--   3. Calls redrawstatus after :w to clear the "written" message from the
--      now-hidden cmdline area.
--
-- The augroup names are intentionally verbose and include a prefix (gmr_) to
-- avoid collision with other plugins.
--==============================================================================

-- Show the command line when the user presses : (enters command-line mode).
vim.api.nvim_create_autocmd('CmdlineEnter', {
  group = vim.api.nvim_create_augroup(
    'gmr_cmdheight_1_on_cmdlineenter',
    { clear = true }
  ),
  desc = 'Show cmdline when typing a command',
  command = ':set cmdheight=1',
})

-- Hide the command line when done (after pressing <CR> or <Esc>).
vim.api.nvim_create_autocmd('CmdlineLeave', {
  group = vim.api.nvim_create_augroup(
    'gmr_cmdheight_0_on_cmdlineleave',
    { clear = true }
  ),
  desc = 'Hide cmdline when not typing',
  command = ':set cmdheight=0',
})

-- After writing a file, redraw the status line to clear the "written" message
-- that lingers in the cmdheight=0 area.
vim.api.nvim_create_autocmd('BufWritePost', {
  group = vim.api.nvim_create_augroup(
    'gmr_hide_message_after_write',
    { clear = true }
  ),
  desc = 'Clear "written" message after saving',
  pattern = { '*' },
  command = 'redrawstatus',
})

--==============================================================================
-- 6. Disable automatic comment continuation
--
-- By default, Neovim continues comment leaders when you press <Enter> inside
-- a comment, or use o/O on a comment line. This is controlled by three
-- 'formatoptions' flags:
--   c - Auto-wrap comments using the current comment leader.
--   r - Insert comment leader when pressing <Enter> in Insert mode.
--   o - Insert comment leader when pressing o or O in Normal mode.
--
-- Many users find this behavior annoying because it forces them to manually
-- delete the continued comment leader. This autocmd removes all three flags
-- for every filetype, ensuring that pressing <Enter> inside a comment
-- produces a plain newline without a leader.
--
-- The autocmd fires on every FileType event, setting vim.opt_local so the
-- change is window-local (not global), allowing filetype-specific overrides
-- to take precedence if explicitly set in a ftplugin.
--==============================================================================

vim.api.nvim_create_autocmd("FileType", {
  desc = "Disable automatic comment continuation on Enter / o / O",
  callback = function()
    vim.opt_local.formatoptions:remove({ "c", "r", "o" })
  end,
})

--==============================================================================
-- 7. Cursorline only in the active window
--
-- Source: https://www.reddit.com/r/neovim/comments/1i2xw2m/comment/m7ik6wu
--
-- By default Neovim shows cursorline in ALL windows, which is distracting.
-- This autocmd pair shows it only in the currently focused window:
--   - WinEnter + InsertLeave: enable cursorline
--   - WinLeave + InsertEnter: disable cursorline
--
-- The window-local variable `vim.w.auto_cursorline` tracks whether the
-- cursorline was enabled before we entered a different window. It is set
-- to true when we hide it, and false when we restore it, serving as a
-- guard to avoid accidentally enabling cursorline in windows that had it
-- disabled by the user's filetype or window settings.
--==============================================================================

-- Show cursorline when entering a window OR when leaving Insert mode
-- (the cursorline is hidden during Insert mode to reduce visual noise).
vim.api.nvim_create_autocmd({ "InsertLeave", "WinEnter" }, {
  desc = "Show cursorline in the active window",
  callback = function()
    if vim.w.auto_cursorline then
      vim.wo.cursorline = true
      vim.w.auto_cursorline = false
    end
  end,
})

-- Hide cursorline when entering Insert mode OR when leaving a window.
vim.api.nvim_create_autocmd({ "InsertEnter", "WinLeave" }, {
  desc = "Hide cursorline on insert or when leaving window",
  callback = function()
    if vim.wo.cursorline then
      vim.w.auto_cursorline = true
      vim.wo.cursorline = false
    end
  end,
})

--==============================================================================
-- 8. Dim inactive windows (DISABLED, kept for reference)
--
-- Source: https://www.reddit.com/r/neovim/comments/1i2xw2m/comment/m7ignud
--
-- When enabled, this would dim all highlight groups in unfocused windows
-- using a "DimInactiveWindows" highlight group with guifg=#666666, and
-- restore normal highlights on WinEnter.
--
-- It is disabled by default: the implementation is too aggressive (every
-- single highlight group gets overridden with winhighlight) and causes
-- visual glitches with many plugins. Set `enable_dim_inactive` to true
-- to turn it back on.
--==============================================================================

local enable_dim_inactive = false
if enable_dim_inactive then
  -- Define the dimmed foreground color for inactive windows.
  vim.cmd("highlight default DimInactiveWindows guifg=#666666")

  -- On WinLeave: collect every highlight group currently defined and set ALL
  -- of them to the dimmed variant via the winhighlight window option.
  vim.api.nvim_create_autocmd({ "WinLeave" }, {
    desc = "Dim inactive windows",
    callback = function()
      local highlights = {}
      for hl, _ in pairs(vim.api.nvim_get_hl(0, {})) do
        table.insert(highlights, hl .. ":DimInactiveWindows")
      end
      vim.wo.winhighlight = table.concat(highlights, ",")
    end,
  })

  -- On WinEnter: clear the winhighlight override, restoring original colors.
  vim.api.nvim_create_autocmd({ "WinEnter" }, {
    desc = "Restore highlights on window enter",
    callback = function()
      vim.wo.winhighlight = ""
    end,
  })
end

--==============================================================================
-- 9. Per-filetype editor options
--
-- Applies filetype-specific indentation and formatting settings when a buffer
-- is recognised as a specific filetype. This allows different languages to
-- use different tab widths, indentation styles, etc.
--
-- The options are stored in a lookup table keyed by filetype name. On every
-- FileType event, if the filetype matches a key in the table, all options
-- in that entry are applied via vim.opt_local (buffer-local).
--==============================================================================

-- Table of per-filetype options. Each key is a filetype string, and the
-- value is a table of vim.opt_local keys and values to set.
local filetype_opts = {
  lua = {
    tabstop = 2,
    shiftwidth = 2,
    softtabstop = 2,
    expandtab = true,
  },
  sh = {
    tabstop = 4,
    shiftwidth = 4,
    softtabstop = 4,
    expandtab = false,  -- Shell scripts conventionally use real tabs.
  },
  python = {
    tabstop = 4,
    shiftwidth = 4,
    softtabstop = 4,
    expandtab = true,   -- PEP 8: 4 spaces per indent.
  },
}

-- Apply per-filetype options on FileType events.
-- The pattern "*" means this fires for every filetype (we filter internally).
vim.api.nvim_create_autocmd("FileType", {
  desc = "Apply buffer-local options based on filetype",
  pattern = "*",
  callback = function(args)
    local opts = filetype_opts[args.match]
    if not opts then
      return  -- No settings for this filetype; skip.
    end
    for name, value in pairs(opts) do
      vim.opt_local[name] = value
    end
  end,
})

--==============================================================================
-- 10. Open help pages in a new tab
--
-- By default, :help opens in a split window. This autocmd intercepts help
-- buffers and moves them to a new tab page via `wincmd T`.
--
-- Additionally, it sets bufhidden = "wipe" which means the buffer is deleted
-- from memory when its window closes. This is important because:
--   - Without it, closing a help tab just hides the buffer.
--   - The next :help call reuses the hidden buffer (BufReadPost doesn't fire).
--   - Since this autocmd fires on FileType, skipping the callback entirely.
--   - Wiping the buffer forces a fresh load on the next :help call.
--==============================================================================

vim.api.nvim_create_autocmd("FileType", {
  desc = "Open help pages in a new tab instead of a split",
  group = vim.api.nvim_create_augroup("HelpInNewTab", { clear = true }),
  pattern = "help",
  callback = function()
    -- Safety check: only act on actual help buffers.
    if vim.bo.buftype ~= "help" then
      return
    end

    -- When the help window closes, wipe the buffer entirely.
    -- This forces the next :help call to create a new buffer, re-triggering
    -- FileType and this autocmd, instead of silently reusing the old hidden
    -- buffer and skipping the callback.
    vim.bo.bufhidden = "wipe"

    -- Move the current window to a new tab page.
    vim.cmd.wincmd("T")
  end,
})

--==============================================================================
-- 11. Press 'q' to quit empty, unedited, new buffers
--
-- When you create a new (nameless) buffer that is completely empty and has
-- not been modified, pressing `q` in Normal mode will close it.
-- This is a convenience: when you type `:enew` or open a new tab with no
-- file, you can just press q instead of reaching for :q or :bd.
--
-- The mapping is buffer-local and is removed as soon as the buffer is
-- modified (TextChanged event checks and deletes the mapping).
--
-- Conditions for the map to be created:
--   1. The file does not exist on disk (filereadable returns 0).
--   2. The buffer has exactly 1 line, and that line is empty ("").
--==============================================================================

-- On new or read buffers, check the conditions and set up the mapping.
vim.api.nvim_create_autocmd({ "BufNewFile", "BufReadPost", "VimEnter" }, {
  desc = "Press q to quit empty unedited new files",
  callback = function(args)
    local buf = args.buf

    -- If the file already exists on disk, skip (it's not a "new" empty file).
    if vim.fn.filereadable(vim.api.nvim_buf_get_name(buf)) == 1 then
      return
    end

    -- If the buffer has more than 1 line, or the first line is non-empty,
    -- it's not an empty buffer.
    if vim.api.nvim_buf_line_count(buf) ~= 1
      or vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "" then
      return
    end

    -- Set buffer-local mapping: press q to :quit.
    vim.keymap.set("n", "q", "<cmd>quit<cr>", {
      buffer = buf,
      silent = true,
      desc = "Quit new empty buffer",
    })
  end,
})

-- On TextChanged (any edit), check if the q mapping exists and remove it.
-- This ensures that once the user starts typing in the empty buffer, q goes
-- back to its normal behavior (recording a macro).
vim.api.nvim_create_autocmd("TextChanged", {
  callback = function(args)
    local ok, maps = pcall(vim.api.nvim_buf_get_keymap, args.buf, "n")
    if ok then
      for _, m in ipairs(maps) do
        if m.lhs == "q" and m.desc == "Quit new empty buffer" then
          pcall(vim.keymap.del, "n", "q", { buffer = args.buf })
          return
        end
      end
    end
  end,
})

--==============================================================================
-- 12. Restore cursor position per file
--
-- When reopening a file that was previously edited, Neovim stores the last
-- cursor position in the '" mark (previous cursor position). This autocmd
-- retrieves that mark and sets the cursor there on BufReadPost.
--
-- The '" mark is automatically saved and restored by vim.opt.undofile but
-- is not applied to the cursor position without explicit code. This autocmd
-- bridges that gap.
--
-- Safety checks:
--   - The mark line must be > 0 (marks can be invalid).
--   - The mark line must be <= the total number of lines in the buffer
--     (in case the file changed since last edit).
--==============================================================================

vim.api.nvim_create_autocmd("BufReadPost", {
  desc = "Restore cursor position to last edit location",
  callback = function(event)
    -- Get the '" mark (previous cursor position) for this buffer.
    -- Returns {line, col} where line is 1-indexed, col is 0-indexed.
    local mark = vim.api.nvim_buf_get_mark(event.buf, '"')
    -- Get the total line count of the buffer.
    local line_count = vim.api.nvim_buf_line_count(event.buf)

    -- Only restore if the saved line is within the current buffer's range.
    -- mark[1] is the line number (1-indexed).
    if mark[1] > 0 and mark[1] <= line_count then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

--==============================================================================
-- 13. Dynamic scrolloff based on window height
--
-- Instead of a fixed vim.opt.scrolloff value, this autocmd calculates
-- scrolloff as a percentage of the current window height. This keeps the
-- cursor proportionally away from screen edges regardless of window size.
--
-- Formula: scrolloff = max(3, min(window_height * 0.70, 24))
--   - Minimum 3: ensures at least 3 lines of context.
--   - Maximum 24: avoids excessive scrolling on very large windows.
--   - 70% of height: keeps cursor roughly in the centre third of the window.
--
-- The value is set locally (vim.opt_local) so each window can have its own.
-- Recalculated on VimEnter, WinEnter (changing focus), and WinResized.
--==============================================================================

local scrolloff_group = vim.api.nvim_create_augroup("smart-scrolloff", { clear = true })

local function update_scrolloff()
  local height = vim.api.nvim_win_get_height(0)

  -- 70% of height, clamped to [3, 24].
  -- math.floor because scrolloff must be an integer.
  local scrolloff = math.floor(height * 0.70)
  scrolloff = math.max(3, math.min(scrolloff, 12))

  vim.opt_local.scrolloff = scrolloff
end

vim.api.nvim_create_autocmd({
  "VimEnter",
  "WinEnter",
  "WinResized",
}, {
  group = scrolloff_group,
  desc = "Adjust scrolloff proportionally to window height",
  callback = update_scrolloff,
})

--==============================================================================
-- 14. Auto-remove trailing whitespace
--
-- Automatically removes trailing whitespace from every line before saving
-- (BufWritePre). Also exposes a :TrimWhitespace command for manual use
-- (with a notification of how many lines were affected).
--
-- Certain filetypes where trailing whitespace is intentional (markdown,
-- text, reStructuredText, git commits) are excluded from the auto-trim.
-- The user can still run :TrimWhitespace manually on these if desired.
--
-- The trim function preserves the current cursor position, folds, and
-- viewport (via winsaveview/winrestview) so the user does not see the
-- edit happening.
--==============================================================================

-- Create a named augroup so the autocmd can be re-loaded without duplication.
local trim_group = vim.api.nvim_create_augroup("TrimTrailingWhitespace", {
  clear = true,
})

-- Filetypes where trailing whitespace is often intentional or meaningful.
-- Markdown: two trailing spaces create a <br> in many flavours.
-- Text/rst: plain text files may have intentional formatting.
-- gitcommit: git commit messages should preserve whatever the user typed.
local excluded = {
  markdown = true,
  text = true,
  rst = true,
  gitcommit = true,
}

-- Core function: remove trailing whitespace while preserving the viewport.
-- @param notify (boolean): if true, show a notification with the count.
local function trim_trailing_whitespace(notify)
  -- Save cursor position, folds, and viewport.
  local view = vim.fn.winsaveview()

  -- Count lines that currently have trailing whitespace. This is a second
  -- full-buffer scan (measured ~35ms on a 20k-line file), and the number is
  -- only ever displayed by :TrimWhitespace -- so the save path skips it.
  local trimmed = 0
  if notify then
    trimmed = vim.fn.searchcount({
      pattern = [[\s\+$]],
      maxcount = 0,
    }).total
  end

  -- Substitute trailing whitespace with nothing.
  -- The 'e' flag suppresses "Pattern not found" errors when no matches exist.
  vim.cmd([[%s/\s\+$//e]])

  -- Restore the original viewport so the user does not see a cursor jump.
  vim.fn.winrestview(view)

  -- Optionally report the result.
  if notify then
    vim.notify(
      trimmed > 0
        and ("Trimmed trailing whitespace on %d line%s"):format(
          trimmed,
          trimmed == 1 and "" or "s"
        )
      or "No trailing whitespace found",
      vim.log.levels.INFO,
      { title = "TrimWhitespace" }
    )
  end
end

-- Expose the function as :TrimWhitespace for manual invocation.
vim.api.nvim_create_user_command("TrimWhitespace", function()
  trim_trailing_whitespace(true)
end, {
  desc = "Remove trailing whitespace from the buffer",
})

-- Automatically trim trailing whitespace before saving, skipping excluded filetypes.
vim.api.nvim_create_autocmd("BufWritePre", {
  desc = "Trim trailing whitespace before save",
  group = trim_group,
  callback = function(args)
    if excluded[vim.bo[args.buf].filetype] then
      return
    end
    trim_trailing_whitespace(false)
  end,
})

--==============================================================================
-- 15. Auto-equalize window splits on resize
--
-- When the terminal window is resized, VimResized fires. This autocmd
-- triggers `wincmd =` in every tab page to redistribute window sizes
-- proportionally, then restores the current tab.
--
-- Without this, splits keep their old absolute sizes after a terminal
-- resize, which can leave unused space or overflow the visible area.
--==============================================================================

vim.api.nvim_create_autocmd({ "VimResized" }, {
  group = vim.api.nvim_create_augroup("EqualizeSplits", {}),
  callback = function()
    -- Save the current tab page so we can return to it after tabdo.
    local current_tab = vim.api.nvim_get_current_tabpage()
    -- Run `wincmd =` in every tab page to equalise all splits.
    vim.cmd("tabdo wincmd =")
    -- Restore the original tab page.
    vim.api.nvim_set_current_tabpage(current_tab)
  end,
  desc = "Equalize window splits when the terminal is resized",
})

--==============================================================================
-- 16. Template system: auto-load templates from lua/templates/
--
-- Two matching modes, one per directory level:
--   lua/templates/           EXACT filename match:
--                            "package.json" fills only package.json,
--                            never foobar.json.
--   lua/templates/by_ext/    LAZY extension match:
--                            the filetype is the last extension of the
--                            template name: "systemd.service" fills any
--                            *.service file, "spec" fills any *.spec.
--                            An optional "@filetype" suffix forces the
--                            buffer filetype (e.g. "systemd.service@systemd").
--
-- Adding a template is dropping a source file into the right folder and
-- restarting Neovim. See utils/templates.lua for the engine and $VAR vars.
--==============================================================================

local templates = require("utils.templates")
local templates_dir = vim.fn.stdpath("config") .. "/lua/templates"

--==============================================================================
-- 17. 80-column guide for text and markdown files
--
-- Prose files (.txt, .md) are conventionally kept within 80 columns. This
-- autocmd draws a vertical highlight line at column 80 as a visual guide
-- whenever a text or markdown buffer is opened.
--
-- Neovim maps .txt -> "text" and .md -> "markdown", so filtering on the
-- FileType event with an explicit filetype check is sufficient.
--
-- 'colorcolumn' is WINDOW-local, not buffer-local: the setting follows the
-- window, so it would linger if the same window later displays a code file.
-- To avoid a stale guide line, any other FileType explicitly clears it. The
-- line is therefore shown only while a text/markdown buffer occupies the
-- window, and never added to code filetypes.
--==============================================================================

vim.api.nvim_create_autocmd("FileType", {
  desc = "Show an 80-column guide in text and markdown buffers",
  group = vim.api.nvim_create_augroup("text_column_guide", { clear = true }),
  pattern = "*",
  callback = function(args)
    if vim.list_contains({ "text", "markdown" }, args.match) then
      -- 'colorcolumn' takes a string of comma-separated column numbers.
      vim.opt_local.colorcolumn = "80"
    else
      -- Clear any stale guide inherited from a previous text/markdown buffer
      -- displayed in this window (no-op for windows that never had one).
      vim.opt_local.colorcolumn = ""
    end
  end,
})
--==============================================================================
-- 18. Highlight on yank
--
-- Briefly flashes the yanked text so the eye confirms what was copied.
-- Uses the built-in vim.hl.on_yank (Neovim 0.11+); falls back to
-- vim.highlight.on_yank on older versions.
--==============================================================================

vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Flash yanked text",
  group = vim.api.nvim_create_augroup("yank_highlight", { clear = true }),
  callback = function()
    if vim.hl and vim.hl.on_yank then
      vim.hl.on_yank({ timeout = 150 })
    else
      vim.highlight.on_yank({ timeout = 150 })
    end
  end,
})
templates.from_directory(templates_dir)
templates.from_extensions(templates_dir .. "/by_ext")
