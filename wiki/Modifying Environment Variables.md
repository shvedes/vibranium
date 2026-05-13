There are two ways to set and modify your environment variables:

- `Vibranium Menu -> Settings -> Misc -> Edit Env`
- Hyprland config files using the `env =` syntax

The preferred method is, of course, the first one.

Vibranium uses [UWSM](https://github.com/Vladimir-csp/uwsm) as its session manager, so it is responsible for all environment variables you set.  
Do not modify `~/.config/uwsm/env` directly, as it is symlinked to the Vibranium repository and may overwrite your changes on next update. Use `~/.config/vibranium/environment` instead.

This file is essentially a bash script, but under no circumstances should you include any logic beyond simple `export KEY=VAL` lines. First, executing commands will slow down startup. Second, if even a single command fails, your session may fail to start entirely. This file is not intended for that purpose.

Your second option is to use a Hyprland config file with the `env =` syntax.  
To do this, create a file named `env.conf` inside `~/.config/hypr/hyprland.conf.d/` and configure it as needed.  
Follow [this link](https://wiki.hypr.land/Configuring/Environment-variables/) for syntax details.

Keep in mind that this method is not recommended. The preferred approach is `~/.config/vibranium/environment`, handled by UWSM.

Any changes take effect after re-login.