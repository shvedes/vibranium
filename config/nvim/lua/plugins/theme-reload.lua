return {
  {
    name = "theme-hotreload",
    dir = vim.fn.stdpath("config"),
    lazy = false,
    priority = 1000,
    config = function()
      local transparency_file = vim.fn.stdpath("config") .. "/plugin/after/transparency.lua"

      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyReload",
        callback = function()
          -- Unload the theme module so require() below gets the fresh file off disk
          package.loaded["plugins.theme"] = nil

          vim.schedule(function()
            local ok, theme_spec = pcall(require, "plugins.theme")
            if not ok then
              return
            end

            -- Walk the spec once, pulling out everything we need up front.
            -- We need:
            --   theme_plugin_name  - to locate the plugin dir for module purging
            --   theme_opts         - the opts table from that same spec entry
            --                        (these are the custom color overrides from the template)
            --   colorscheme        - the name string from the LazyVim/LazyVim entry
            local theme_plugin_name = nil
            local theme_opts = nil
            local colorscheme = nil

            for _, spec in ipairs(theme_spec) do
              if spec[1] and spec[1] ~= "LazyVim/LazyVim" then
                -- First non-LazyVim entry is the actual theme plugin
                theme_plugin_name = spec.name or spec[1]
                -- opts holds the colors table that the template rendered into the file;
                -- we must pass it to setup() ourselves since we skip the config function
                theme_opts = spec.opts
              elseif spec[1] == "LazyVim/LazyVim" and spec.opts and spec.opts.colorscheme then
                colorscheme = spec.opts.colorscheme
              end
            end

            -- Nothing to do if we couldn't find a colorscheme
            if not colorscheme then
              return
            end

            -- Clear all highlight groups before applying new theme
            vim.cmd("highlight clear")
            if vim.fn.exists("syntax_on") then
              vim.cmd("syntax reset")
            end

            -- Reset background so the incoming colorscheme can set it correctly
            vim.o.background = "dark"

            -- Purge every Lua module that belongs to the theme plugin so the
            -- next require() loads fresh bytecode from disk (picks up any upstream
            -- changes as well as our setup() call below)
            if theme_plugin_name then
              local plugin = require("lazy.core.config").plugins[theme_plugin_name]
              if plugin then
                local plugin_dir = plugin.dir .. "/lua"
                require("lazy.core.util").walkmods(plugin_dir, function(modname)
                  package.loaded[modname] = nil
                  package.preload[modname] = nil
                end)
              end
            end

            -- Load the plugin (makes its Lua files available for require())
            require("lazy.core.loader").colorscheme(colorscheme)

            vim.defer_fn(function()
              -- Re-run setup() with the opts from the spec BEFORE applying the
              -- colorscheme.  This is the step the original code was missing:
              -- vim.cmd.colorscheme triggers the colorscheme's init path which
              -- reads whatever was passed to setup(); skipping this meant aether
              -- always started with its compiled-in defaults instead of the
              -- template-rendered color overrides.
              if theme_opts then
                -- pcall so a bad opts table doesn't abort the rest of the reload
                local setup_ok, setup_err = pcall(function()
                  require(colorscheme).setup(theme_opts)
                end)
                if not setup_ok then
                  vim.notify("theme-hotreload: setup() failed: " .. tostring(setup_err), vim.log.levels.WARN)
                end
              end

              -- Now apply the colorscheme; it will read the state set by setup() above
              pcall(vim.cmd.colorscheme, colorscheme)

              -- Force redraw so statuslines, borders, etc. pick up the new palette
              vim.cmd("redraw!")

              -- Re-source transparency overrides and fire plugin refresh autocmds
              if vim.fn.filereadable(transparency_file) == 1 then
                vim.defer_fn(function()
                  vim.cmd.source(transparency_file)

                  -- Let lualine, bufferline, etc. know the colorscheme changed
                  vim.api.nvim_exec_autocmds("ColorScheme", { modeline = false })
                  vim.api.nvim_exec_autocmds("VimEnter", { modeline = false })

                  vim.cmd("redraw!")
                end, 5)
              end
            end, 5)
          end)
        end,
      })
    end,
  },
}
