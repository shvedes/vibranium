# PWAs & TUIs

Vibranium inherited the webapp and TUI installer ideas from Omarchy and improved them significantly.

## Progressive Web Apps (PWAs)

A PWA — or webapp — is essentially a web page that behaves like a native application: its own window, its own icon, without browser UI.
Vibranium's PWA installer actively tries to fetch everything about the site you give it:

- **Automatic name generation** from the page's metadata
- **Automatic keywords** — XDG-compliant, so the app launcher's category filters work
- **Automatic icon download** from the site's favicon/app icons (credits to Omarchy for the idea)

At every step, if the data can't be fetched, the installer falls back and asks you for input.
Even when everything is auto-detected, you're asked whether to keep the generated values or override them.

### Installing

**Vibranium Menu** -> **Install -> **Webapp** (opens a window), or fully from the CLI:

```bash
vb-webapp-install --help
```

The installer creates a proper `.desktop` entry, an icon, and — optionally — an **isolated profile** (`--own-profile`), so the PWA gets its own cookie store and doesn't share browsing data with your main Chromium profile.
Window rules and focus detection are set up from the class name, so PWAs behave like real apps in the launcher and in `hyprctl` matching.

### Pre-installed PWAs

Vibranium ships several PWAs out of the box: Reddit, GitHub, YouTube, X, plus AI tools like ChatGPT, Grok and Perplexity.
They're all installed but **disabled by default** — flip them on in **Vibranium Menu** -> **Settings** -> **App Launcher**.

## TUI applications

TUIs (text user interfaces) run inside a terminal window — the installer creates a desktop entry that opens them with the right terminal.

- Install: **Vibranium Menu** -> **Install** -> **TUI**, or `vb-tui-install --help` from the CLI
- The installer validates your input so nothing broken gets created
- `--float` makes the TUI open in a floating terminal window

Pre-installed TUIs include [btop](https://github.com/aristocratos/btop), [ncdu](https://dev.yorhel.nl/ncdu), [impala](https://github.com/pythops/impala), [bluetui](https://github.com/pythops/bluetui), and [wiremix](https://github.com/tsowell/wiremix).
Remove the ones you don't need via **Vibranium Menu** -> **Remove** -> **TUI**.

## Removing

**Vibranium Menu** -> **Remove** -> **Webapp** / **TUI** — a multi-select list of what you've installed (or what came pre-installed).
Icons and isolated profiles, and other stale data cleaned up properly.

## Categories

With webapps enabled in the launcher, typing `AI`, `PWA`, or `TUI` filters the list — see [App launcher](app-launcher.md) for the details.
