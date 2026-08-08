# Video downloader

Vibranium ships a small CLI wrapper around `yt-dlp` (`vb-util-yt-dlp`) that makes downloading a video much simpler.
It's designed to be plain and simple, so it has no settings nor options to configure it; URL in -> `.mp4` out.

## Using it

**From the app launcher** (++super+a++): seach for "Video Downloader".

**As a one-shot command**:

```bash
vb-util-yt-dlp https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

## What it does automatically

- **Picks the best quality**: downloads the best available video and audio streams, then remuxes them into an `.mp4` in your default downloads directory.
- **Handles cookies for you**: many sites require login cookies to access the highest quality. The wrapper automatically tries your browsers in order (there are eight in the fallback chain) and caches the first one that works.
- **Knows when you're not looking**[^1]: if the terminal window is on a non-active workspace when the download finishes, it closes automatically and sends a **notification** instead. If the window is on your active workspace, it simply stays open—you were already watching it.

[^1]: This is a fairly opinionated behavior and may be removed in a future release.
