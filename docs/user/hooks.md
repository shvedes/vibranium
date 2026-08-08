# Hooks

Vibranium supports user-defined hooks that allow extending its behavior without modifying internal scripts.

At the time of writing, four hook types are available:

- theme
- startup
- shutdown
- update

Each hook type is represented by a directory containing one or more `.sh` scripts.

All scripts found in a hook directory are executed in alphanumerical order.  
Use filenames such as `00-init.sh`, `10-example.sh`, and `99-cleanup.sh` to control execution order.

Unless stated otherwise, hooks are started asynchronously. Each script is detached from the controlling terminal before execution, so the caller does not wait for it to finish. Hooks should therefore not rely on one another unless the documentation for that hook type explicitly guarantees execution order.

If both Vibranium and the user provide hooks of the same type, Vibranium's built-in hooks are executed first, followed by the user's hooks.

## Theme

**Caller:** `vb-theme-set`

**Directories:**

- `$XDG_CONFIG_HOME/vibranium/hooks/theme/`

Executed after every successful theme change.  
Each hook receives the selected theme through the `$THEME` environment variable. The value is the theme's directory name, for example:

```text
Catppuccin Mocha -> catppuccin-mocha
```

The complete list of theme identifiers can be viewed with:

```bash
vb-theme-set --list
```

This hook type is intended for applying theme changes to software that is not directly supported by Vibranium.

An `example.sh` file is provided in the hook directory as a reference implementation.

## Startup

**Caller:** `vb-util-startup`

**Directories:**

- `$VIBRANIUM/default/hooks/startup/`
- `$XDG_CONFIG_HOME/vibranium/hooks/startup/`

Executed once during every desktop session startup.

Startup hooks run after the user session and its environment have been fully initialized.

## Shutdown

**Caller:** `vb-core-stop-session`

**Directories:**

- `$XDG_CONFIG_HOME/vibranium/hooks/shutdown/`

Executed immediately before the session terminates.

Unlike other hook types, shutdown hooks are executed synchronously. Each script must finish before the next one starts, and the caller waits for all hooks to complete before ending the session.

Long-running shutdown hooks will delay session termination.

## Update

**Caller:** `vb-pkg-update`

**Directories:**

- `$XDG_CONFIG_HOME/vibranium/hooks/update/`

Executed after a successful system update.
