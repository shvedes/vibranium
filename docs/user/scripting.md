# Scripting

Most of Vibranium is implemented as shell scripts and small command-line utilities.

Many internal components expose a CLI interface that can be used independently of the desktop environment. To discover available commands and options, run any `vb-*` utility with the `--help` flag.

For example:

```bash
vb-core-... --help
vb-cmd-... --help
vb-util-... --help
```

These commands are intended to be reusable. They can be called from your own scripts, keybindings, launcher entries, hooks, systemd units, or any other automation.

One example is `vb-cmd-play-mpd`, which performs MPD library searches.  
Vibranium itself never calls this command directly, but it is used by the default launcher keyword configuration.

If your MPD library is indexed, opening the launcher and typing:

```text
play <query>
```

searches your music library, queues the best matching result, and immediately starts playback. No dedicated application needs to be opened—the launcher simply invokes a background command.

Many other utilities follow the same design.  
Explore the available commands by prefix (`vb-core-*`, `vb-cmd-*`, `vb-util-*`, etc.) and inspect their help pages.

The scripting interface continues to expand as new components are added.
