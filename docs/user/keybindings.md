# Keyboard shortcuts

Vibranium is designed around keyboard navigation.  
The default layout follows a simple principle: **keys are chosen to be memorable**.  
Most shortcuts use the first letter of the action they perform whenever practical.  
For example, **T** for Theme, **W** for Wallpaper, and **U** for Utilities.

## Layout philosophy

![Keyboard layout diagram](../assets/images/layout.png)

The shortcut layout is organized into two primary groups.

- **Blue** — ++super++ (primary modifier)
- **Green** — additional keys used together with ++super++
- **Orange** — ++ctrl++ ++alt++ (Vibranium-specific actions)

The keyboard is also divided into two logical halves:

![Keyboard layout diagram 2](../assets/images/split_layout.png)

The left hand primarily holds the modifiers while the right hand performs the action key.  
Most shortcuts can therefore be executed with minimal hand movement.

## Primary shortcuts (`SUPER`)

These shortcuts cover everyday desktop usage.

| Shortcut | Action |
|----------|--------|
| ++super+q++ | Close active window |
| ++super+shift+q++ | Force close active window |
| ++super+f++ | Toggle fullscreen |
| ++super+shift+f++ | Toggle floating |
| ++super+a++ | Application launcher |
| ++super+e++ | File manager |
| ++super+v++ | Clipboard history |
| ++super+shift+v++ | Clear clipboard |
| ++super+shift+s++ | Screenshot: region |
| ++super+shift+a++ | Screenshot: active window |
| ++super+shift+z++ | Screenshot: entire screen |
| ++print++ | Annotated screenshot |
| ++super+m++ | Toggle microphone mute |
| ++super+b++ | Cycle power profiles |
| ++super+period++ | Emoji picker |
| ++super+return++ | Terminal |
| ++super+shift+return++ | Floating terminal |
| ++super+escape++ | System monitor (`btop`) |
| ++ctrl+shift+escape++ | System monitor (`btop`) |
| ++super+grave++ | GPU monitor (`nvtop`) |
| `XF86Calculator` | Calculator |
| ++super+g++ | Toggle window group |
| ++super+ctrl+g++ | Lock or unlock window group |
| ++super+r++ | Resize mode |
| ++super+1++ … ++super+0++ | Switch workspace |
| ++super+shift+1++ … ++super+shift+0++ | Move window to workspace |
| ++super+tab++ | Cycle workspaces |
| ++super+alt+left++ / ++super+alt+right++ | Previous/next workspace |

Window movement uses the **IJKL** cluster:

- ++super+j++ / ++super+l++ / ++super+i++ / ++super+k++ — change focus
- ++super+shift+j++ / ++super+shift+l++ / ++super+shift+i++ / ++super+shift+k++ — move the active window

Arrow keys are available as an alternative.

## Vibranium shortcuts (`CTRL` + `ALT`)

These shortcuts open menus and Vibranium-specific functionality.

| Shortcut | Action |
|----------|--------|
| ++ctrl+alt+v++ | Vibranium menu |
| ++ctrl+alt+u++ | Utilities menu |
| ++ctrl+alt+t++ | Theme picker |
| ++ctrl+alt+w++ | Next wallpaper |
| ++ctrl+alt+c++ | Color picker |
| ++ctrl+alt+r++ | Recording menu |
| ++ctrl+alt+p++ | Password manager |
| ++ctrl+alt+l++ | Lock session |
| ++ctrl+alt+delete++ | Power menu |
| ++ctrl+alt+f++ | Freeze or unfreeze a process |
| ++super+alt+escape++ | Alternate power menu |

## Hardware keys

Standard multimedia keys (`XF86*`) behave as expected.  
Media playback, volume, brightness, and similar controls work through the dedicated hardware keys provided by the keyboard.  
Some media keys continue to function while the session is locked.

## Mouse bindings

Floating windows behave as in most desktop environments.

- Drag with the left mouse button to move a floating window.
- Drag with the right mouse button to resize a floating window.

In addition, ++super++ + mouse wheel adjusts the playback volume of the focused application.

!!! note

    Some applications do not persist per-application volume levels between launches. In those cases, volume must be adjusted again after restarting the application.

## Window groups

Window groups allow multiple windows to occupy the same position and be cycled without changing workspace.

The most important shortcuts are:

- ++super+g++ — create or toggle a group
- ++alt+j++ / ++alt+l++ — switch between grouped windows
- ++alt+1++ … ++alt+0++ — jump directly to a grouped window
- ++super+ctrl+g++ — lock or unlock the group

See [Window groups](window-groups.md) for complete documentation.

## Listing all shortcuts

The complete list of active shortcuts can be viewed in two ways.

From the menu: **Vibranium Menu -> Help -> Keybindings**, or from a terminal:

```bash
vb-cmd-keybindings --list
```

Both methods display the currently active configuration, including user-defined shortcuts.

## Customizing shortcuts

Default bindings are defined by Vibranium and can be overridden without modifying the installation.

See [Customizing keybindings](../understanding/customize-keybindings.md) for details.
