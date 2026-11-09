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

## Tips

When something is playing, the "**Copy Current Track**" entry in the Utilities menu will appear.
When selected, the URI, URL, or FILE of the currently playing track will be copied to clipboard,
making it easy to share your music with friends.
