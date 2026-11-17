# Downloader

Vibranium ships a small downloader for media and direct files. Media goes through `yt-dlp` (`vb-util-yt-dlp`); a direct link is fetched with `wget`, or `aria2c` for `ftps`/`sftp` links. The island picks the engine from the link, and you can override it with the Auto, Video and File chips.

## Using it

**From the app launcher** (++super+a++): search for "Downloader".

**As a one-shot command**:

```bash
vb-util-download https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

## Direct files

`vb-util-download URL` is the general entry point. With no options it classifies the link: a known media host or an HLS/DASH manifest goes to `vb-util-yt-dlp`; a path naming a file goes to `aria2c` when it is installed (`wget` otherwise); `ftps` and `sftp` links always go to `aria2c`; and an ambiguous link stops with the reason instead of guessing. aria2c splits HTTP, FTP and FTPS transfers across several connections; SFTP stays single-stream. `--tool auto|yt-dlp|wget|aria2c` overrides the choice, `--classify URL` prints the verdict, and `--probe` answers whether any engine is installed. `--subdir NAME` works for every engine; `--format`, `--subdir-tag` and `--embed-thumbnail` are yt-dlp-only. The history is shared with the media downloader. Recent is one list for every engine, media and direct files alike; when it is empty, the table stays in place with a dimmed placeholder and a short idle note.

In the island the Auto chip shows the verdict it reached, and the Video and File chips pin the engine. A file has no format table: the preview names the file, Download fetches it, and the history row reopens in file mode with the engine that wrote it. When the file lands, the island keeps a green **Downloaded <name>** box in place of the transient progress line, so a download short enough to miss the line still leaves evidence. The box clears on the next action. While a job runs, the card shows an indeterminate barber pole, and a batch also shows its position; there is no byte percentage yet. The bar icon's little sweep runs even when global animations are disabled, because it is the only busy indicator left on the bar.

Middle-click the bar icon to download the link in the PRIMARY selection without opening the island. The whole selection must be one link: a sentence that merely contains one is prose, and is refused. If auto-detection cannot identify the type, it assumes a direct file and starts wget instead of stopping. Middle-click is the all-default automatic path: no format, subdirectory, or thumbnail override. Any playlist link, whether a `/playlist` page or a watch link carrying `list=`, queues every listed video at Best in the background. Each queued video uses the wrapper's default single-video selection (`--no-playlist --playlist-end 1`). The batch is one Recent row for its folder, with SIZE showing the folder's total. The downloader sends notifications for the start, an invalid or non-link selection, and the finished file. The bar module starts disabled; enable it from the bar settings, where it sits immediately before Power profiles. A fetched file shows the file glyph, while an empty field keeps the paste prompt. Preview thumbnails are held in the shell's runtime image cache while the card is open, so reopening the same video or playlist uses the already-decoded image instead of downloading it again. Inactive format rows, quality chips and already-held playlist entries show the same blocked cursor as a disabled button; selectable format rows keep the pointing hand. Clicking that pane pastes any link, including a direct file, not only the mainstream video hosts that auto-fill on open. Long titles and long URLs begin scrolling as soon as the pointer is over them, even when animations are disabled: reading the full text is not decoration, but nothing moves under a pointer that is elsewhere. The Recent table is a fixed seven-row window; older entries are silently out of reach. If Auto cannot identify a link, the card says so without the classifier's internal reason, and choosing **Video** or **File** clears that warning. If you pin **Video** on a link yt-dlp rejects as unsupported, the island says the link is not a video and points you back to **Auto** or **File**, instead of leaving an empty format table. Magnet links are refused until torrent metadata naming is wired; download the `.torrent` and pass that file to `aria2c`.

## Playlists

Paste a playlist link (a `/playlist` URL, or a watch link that carries `list=`) and the island lists its videos instead of downloading one. Every entry starts ticked and the tick above the list flips them all; a row of quality chips picks the capture for the whole batch (Best, 4K, 2K, 1080p, 720p, Audio — nothing is silently assumed; every tier but Best is a cap of "best at or below", so a video that lacks the chosen height still downloads its best one), and **Download N** fetches the ticked videos in that quality, in order, each into its own file. The batch is one Recent row named after the playlist, with SIZE showing the folder's total size; the individual files are not separate history rows. When **Audio** is selected, a checkbox under the chips (on by default) embeds the thumbnail as cover art; metadata is always embedded.

An entry whose video is already in the recent list is drawn ticked, greyed out and named in the accent colour: you already have that one, so it cannot be unticked and is never fetched again. A copy that was deleted or moved is not held, so that entry stays selectable for a fresh download. **Clear** drops the loaded playlist and returns the card to Recent. Long entry titles scroll while the pointer is over the row.

The batch lands in a folder named after the playlist itself — never after its first video. Once that folder exists, the next batch of the same playlist goes into a suffixed copy named after its quality, so the same playlist at another preset (`Best`, `1080p`, `Audio`…) never mixes into the first copy; a rerun of that same preset reuses its folder. The folder holds only the downloaded media; the preset bookkeeping lives outside it.

Closing the island does not stop the queue — the bar keeps going, and the completion card states how many videos landed and offers an **Open** action for the batch folder. The island's spinner and barber pole also keep moving when global animations are disabled.

## What it does automatically

- **Picks the best quality**: downloads the best available video and audio streams, then remuxes them into an `.mp4` in your default downloads directory.
- **Handles cookies for you**: many sites require login cookies to access the highest quality. The wrapper automatically tries your browsers in order (there are eight in the fallback chain) and caches the first one that works.
- **Knows when you're not looking**[^1]: if the terminal window is on a non-active workspace when the download finishes, it closes automatically and sends a **notification** instead. If the window is on your active workspace, it simply stays open—you were already watching it.

[^1]: This is a fairly opinionated behavior and may be removed in a future release.
