# Screenshots

Screenshots are basic by default, but somewhat powerful when needed. Don't sue me, KDE.

| Shortcut | Scope |
|---|---|
| ++super+shift+s++ | Screenshot: pick region or screen |
| ++super+ctrl+s++ | Screenshot: the screen exactly as it stands |

Pressing the shortcut opens a dimmed overlay with two icon-only buttons: region and entire screen. Buttons are clickable, or Tab / arrows + Enter. Region selection also supports a keyboard cursor with Space, arrows, Shift+arrows, and Enter.

++super+ctrl+s++ skips that overlay and takes the frame immediately, with whatever is on screen left standing. The normal screenshot is an exclusive surface: it dismisses the open menu, launcher, power menu, pass panel, and clipboard panel first, so the shot is the desktop alone. This one takes no such claim, so an open menu is in the picture - which is the point when you are documenting a menu or an error. It captures the whole screen only; there is no region variant, because the region selector needs exclusive keyboard focus and would take it from the very menu you are photographing.

Because nothing is dismissed, anything open is recorded. Leave the pass and clipboard panels closed when you use it.

Capture uses Quickshell screencopy for the frozen frame and Qt for PNG/JPEG encoding. ImageMagick performs the exact physical-pixel crop for selected regions, and `wl-copy` offers the finished image as a `text/uri-list` file URI. Region selection crops the same pre-overlay frame the user selected, including at fractional display scales.

With **Save to disk** on, a screenshot without auto-annotate is saved to `~/Pictures/Screenshots` (respects `XDG_PICTURES_DIR`) and copied to the clipboard. With **Save to disk** off, it is kept only for the clipboard offer. With auto-annotate, no final file is created up front: Save writes to the screenshots folder only when disk saving is on. Cancelling drops it silently. **Save to disk** is listed under **Auto-annotate** in the settings, so it is only reachable there while auto-annotate is off; the value you set persists and keeps deciding the annotator's Save behavior when it is on.

## Settings

*Vibranium Menu -> Settings -> Screenshots:*

| Setting | Options / notes |
|---|---|
| File type | `jpeg` (default), `png` |
| Notification | Notify when taking screenshots |
| Auto-annotate | Open the annotation overlay after every capture (see below) |
| Save to disk | On by default. Off = clipboard only. Listed under Auto-annotate, so it appears only while that is off |
| Capture cursor | Include the cursor in the image |
| Annotator UI size | Toolbar scale: small, medium, large |

JPEG quality and PPM are retired: the native encoder writes JPEG at its default quality, and no QML encoder writes PPM.

Clipboard images are normal Vibranium clipboard-history entries. They can be previewed, copied again, and pinned. If `wl-copy` cannot offer the URI-list, Vibranium places the same persistent local `file://` URI on the clipboard instead of deleting its target.

Screenshots and annotation are unavailable while the session is locked. Locking the session also closes any active picker, selector, capture, or annotator.

## Annotation

Toggle **Auto-annotate** in the settings, and after every capture the native annotation overlay opens with the screenshot loaded: a dimmed fullscreen overlay with the shot centered and a floating tool panel at the bottom.

Tools: brush, line, eraser, arrow, elbow arrow, rectangle, ellipse, text, pixelate, crop, select, undo, and redo.

| Key | Tool |
|---|---|
| ++b++ | Brush |
| ++e++ | Eraser |
| ++l++ | Line |
| ++a++ | Arrow |
| ++n++ | Elbow arrow |
| ++g++ | Rectangle |
| ++o++ | Ellipse |
| ++t++ | Text |
| ++d++ | Pixelate |
| ++c++ | Crop |
| ++v++ | Select (move placed strokes, ++del++ removes) |
| ++u++ / ++r++ | Undo / redo |

`Ctrl+Z` / `Ctrl+Shift+Z` (or `Ctrl+Y`) undo/redo. `Ctrl+S` saves, and `Ctrl+C` copies the current image as a persistent `text/uri-list` file URI. Enter applies the staged crop as a resizable frame. Escape walks back through text, crop, selection, the discard guard, and finally close.

Text can be placed with a click or an aspect-locked drag box; the box height sets the text size. The toolbar provides colors, pen width, tools, Clear all, Copy, Save, rotation, and Cancel. Tool buttons and color swatches support Return or Space; the pen-width slider uses arrow keys and Page Up/Down. Wheel zooms, middle-drag pans, and `0` restores the opening view. The annotator opens one wheel step zoomed out.

Edited output is exported at source-document resolution. Monitor scale, preview zoom, and window placement do not reduce the saved image. Crop and 90-degree rotation are applied during export.

`vb-shell screenshots annotate <absolute-path>` opens an existing image without changing it. Save opens Save As, while Copy offers the current image. A directly opened source is never overwritten in place.

Notifications come from the shell's own notification daemon, so the toast follows DND and fullscreen-hold rules like any other card.
