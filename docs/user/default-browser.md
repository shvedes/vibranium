# Default browser

Vibranium provides a simple way to configure your default web browser.

## Changing the default browser

Open **Vibranium Menu** -> **Settings** -> **Misc** -> **Default browser**.

The menu displays all supported browsers detected on your system. Selecting one updates the system-wide default browser for web links.

If your preferred browser does not appear in the list, you can configure it manually as described below.

## Manual configuration

If your browser is not currently supported by Vibranium, register its `.desktop` file with `xdg-mime`:

```bash
# Find the browser's desktop file
pacman -Ql <browser_package> | grep -oE '/.*\.desktop'

# Register it as the default browser
xdg-mime default "<browser>.desktop" x-scheme-handler/http
xdg-mime default "<browser>.desktop" x-scheme-handler/https
```

Most applications recognize the new default immediately without requiring a logout or reboot.

## What uses the default browser

The configured default browser is used for:

- Web links opened from applications
- `xdg-open` requests
- Vibranium's web search feature
