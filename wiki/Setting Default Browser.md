## Vibranium Way

`Vibranium Menu -> Settings -> Misc -> Default Browser`

Vibranium tries to cover as many browsers as possible. If you don’t see your preferred browser in the list, feel free to open an issue.

## Manual Way

First, find the corresponding `.desktop` file for your browser in `/usr/share/applications`. If you're unsure, you can list all files installed by the package with:

```bash
pacman -Ql <browser_package> | grep -oE '/.*\.desktop'
```

Then register with `xdg-mime`:

```bash
xdg-mime default "<browser>.desktop" x-scheme-handler/https
xdg-mime default "<browser>.desktop" x-scheme-handler/http
```

No restart nor re-login required.