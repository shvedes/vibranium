Vibranium includes a handy CLI game wrapper that launches games inside the `gamescope` micro-compositor when `gamescope` is available on the system. Gamescope can potentially eliminate various Wine and XWayland-related issues, while also improving performance in some cases.

First, make sure you have `gamescope` and optionally `mangohud` installed (*Vibranium Menu* (`CTRL ALT V`) > *Install* > *Package*), then launch your game with:

```bash
vb-core-gamemode -- my-cool-game
````

If `gamescope` is not available, the wrapper will try to use `mangohud` instead. If neither is installed, it will simply execute the game normally with *performance* power profile enabled.

To use it with Steam, use the following syntax:

```bash
vb-core-gamemode [OPTIONS] -- %command%
```

Use the `--help` flag to see all available options.