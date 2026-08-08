# Packages

Vibranium provides TUI frontends for common package management tasks while preserving the standard Arch Linux workflow.  
Package installation, removal, and updates are available from the **Vibranium Menu**.

## Installing and removing packages

Open **Vibranium Menu** -> **Install** / **Remove** -> **Package**

The package picker displays all available packages in an interactive `fzf` interface.

Navigation:

- Arrow keys or ++ctrl+j++ / ++ctrl+k++ — move selection
- ++tab++ — (un)mark a package
- ++enter++ — confirm selection

The package management wrappers are also scriptable and can be used in other scripts.

```bash
# Install packages
vb-pkg-install --help

# Remove packages
vb-pkg-remove --help
```

## Automatic service handling

When installing a package, Vibranium checks whether it provides one or more systemd units.  
If services are found, you are offered the option to enable them immediately.  

Likewise, before removing a package, Vibranium offers to disable any associated services first.  
This avoids leaving broken or orphaned systemd unit links behind.

## Updating

Updates are available from **Vibranium Menu -> Update**.

Two update actions are provided:

- **Update Vibranium** — updates the Vibranium installation itself
- **Update system** — performs a complete Arch Linux system upgrade

See [Updates & channels](../understanding/updates.md) for details about the Vibranium update process.

## Updates Waybar module

Waybar includes an optional updates module that displays pending Arch and AUR updates.

It can be enabled from **Vibranium Menu -> Settings -> Waybar -> Toggle modules**

The module displays the number of available updates and provides a detailed breakdown in its tooltip.
