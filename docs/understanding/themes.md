# Themes

Vibranium includes a theme system that controls the appearance of the entire desktop.
Themes can be switched from the theme picker with ++ctrl+alt+t++. The currently active theme is highlighted.

Additional themes can be installed through **Vibranium Menu** -> **Install** -> **Theme**.  
Community themes are distributed through repositories following the `vibranium-theme-*` naming scheme.

## Theme structure

Vibranium supports two types of themes:

- **Families** — collections of related variants.
- **Standalone themes** — complete themes without variants.

A family contains multiple flavors, such as different light and dark variants.

Example:

| Type | Examples |
| --- | --- |
| Catppuccin family | Mocha, Macchiato, Frappé, Latte |
| Gruvbox family | Hard, Medium, Soft, Light |
| Standalone themes | Dracula, Deep Forest, Ristretto |

## Omarchy theme support

Vibranium supports compatible Omarchy themes.
Supported themes are those using the newer Base16-style format with the `colors.toml` file.
This file provides the color information required for Vibranium to generate its own application configurations.

Compatible community themes can be found at:

- [omarchythemes.com](https://omarchythemes.com/)
- [omarchy.deepaknes.com](https://omarchy.deepakness.com/themes)
- [awesome-omarchy.com](https://awesome-omarchy.com/)
- [Omarchy theme GitHub topic](https://github.com/topics/omarchy-theme)

## Installing community themes

Open **Vibranium Menu** -> **Install** -> **Theme**.

The installer accepts theme URLs or repository shortcuts.
Before installation, Vibranium checks that the theme has the required structure. Unsupported themes are rejected before installation.
After installation, the theme applies instantly and becomes available in the picker.


You also can just copy-paste the installation command from a theme's README.md page like so:

```bash
omarchy-theme-install <URL>
```

## Removing themes

Open **Vibranium Menu** -> **Remove** -> **Theme**.

Select the theme you want to remove.
If the active theme is removed, Vibranium switches to the default one (Nightfox).

## Theme hooks

See [Hooks](../user/hooks.md).

## Applications requiring manual activation

Some applications require a one-time setup step.

### [Obsidian](https://obsidian.md)

In Obsidian, open **Settings** -> **Appearance**.
Select the **Vibranium** theme.

If it is not available, switch themes once and reopen the settings window so the generated theme becomes visible.

### VS Code and compatible editors

Supported editors include:

- VS Code
- VS Code Insiders
- VSCodium
- VSCodium Insiders
- Cursor

Enable the **Vibranium** extension from the Extensions view.

After activation, editor themes follow Vibranium theme changes automatically.

> See [VS Code theme](../user/vscode-theme.md).

!!! warning "Your entire workspace will reload"
    Due to limitations of VS Code-compatible editors, Vibranium cannot reload only the color theme.
    Applying a new theme reloads the entire workspace, which also restarts LSPs, linters, and other editor integrations.

    If this behavior is not acceptable, disable the Vibranium extension.

## Creating your own theme

Creating a Vibranium theme does not require manually editing every application configuration. 
A theme palette can generate the required application themes automatically.

See:

- [Making your own theme](making-your-own-theme.md)
- [The theme engine](../internals/theme-engine.md)
