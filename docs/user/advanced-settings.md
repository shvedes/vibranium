# Advanced settings

Vibranium uses two configuration layers stored under `~/.config/vibranium/`:

- `settings`
- `settings.advanced`
  - `settings.functions`

## `settings`

`settings` is an automatically maintained file. It must not be edited manually.

It contains values changed through **Vibranium Menu -> Settings** and is managed by Vibranium. Manual changes may be overwritten.

## `settings.advanced`

`settings.advanced` is the manual configuration layer intended for users who need control over advanced Vibranium behavior.

Unlike `settings`, this file is not generated or maintained automatically. It is designed for direct editing and allows overriding internal defaults, changing runtime behavior, and configuring features that are intentionally not exposed through the normal settings interface.

The file is used by internal Vibranium components, including:

- `vb-theme-set-templates`
- other scripts that require advanced configuration

Typical use cases include:

- overriding theme behavior
- extending launcher functionality
- modifying internal processing rules
- applying low-level customizations

The file contains Bash variables and arrays. The exact structure may change between releases.

Each configuration entry belongs to a specific internal component located under $VIBRANIUM_PATH.

Some entries may use custom string formats that are not intended to be interpreted directly by Bash. These values are parsed by the component that owns them. Modifying their format without understanding the parser may break the related functionality.

`settings.advanced` contains extensive inline documentation. Refer to the comments inside the file before changing any values.

## `settings.functions`

`settings.functions` is an extension file used together with `settings.advanced`.

Scripts supporting advanced configuration load files in this order:

1. `settings.functions`
2. `settings.advanced`

It is intended for storing custom Bash functions that can be referenced by advanced configuration entries.

For example, custom launcher actions may call functions defined in `settings.functions`.

Functions can technically be placed directly inside `settings.advanced`, but this is discouraged. Keeping user-defined logic separated from configuration values makes the setup easier to maintain and prevents custom code from being mixed with Vibranium's configuration.

---

# Configuration areas

`settings.advanced` currently provides several configuration areas.

## Template overrides

Controls which files should always be generated from Vibranium templates, even if the selected theme provides its own version.

Normally, theme-provided files take priority. This setting allows forcing specific files to use Vibranium's template system instead.

This is useful for maintaining consistent generated files across themes or for overriding theme-specific implementations.

---

## Theme filtering

Controls which built-in themes are displayed in the Vibranium theme picker.

Hidden themes remain installed and unchanged. This setting only affects visibility in the picker.

It supports filtering individual themes, theme groups, and patterns using Bash-style wildcard matching.
