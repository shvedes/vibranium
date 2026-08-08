# Screen recording

Vibranium uses [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) (GSR) for recording, wrapped in `vb-core-recording` — the script that translates your settings into GSR flags.
Everything should work out of the box.

!!! warning "Not in VMs"
    Screen recording is unavailable when Vibranium runs inside a VM due to potential complications with support implementation.

## Starting a recording

Press ++ctrl+alt+r++ to open the recording menu, pick **Screen** or **Region**, and recording starts with a brief screen flash.
A **recording indicator** appears in the bar, showing that a recording is in progress.

When Hyprland animations enabled, a brief screen flash will appear on start/stop actions.  
This effect is **not visible** in the recordings themselfs.
If you don't like this effect, disable it in the settings.

To stop the active recording, call the recording menu again, or click on the bar indicator.  
The flash confirms the stop, and the finished file saved in `~/Videos/Screencasts/`.

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
