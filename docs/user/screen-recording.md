# Screen recording

Vibranium uses [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) (GSR) for recording, wrapped in `vb-core-recording` — the script that translates your settings into GSR flags.
Everything should work out of the box.

!!! warning "Not in VMs"
    Screen recording is unavailable when Vibranium runs inside a VM due to potential complications with support implementation.

## Starting a recording

Press ++ctrl+alt+r++ to toggle screen recording, and recording starts with a brief screen flash.
A **recording indicator** appears in the bar, showing that a recording is in progress.

When Hyprland animations enabled, a brief screen flash will appear on start/stop actions.  
This effect is **not visible** in the recordings themselfs.
If you don't like this effect, disable it in the settings.

To stop the active recording, press ++ctrl+alt+r++ again, or click on the bar indicator.  
The flash confirms the stop, and the finished file saved in `~/Videos/Screencasts/`.

Once the encoder has flushed and exited, the finished file is placed on the clipboard as a `file://` URI-list, the same way a screenshot is.
That entry is a normal Vibranium clipboard-history entry: it can be previewed, copied again, and pinned.
The clipboard keeps serving the URI after the recording stops, so you can paste the path straight into a file manager, an editor, or a chat window.

## Settings

**Vibranium Menu** -> **Settings** -> **Recording**:

| Setting | What it means |
|---|---|
| FPS | FPS to record with |
| Quality | `medium`, `high`, `very_high`, `ultra`. |
| Container | `mp4`, `mkv`, `webm`. |
| Video codec | `auto`, `h264`, `hevc`, `av1`, `vp8`, `vp9`, plus HDR and 10-bit variants |
| Framerate mode | `cfr` or `vfr` |
| Capture source | Capture microphone |
| Capture sink | Capture system audio |
| Flash screen | Explained above |

!!! warning
    Make sure your hardware supports selected codec. Otherwise, the recording may fail.

!!! note
    Your recording FPS is limited by the highest refresh rate of your **active** monitor.
    Currently this is a limitation that needs to be fixed.
    ---
    `webm` forces the `vp8` codec in GSR. If you want webm, make sure your GPU supports the vp8 codec; otherwise pick a different container.
