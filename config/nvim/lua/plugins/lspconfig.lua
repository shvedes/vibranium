--==============================================================================
-- plugins/lspconfig.lua  -  LSP server configuration (nvim-lspconfig + Mason)
--
-- Plugin: neovim/nvim-lspconfig
--
-- Central LSP configuration for ~20 language servers. Key design decisions:
--   1. Servers are defined in a single `servers` table keyed by server name.
--      Adding a new entry = auto-install and enable.
--   2. Mason manages the actual server binaries. On first FileType match,
--      the server is installed automatically.
--   3. blink.cmp capabilities are merged into every server config.
--   4. Buffer-local keymaps are set on LspAttach, not at setup time.
--   5. Extra non-LSP Mason packages (shellcheck etc.) are installed per filetype.
--==============================================================================

return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    -- Mason installs and manages the actual language server binaries.
    -- lspconfig only ships the connection definitions; it does not install anything.
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",

    -- Shared JSON/YAML schema catalog (SchemaStore) consumed by jsonls and
    -- yamlls. Pure data, no setup() call required.
    --
    -- NOTE: blink.cmp is deliberately NOT a dependency here. Listing it made
    -- lazy load the completion engine whenever this plugin loads (BufReadPre),
    -- i.e. on every file open, defeating blink's own InsertEnter trigger.
    -- Its capabilities come from utils/lsp_caps.lua instead.
    "b0o/schemastore.nvim",
  },

  config = function()
    local lsp = vim.lsp

    -- Deliberately NO require("lspconfig"): only the legacy lspconfig.<name>.setup
    -- API needs it, and this config uses vim.lsp.config/vim.lsp.enable. Neovim
    -- 0.11+ resolves lsp/<name>.lua straight from the runtimepath, so loading the
    -- shim cost ~8.5ms on the first buffer open for nothing (measured).

    --==========================================================================
    -- Server definitions
    --==========================================================================
    -- Central registry. Add a server here and it is installed, configured,
    -- and enabled automatically. Anything omitted falls back to the defaults
    -- shipped in nvim-lspconfig's lsp/<name>.lua files.
    local servers = {
      lua_ls = {
        -- Custom root_dir: ensures .luarc.json inside the nvim config tree
        -- never gets hijacked by a project-level .luarc.json from an unrelated
        -- ancestor directory.
        root_dir = function(bufnr, on_dir)
          local fname = vim.api.nvim_buf_get_name(bufnr)
          local config_dir = vim.fn.stdpath("config")

          -- Buffers inside the nvim config tree always root here.
          if vim.startswith(fname, config_dir) then
            on_dir(config_dir)
            return
          end

          -- Search upward for .luarc.json or .luarc.jsonc.
          local luarc = vim.fs.find(
            { ".luarc.json", ".luarc.jsonc" },
            { path = vim.fs.dirname(fname), upward = true, stop = vim.uv.os_homedir() }
          )[1]

          if luarc then
            on_dir(vim.fs.dirname(luarc))
          else
            on_dir(config_dir)
          end
        end,

        -- before_init: if the root is $HOME, disable preloading (avoids
        -- indexing the entire home directory).
        before_init = function(params)
          local uri = params.rootUri
          local root
          if type(uri) == 'string' then
            root = vim.uri_to_fname(uri)
          elseif type(params.rootPath) == 'string' then
            root = params.rootPath
          end
          if root == vim.fn.expand("$HOME") then
            params.initializationOptions = vim.tbl_deep_extend("force", params.initializationOptions or {}, {
              Lua = { workspace = { maxPreload = 0, preloadFileSize = 0 } },
            })
          end
        end,

        -- on_init: apply workspace settings after server initialisation.
        on_init = function(client)
          local path = client.workspace_folders and client.workspace_folders[1].name
          if path then
            if path ~= vim.fn.stdpath("config") and (vim.uv.fs_stat(path .. "/.luarc.json") or vim.uv.fs_stat(path .. "/.luarc.jsonc")) then
              return
            end
            if path == vim.fn.expand("$HOME") then
              return
            end
          end
          client.config.settings.Lua = vim.tbl_deep_extend("force", client.config.settings.Lua or {}, {
            runtime = { version = "LuaJIT" },
            workspace = { checkThirdParty = false, library = { vim.env.VIMRUNTIME } },
          })
        end,

        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            diagnostics = { globals = { "vim" } },
            workspace = { checkThirdParty = false, library = { vim.env.VIMRUNTIME } },
            telemetry = { enable = false },
            hint = { enable = true },
          },
        },
      },

      rust_analyzer = {
        settings = {
          ["rust-analyzer"] = {
            cargo = { allFeatures = true },
            checkOnSave = true,
            check = { command = "clippy" },
            inlayHints = {
              lifetimeElisionHints = { enable = true, useParameterNames = true },
            },
          },
        },
      },

      pyright = {
        settings = {
          python = {
            analysis = {
              typeCheckingMode = "basic",
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
            },
          },
        },
      },

      -- Linting/formatting complement to pyright. ruff covers style, unused
      -- imports, and fast autofixes. Hover/goto-definition are disabled here
      -- so pyright stays authoritative for those, avoiding duplicate results.
      ruff = {
        init_options = {
          settings = {
            lineLength = 100,
          },
        },
        on_attach = function(client)
          client.server_capabilities.hoverProvider = false
        end,
      },

      -- bash-language-server can delegate diagnostics to shellcheck when
      -- shellcheckPath is set. The shellcheck binary itself is installed
      -- separately by Mason as a non-LSP package (see extra_mason_pkgs below).
      bashls = {
        settings = {
          bashIde = {
            shellcheckPath = "shellcheck",
            shellcheckArguments = { "-e", "SC1091" },
            backgroundAnalysisMaxFiles = 500,
            globPattern = "**/*@(.sh|.inc|.bash|.command)",
          },
        },
      },

      awk_ls = {},

      -- SchemaStore supplies the catalog (package.json, tsconfig.json,
      -- GitHub Actions workflows, etc). Parsing it costs ~2-3ms (1.5k+ JSON
      -- schemas), and it used to happen while this plugin loaded -- for every
      -- file, whatever its type. Injecting it from before_init instead defers
      -- the cost to the moment a jsonls/yamlls client actually starts.
      --
      -- before_init mutates `config.settings` in place: client.settings holds
      -- the same table reference (vim/lsp/client.lua assigns it before calling
      -- the callback), so nested assignment here is what the server sees in
      -- workspace/configuration.
      jsonls = {
        settings = {
          json = { validate = { enable = true } },
        },
        before_init = function(_, config)
          config.settings.json.schemas = require("schemastore").json.schemas()
        end,
      },

      yamlls = {
        settings = {
          yaml = {
            schemaStore = {
              -- Disable yamlls's own downloader; schemastore.nvim supplies
              -- the catalog locally instead.
              enable = false,
              url = "",
            },
            keyOrdering = false,
            format = { enable = true },
          },
        },
        before_init = function(_, config)
          config.settings.yaml.schemas = require("schemastore").yaml.schemas()
        end,
      },

      taplo = {},
      dockerls = {},
      docker_compose_language_service = {},

      marksman = {},

      gopls = {
        settings = {
          gopls = {
            gofumpt = true,
            staticcheck = true,
            analyses = {
              unusedparams = true,
              shadow = true,
            },
            hints = {
              assignVariableTypes = true,
              compositeLiteralFields = true,
              constantValues = true,
              parameterNames = true,
              rangeVariableTypes = true,
            },
          },
        },
      },

      clangd = {
        cmd = {
          "clangd",
          "--background-index",
          "--clang-tidy",
          "--header-insertion=iwyu",
          "--completion-style=detailed",
          "--function-arg-placeholders",
          "--fallback-style=llvm",
        },
        init_options = {
          usePlaceholders = true,
          completeUnimported = true,
          clangdFileStatus = true,
        },
      },

      cmake = {
        init_options = {
          buildDirectory = "build",
        },
      },

      sqlls = {},

      ts_ls = {
        settings = {
          typescript = {
            inlayHints = {
              includeInlayParameterNameHints = "all",
              includeInlayFunctionParameterTypeHints = true,
              includeInlayVariableTypeHints = true,
              includeInlayPropertyDeclarationTypeHints = true,
              includeInlayFunctionLikeReturnTypeHints = true,
              includeInlayEnumMemberValueHints = true,
            },
          },
          javascript = {
            inlayHints = {
              includeInlayParameterNameHints = "all",
              includeInlayFunctionParameterTypeHints = true,
              includeInlayVariableTypeHints = true,
              includeInlayPropertyDeclarationTypeHints = true,
              includeInlayFunctionLikeReturnTypeHints = true,
            },
          },
        },
      },

      -- Runs alongside ts_ls: ts_ls covers the TS language service
      -- (types, refactors), eslint covers project lint rules.
      eslint = {
        settings = {
          workingDirectories = { mode = "auto" },
        },
      },

      html = {},

      cssls = {
        settings = {
          css = { validate = true, lint = { unknownAtRules = "ignore" } },
          scss = { validate = true, lint = { unknownAtRules = "ignore" } },
          less = { validate = true },
        },
      },

      tailwindcss = {},
    }

    --==========================================================================
    -- Extra non-LSP Mason packages
    --==========================================================================
    local extra_mason_pkgs = {
      sh = { "shellcheck" },
      bash = { "shellcheck" },
    }

    --==========================================================================
    -- Diagnostic configuration (global)
    --==========================================================================
    vim.diagnostic.config({
      severity_sort = true,
      -- Square corners like every other popup (options.lua sets winborder =
      -- "single"); an explicit "rounded" here is the one thing that overrode it.
      float = { border = "single", source = true },
      underline = true,
      update_in_insert = false,
      virtual_text = { spacing = 4, source = "if_many", prefix = "*" },
      signs = {
        text = {
          [vim.diagnostic.severity.ERROR] = "E",
          [vim.diagnostic.severity.WARN]  = "W",
          [vim.diagnostic.severity.INFO]  = "I",
          [vim.diagnostic.severity.HINT]  = "H",
        },
      },
    })

    -- Hover (K) and signature help (gs) use the same squared frame.
    -- vim.lsp.with merges the border into the handler defaults.
    vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "single" })
    vim.lsp.handlers["textDocument/signatureHelp"] =
      vim.lsp.with(vim.lsp.handlers.signature_help, { border = "single" })

    --==========================================================================
    -- Capabilities (blink.cmp-compatible, without loading blink.cmp)
    --==========================================================================
    local capabilities = require("utils.lsp_caps").get()

    --==========================================================================
    -- Mason setup
    --==========================================================================
    -- mason.nvim itself is set up by its own spec (lua/plugins/mason.lua), which
    -- gives it a `cmd` stub so :Mason works before any file is opened. Only the
    -- lspconfig bridge is configured here.
    -- automatic_enable is off: every server below is registered with
    -- vim.lsp.config() and started by vim.lsp.enable() a few lines down, which
    -- is exactly what mason-lspconfig's automatic_enable would do again -- but
    -- it builds its list synchronously inside setup() (measured ~8ms on the
    -- first file open). Keeping it on duplicated the work and could start a
    -- server before our own config was applied.
    require("mason-lspconfig").setup({
      automatic_enable = false,
    })

    --==========================================================================
    -- Register server configs and enable them
    --==========================================================================
    for name, opts in pairs(servers) do
      opts.capabilities = vim.tbl_deep_extend("force", capabilities, opts.capabilities or {})
      lsp.config(name, opts)
    end

    lsp.enable(vim.tbl_keys(servers))

    --==========================================================================
    -- Auto-install servers per-filetype
    --==========================================================================
    local server_names = vim.tbl_keys(servers)

    -- Mapping lookup is deferred: get_mason_map() rebuilds its tables on every
    -- call (~4ms, not memoised upstream) and is only needed when a buffer's
    -- filetype matches a configured server. mason-lspconfig's async registry
    -- refresh may build it first, in which case this call is simply free.
    local mason_map
    local function mason_package_for(server_name)
      if not mason_map then
        mason_map = require("mason-lspconfig.mappings").get_mason_map().lspconfig_to_package
      end
      return mason_map[server_name]
    end

    -- Rebuild mapping when registry finishes loading (fixes first-launch race
    -- where the registry cache hasn't been downloaded yet).
    local mason_registry = require("mason-registry")
    mason_registry:on("update:success", function()
      mason_map = nil -- rebuild the mapping on next lookup
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local ft = vim.bo[buf].filetype
            for _, cfg in ipairs(vim.lsp.get_configs()) do
              if servers[cfg.name] and cfg.filetypes then
                for _, f in ipairs(cfg.filetypes) do
                  if f == ft then
                    pcall(vim.lsp.start, cfg, { bufnr = buf })
                    break
                  end
                end
              end
            end
          end
        end
      end)
    end)

    -- Install servers on demand per filetype instead of all at once.
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("MasonAutoInstall", { clear = true }),
      callback = function(args)
        local ft = args.match

        -- Install extra non-LSP packages (CLI tools like shellcheck).
        if extra_mason_pkgs[ft] then
          for _, name in ipairs(extra_mason_pkgs[ft]) do
            local mr = require("mason-registry")
            if not mr.is_installed(name) then
              local ok, pkg = pcall(mr.get_package, name)
              if ok and pkg and not pkg:is_installing() then
                vim.notify(("[mason] Installing %s"):format(pkg.name), vim.log.levels.INFO, { id = "mason-install-" .. pkg.name })
                pcall(pkg.install, pkg)
              end
            end
          end
        end

        -- Install LSP server packages that match the current filetype.
        for _, server_name in ipairs(server_names) do
          local cfg = lsp.config[server_name]
          if cfg and cfg.filetypes and vim.list_contains(cfg.filetypes, ft) then
            local pkg_name = mason_package_for(server_name)
            if pkg_name then
              local mr = require("mason-registry")
              if not mr.is_installed(pkg_name) then
                local ok, pkg = pcall(mr.get_package, pkg_name)
                if ok and pkg and not pkg:is_installing() then
                  local notif_id = "mason-install-" .. pkg.name
                  vim.notify(("[mason] Installing %s"):format(pkg.name), vim.log.levels.INFO, { id = notif_id })
                  pcall(pkg.install, pkg, {}, function(success, err)
                    if not success then
                      local err_msg = type(err) == "string" and err or tostring(err)
                      -- If the error is a PATH/not-found issue, show a friendlier message.
                      if err_msg:find("PATH")
                        or err_msg:find("not find")
                        or err_msg:find("not installed")
                        or err_msg:find("executable")
                        or err_msg:find("missing")
                      then
                        local bin = err_msg:match('executable%s+"([^"]+)"')
                          or err_msg:match('spawn:%s*([%w_-]+)')
                          or pkg.name
                        vim.schedule(function()
                          vim.notify(
                            ("[mason] %s: %q not found in PATH"):format(pkg.name, bin),
                            vim.log.levels.WARN,
                            { id = notif_id }
                          )
                        end)
                      end
                    end
                  end)
                end
              end
            end
          end
        end
      end,
    })

    --==========================================================================
    -- LspAttach: buffer-local keymaps and behavior
    --==========================================================================
    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("UserLspAttach", { clear = true }),
      callback = function(event)
        local bufnr = event.buf
        local client = lsp.get_client_by_id(event.data.client_id)

        -- Helper to define buffer-local mappings.
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end

        -- Navigation
        map("n", "gd", vim.lsp.buf.definition, "Go to definition")
        map("n", "gD", vim.lsp.buf.declaration, "Go to declaration")
        map("n", "gi", vim.lsp.buf.implementation, "Go to implementation")
        map("n", "go", vim.lsp.buf.type_definition, "Go to type definition")
        map("n", "gr", vim.lsp.buf.references, "List references")
        map("n", "gs", vim.lsp.buf.signature_help, "Signature help")
        map("n", "K",  vim.lsp.buf.hover, "Hover documentation")
        map("n", "<leader>rn", vim.lsp.buf.rename, "Rename symbol")
        map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, "Code action")
        -- <leader>cf is deliberately NOT mapped here. A buffer-local mapping
        -- would shadow the global one from lua/plugins/conform.lua, so the
        -- conform formatters (stylua/ruff/prettier/...) never ran and only the
        -- LSP formatter did. conform.format() covers the LSP case anyway via
        -- lsp_fallback = true.

        -- Diagnostics navigation. These two are buffer-local, so they shadow
        -- any global mapping with the same lhs: trouble.nvim's list viewers
        -- therefore live on <leader>dQ / <leader>dL (see plugins/trouble.lua).
        map("n", "]d", function() vim.diagnostic.jump({ count = 1, float = true }) end, "Next diagnostic")
        map("n", "[d", function() vim.diagnostic.jump({ count = -1, float = true }) end, "Previous diagnostic")
        map("n", "<leader>dl", vim.diagnostic.open_float, "Line diagnostics")
        map("n", "<leader>dq", vim.diagnostic.setloclist, "Diagnostics to loclist")

        -- Inlay hints toggle (only if the server supports textDocument/inlayHint).
        if client and client:supports_method("textDocument/inlayHint") then
          map("n", "<leader>th", function()
            local enabled = lsp.inlay_hint.is_enabled({ bufnr = bufnr })
            lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
          end, "Toggle inlay hints")
        end

        -- Document highlight: highlight references under cursor on CursorHold,
        -- clear on CursorMoved.
        if client and client:supports_method("textDocument/documentHighlight") then
          local highlight_group = vim.api.nvim_create_augroup(
            "UserLspHighlight" .. bufnr,
            { clear = true }
          )
          vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
            buffer = bufnr,
            group = highlight_group,
            callback = vim.lsp.buf.document_highlight,
          })
          vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            buffer = bufnr,
            group = highlight_group,
            callback = vim.lsp.buf.clear_references,
          })
        end
      end,
    })
  end,
}
