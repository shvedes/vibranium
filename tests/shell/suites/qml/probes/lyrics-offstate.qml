// Probe: the Utilities lyrics target is resident and needs no bar runtime.
import QtQuick
import Quickshell
import qs.common
import qs.features.bar.control
import qs.features.lyrics

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n")) }

  Component.onCompleted: {
    try {
      kv("lyrics.exists", typeof Lyrics)
      kv("control.hasShowLyrics", typeof BarControl.showLyrics)
      kv("lyrics.noOverlay", Lyrics.overlay === null)
      kv("lyrics.closeIdempotent", Lyrics.close() === true && Lyrics.overlay === null)
      kv("control.noRuntime", BarControl.runtime === null)
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}
