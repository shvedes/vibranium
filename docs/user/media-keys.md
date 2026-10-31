# Media control

If you have hardware media keys (next/prev track, play/pause, etc) - they'll just work as intended.  
Vibranium just adds a simple layer on top of it with some basic features.

Configure in **Vibranium Menu** -> **Settings** -> **Media Control**.

## Fade

Disabled by default. When you pause, the audio doesn't stop abruptly — it **fades out smoothly** to silence.  
Resume, and it **fades back in**. The same applies when switching tracks.

The fade curve is quadratic — it starts fast and slows down near the end. The duration is configurable:

**Vibranium Menu** -> **Settings** -> **Media Control** -> **Fade duration**:

  - `very_slow`
  - `slow`
  - `normal`
  - `fast`
  - `very_fast`
  - `off`

This works with both regular players (via playerctl) and **MPD** (via mpc, if installed).

## Now playing

Enable **Track change OSD** in the media control settings to briefly show the current track when you skip tracks or change playback state. This works independently of the bar's **Now Playing** module. The progress display follows the active MPRIS player, including seeks and rewinds while the card is visible.

Optionally enable **Show cover art**. For web-based players the art is fetched asynchronously; the card keeps a music fallback until the image is ready.


## Tips

When something is playing, the "**Copy Current Track**" entry in the Utilities menu will appear.
When selected, the URI, URL, or FILE of the currently playing track will be copied to clipboard,
making it easy to share your music with friends.
