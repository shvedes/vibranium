Vibranium includes a simple CLI wrapper for `yt-dlp`, designed to provide a fast and straightforward video downloading experience.

To launch it, open the App Menu (`SUPER A`) and type `video`.

The tool requires `yt-dlp` to be installed. If it is not available on your system, the wrapper will notify you and offer to install it automatically.

The only thing you need to provide is the video URL. Everything else is handled automatically. The tool will attempt to fetch the best available video and audio quality and save the result as an `.mp4` file in your default downloads directory.

You can also use it as a one-shot command:

```bash
vb-util-yt-dlp https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

If, at the moment of saving, the utility window is not on the current workspace, it will automatically close itself and send a notification indicating that the download has completed.

If the window is on the active workspace, it will remain open and no notification will be sent, since the user is already in control of the process.