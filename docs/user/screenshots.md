# Screenshots

Screenshots are basic by default, but somewhat powerful when needed. Don't sue me, KDE.

| Shortcut | Scope |
|---|---|
| ++super+shift+z++ | Entire screen |
| ++super+shift+a++ | Active window |
| ++super+shift+s++ | Region (drag to select) |
| ++print-screen++ | Entire screen |

When triggered, a taken screenshot is being saved to your default screenshots folder and copied to clipboard.
When Hyprland animations are enabled, your screen will flash briefly.
This effect is **not visible** on screenshots themselfs.
If you don't like it, you can disable it in:

## Settings

*Vibranium Menu -> Settings -> Screenshots:*

| Setting | Options / notes |
|---|---|
| File type | `png`, `jpeg` (default), `ppm` |
| JPEG quality | 0–100, default 80 |
| Save to disk | On by default. Off = clipboard-only |
| Flash screen / Flash border | Screen flash needs Hyprland animations enabled |
| Show notification | Show notification after capture |
| Annotate automatically | Open the annotator after every capture (see below). |
| Capture cursor | Include the cursor in the image |

## Annotation

Toggle **Annotate automatically** in the settings, and after every capture the annotator — [satty](https://github.com/Satty-org/Satty) — pops up with the screenshot loaded.
Satty is one of the best-looking and most capable image annotators on Linux: arrows, rectangles, text, blur, highlight, etc.

You can also open the annotator on demand for any image via `vb-util-image-annotator` or the "Image Annotator" app in App Launcher.
