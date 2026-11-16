--==============================================================================
-- utils/templates.lua  -  Template engine
--
-- Converts plain source files into file templates. For every file found in a
-- template directory, a BufNewFile autocmd is registered so that creating a
-- new file matching its pattern pre-fills the contents from the template.
--
-- Two matching modes, one per directory level:
--   lua/templates/           EXACT filename match:
--                            "package.json" fills only package.json, never
--                            foobar.json. Extensionless files (Makefile,
--                            Dockerfile) and dotfiles (".gitignore") work
--                            naturally.
--   lua/templates/by_ext/    LAZY extension match:
--                            the filetype is the LAST extension of the
--                            template's full name: "systemd.service" fills
--                            any *.service file, "spec" fills any *.spec.
--                            Full descriptive names keep many templates
--                            maintainable (e.g. systemd.service,
--                            systemd.socket, systemd.timer).
--                            Optional "@filetype" suffix forces the nvim
--                            filetype of the filled buffer, e.g.
--                            "systemd.service@systemd".
--
-- To add a template: drop a source file into the right folder and restart
-- (the loader lives in config/autocmds.lua). Custom directories work too via
-- M.from_directory() / M.from_extensions().
--
-- Variables: templates may reference $VAR or ${VAR} placeholders:
--   $FILENAME  full file name of the new file      $BASENAME  name w/o extension
--   $FILEEXT   extension of the new file           $AUTHOR    git config user.name
--   $USER      OS user                             $YEAR      current year
--   $DATE      YYYY-MM-DD                          $TIME      HH:MM
--   plus any custom keys passed via opts.variables.
--
-- API:
--   template.from_directory(dir, opts)   register every file in dir by its
--                                        exact name (e.g. "package.json")
--   template.from_extensions(dir, opts)  register every file in dir by
--                                        extension (e.g. "spec" -> "*.spec")
--   Both return the list of registered templates (for diagnostics).
--==============================================================================

local M = {}

-- Augroup owning every template autocmd.
local augroup = vim.api.nvim_create_augroup("templates", { clear = true })

-- Cached author name (from vim.g.templates_author or git config user.name).
local author

-- Resolve the author used by the $AUTHOR placeholder.
local function get_author()
  if author then
    return author
  end
  local g = vim.g.templates_author
  if type(g) == "string" and g ~= "" then
    author = g
  else
    local out = vim.fn.system({ "git", "config", "user.name" }):gsub("%s+$", "")
    author = (vim.v.shell_error == 0 and out ~= "") and out or vim.env.USER or ""
  end
  return author
end

-- Substitute $VAR and ${VAR} placeholders using the vars table.
-- Unknown placeholders are left untouched (string.gsub table semantics).
-- @param content (string): raw template text
-- @param vars (table): key -> value lookup
-- @return (string): rendered template
local function render(content, vars)
  content = content:gsub("%${([%w_]+)}", vars)
  content = content:gsub("%$([%w_]+)", vars)
  return content
end

-- Read a template file at event time (not at registration), so edits to the
-- source files apply to future buffers without a restart.
-- @param path (string): absolute path to the template file
-- @return (table): lines ready for nvim_buf_set_lines
local function read_template(path)
  local handle = io.open(path, "rb")
  if not handle then
    vim.notify("templates: cannot read " .. path, vim.log.levels.WARN)
    return nil
  end
  local content = handle:read("*a")
  handle:close()

  -- Split on "\n"; strip the trailing empty element from a final newline.
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  -- Normalise CRLF templates to LF buffer lines.
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\r$", "")
  end
  return lines
end

-- Register a single template: fill new buffers matching `pattern` from
-- the source file at `path`.
-- @param path (string): absolute path to the template source file
-- @param pattern (string): BufNewFile autocmd pattern (e.g. "*.py")
-- @param opts (table|nil): { filetype = string, variables = table }
local function register(path, pattern, opts)
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = augroup,
    pattern = pattern,
    desc = "templates: pre-fill new file from " .. vim.fn.fnamemodify(path, ":t"),
    callback = function(event)
      local lines = read_template(path)
      if not lines then
        return
      end

      -- Builtin variables describing the new file.
      local fname = vim.fn.fnamemodify(event.file, ":t")
      local vars = {
        FILENAME = fname,
        BASENAME = vim.fn.fnamemodify(fname, ":r"),
        FILEEXT = vim.fn.fnamemodify(fname, ":e"),
        AUTHOR = get_author(),
        USER = vim.env.USER or "",
        YEAR = os.date("%Y"),
        DATE = os.date("%Y-%m-%d"),
        TIME = os.date("%H:%M"),
      }
      -- Merge user-provided variables (override builtins).
      for key, value in pairs(opts.variables or {}) do
        vars[key] = value
      end

      local rendered = vim.split(render(table.concat(lines, "\n"), vars), "\n", { plain = true })
      if rendered[#rendered] == "" then
        table.remove(rendered)
      end

      vim.api.nvim_buf_set_lines(0, 0, -1, false, rendered)

      -- Optionally force a filetype (default: builtin detection).
      if opts.filetype then
        vim.bo.filetype = opts.filetype
      end
    end,
  })
end

-- Escape regex-magic characters so a pattern matches a literal name.
-- Patterns without "/" are matched against the tail of the new file's path,
-- so "package.json" hits foo/bar/package.json.
-- @param name (string): file name to escape
-- @return (string): pattern matching that exact name
local function literal(name)
  return vim.fn.escape(name, "~*\\[]{}?.^$")
end

-- Wrapper: register every source file in a directory as an exact-name
-- template.
--
-- Matching is by EXACT filename: a template named "package.json" fills a
-- new file only when it is literally named package.json, never foobar.json.
-- Extensionless files (Makefile, Dockerfile) and dotfiles (".gitignore")
-- work naturally.
--
-- @param dir (string): absolute path to the directory of source files
-- @param opts (table|nil): passed through to register(); may also contain
--   opts.on_register(name, pattern) called for each template
-- @return (table): list of { name = ..., pattern = ... } registered
function M.from_directory(dir, opts)
  opts = opts or {}
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    vim.notify("templates: directory not found: " .. dir, vim.log.levels.WARN)
    return {}
  end

  local registered = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" then
      local pattern = literal(name)
      register(dir .. "/" .. name, pattern, opts)
      table.insert(registered, { name = name, pattern = pattern })
      if opts.on_register then
        opts.on_register(name, pattern)
      end
    end
  end
  return registered
end

-- Wrapper: register every file in a directory as an extension-based template.
--
-- The filetype is extracted from the LAST extension of the full name, so
-- templates can use descriptive full filenames:
--   "systemd.service" -> "service" -> fills any "*.service" file
--   "spec"            -> "spec"    -> fills any "*.spec" file
--   ".gitignore"      -> "gitignore" -> fills any "*.gitignore" file
--
-- An optional "@filetype" suffix forces the nvim filetype of the filled
-- buffer (useful when the extension has no builtin detection, e.g. nvim
-- does not detect systemd units from *.service alone):
--   "systemd.service@systemd" -> matches "*.service", sets ft = systemd
--
-- @param dir (string): absolute path to the directory of template files
-- @param opts (table|nil): passed through to register(); may also contain
--   opts.on_register(name, pattern) called for each template
-- @return (table): list of { name = ..., pattern = ... } registered
function M.from_extensions(dir, opts)
  opts = opts or {}
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    vim.notify("templates: directory not found: " .. dir, vim.log.levels.WARN)
    return {}
  end

  local registered = {}
  local seen = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" then
      -- Optional "@filetype" annotation: "systemd.service@systemd" ->
      -- match name "systemd.service", forced filetype "systemd".
      local base, ft_override = name:match("^(.-)@([%w_+%-]+)$")
      base = base or name

      -- Filetype = last extension of the match name ("systemd.service" ->
      -- "service"). No extension at all -> the whole name ("spec").
      local ft = base:match("%.([%w_+%-]+)$") or base

      -- Two templates mapping to the same filetype silently override each
      -- other (same pattern, later autocmd wins) -- surface that.
      if seen[ft] then
        vim.notify(
          ("templates: %s and %s both map to *.%s; only one wins"):format(seen[ft], name, ft),
          vim.log.levels.WARN
        )
      else
        seen[ft] = name
      end

      -- Per-file opts: the @filetype annotation wins over a dir-wide default.
      local file_opts = opts
      if ft_override then
        file_opts = vim.tbl_extend("force", opts, { filetype = ft_override })
      end

      local pattern = "*." .. literal(ft)
      register(dir .. "/" .. name, pattern, file_opts)
      table.insert(registered, { name = name, pattern = pattern })
      if opts.on_register then
        opts.on_register(name, pattern)
      end
    end
  end
  return registered
end

return M
