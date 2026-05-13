By default, Vibranium comes with [GSR](https://git.dec05eba.com/gpu-screen-recorder/about/) and the [`vb-core-recording`](https://github.com/shvedes/vibranium/blob/master/bin/vb-core-recording) script that handles all available options: codecs, quality, etc. Everything should work out of the box. Screen recording is not available when Vibranium is running inside of a VM.

You can start screen recording by pressing: `CTRL + ALT + R`.

The recording method is robust: when first try failed - the script will try to re-exec the recording with fallback options, specifically with the CPU encoder instead of the GPU one. This might happen when your GPU drivers not installed properly (this shouldn't happen during Vibranium installation) or when in Vibranium settings you selected a codec that your GPU doesn't support on hardware level. The philosophy behind this is that if the user's intention was to record something - it **must** be recorded, troubleshooting later. When recording in fallback mode stops, Vibranium will notify the user that GPU-accelerated recording failed and will pinpoint to potential causes. 

If though, recording failed in both, GPU **and** CPU encoders, then something is really wrong there. Again, Vibranium will tell you about it and also will suggest to open the latest GSR log (by clicking on the notification) in order to help with troubleshoot.

In general, builtin screen recording solution is simple, yet powerful and robust. You can adjust your recording preferences by going to *Vibranium Menu* -> *Settings* -> *Recording*.

There you can set your *recording FPS*\*, *container type* (such as `mp4` or `mkv`), *video quality*, *volume sources* and even low-level details like *recording format* (like CFR / VFR).

> [!NOTE]
> Your recording FPS is limited by the highest available refresh rate
> of your active monitor.