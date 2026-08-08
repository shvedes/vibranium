# Environment variables

Vibranium uses [UWSM](https://github.com/Vladimir-csp/uwsm) as its session manager.  
UWSM manages the session environment, so environment variables are configured in one place and shared by the entire session: Hyprland, applications, and scripts.

## Setting environment variables

The recommended way to add your own variables is through **Vibranium Menu** -> **Settings** -> **Misc** -> **Edit Env**.

This opens your user environment file:

```text
~/.config/vibranium/environment
```

Add variables using standard `export` statements:

```bash
export EDITOR="nvim"
export MY_APP_FLAGS="--fast"
```

!!! warning
    Keep this file limited to simple `export KEY=VALUE` statements. It is not a shell configuration file.  
    Running commands here can slow down session startup or cause the session to fail if a command exits with an error.

## When changes take effect

Environment variables are loaded by UWSM when your graphical session starts.  
After changing them, log out and log back in for the changes to apply.

## Built-in environment

Vibranium configures the required environment automatically, including:

- XDG base directory paths
- Wayland application settings
- Vibranium-specific variables
- Application defaults

Most users do not need to modify these manually.
