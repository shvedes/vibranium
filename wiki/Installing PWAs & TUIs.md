Vibranium inherited Omarchy features such as the Webapp and TUI installers, and improved them significantly. You can easily install or remove them via *Vibranium Menu* -> *Install* or *Vibranium Menu* -> *Remove*.

## Progressive Web Apps (PWAs)

[Progressive Web Apps](https://en.wikipedia.org/wiki/Progressive_web_app), or PWAs (or simply web apps), are essentially web pages that behave like native applications. Vibranium’s PWA installer is not just a “give me a link and done” tool. Instead, it attempts to fetch all the relevant data from the provided URL. This includes:

- Automatic PWA name generation  
- Automatic [XDG-compliant](https://specifications.freedesktop.org/desktop-entry/latest/) keyword generation
- Automatic icon download (credits to Omarchy)  

At each step, if the installer cannot retrieve the data, it falls back to a manual prompt, giving you full control. Even when all data is successfully fetched, you are still asked whether to keep the auto-generated values or override them manually.

The installer also supports a full CLI mode. To see all available options, run:

```bash
vb-webapp-install --help
````

Vibranium comes with several PWAs by default: common websites such as Reddit, GitHub, YouTube, or X, as well as AI tools like ChatGPT, Grok, Perplexity, and more. All of them are installed but disabled by default, giving you full control. You can toggle them in *Vibranium Menu* -> *Settings* -> *App Launcher*. For example, you can disable only AI-related PWAs if you want.

## Text User Interface (TUI) Applications

As the name suggests, these applications run inside a terminal window. It may sound trivial, but in practice, it saves time. Instead of opening a terminal and typing commands (and potentially mistyping them), your favorite TUI apps are available directly in the App Launcher (`SUPER A`), alongside PWAs and GUI applications.

The installer will guide you through a few steps and validate your input to ensure everything works correctly. Once created, the TUI app will appear in the app menu.

Like the PWA installer, the TUI installer also supports a CLI mode. To see available options, run:

```bash
vb-tui-install --help
```

Vibranium includes several TUI applications out of the box, such as [btop](https://github.com/aristocratos/btop), [ncdu](https://dev.yorhel.nl/ncdu), [impala](https://github.com/pythops/impala), [bluetui](https://github.com/pythops/bluetui), and [wiremix](https://github.com/tsowell/wiremix). These are common utilities you’ll likely use. If you don’t need them, or only want a subset, you can easily remove them via *Vibranium Menu* -> *Remove* -> *TUI*.