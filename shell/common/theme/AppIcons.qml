pragma Singleton

// qmllint disable signal-handler-parameters
import Quickshell
import qs.common
import "../collections/BoundedCache.js" as BoundedCache

// App and window identity -> a loadable icon URL. This is the one place the
// two-step lookup lives: the shell's own themed asset set first
// (Icons.url, so a shipped glyph recolors with the palette), then the
// platform icon theme (Quickshell.iconPath, for every app the shell does
// not ship an icon for).
//
// Icons.url alone cannot serve this. It resolves only the SVGs its boot scan
// read from assets/icons and returns "" for anything else, and an arbitrary
// application is not a member of that set. Quickshell.iconPath alone would
// miss every glyph the shell does ship, because the shipped set is not
// installed into the user's icon theme. A caller needs both, in that order.
//
// Why the memo: the inputs are few and the callers are many. Every bar
// instance renders every workspace on every output, so the same dozen
// appIds are asked for once per output per repaint, and the platform lookup
// walks the icon theme on each miss. Keyed on the resolved inputs, so a
// caller that passes no fallback and one that passes an explicit generic
// cannot read each other's answer.
//
// Keyed on the raw name, the fallback and the tone, NOT on the resolved URL,
// and deliberately not on any theme state: every lookup is a function of
// those three inputs, so a theme change does not invalidate an entry (the tone
// is a palette KEY, and Icons.url re-resolves it against the live palette), and
// an install that adds an icon mid-session is picked up when the entry is
// evicted rather than by watching the icon theme (which would cost a watcher
// per distinct app for a lookup that is correct the overwhelming majority of
// times).
Singleton {
  id: root

  readonly property string tag: "appIcons"

  // name + fallback + tone -> resolved URL. Mutated in place for the reason
  // BoundedCache documents: a caller binding calls url() while it
  // evaluates, so replacing this map would notify the very bindings that
  // are mid-evaluation and loop. Size and diagnostics are functions for
  // that same reason, not properties.
  //
  // Bounded at 128: a session's distinct window identities are counted in
  // tens (every app the user has open, plus the few that share a name with
  // a non-window surface). The bound covers every app that is open at once
  // with room to spare, so the steady state is all hits, and a bound is
  // what keeps a long-lived shell from accumulating an entry per app ever
  // seen.
  readonly property int urlCacheCap: 128
  property var _cache: BoundedCache.create(root.urlCacheCap)

  // Resolved URL for one app or window identity, or "" when nothing
  // resolves. `fallback` is an optional icon name returned instead of ""
  // on a miss; without it a miss is "" so a caller can show a letter tile
  // or nothing rather than a broken texture. `colorKey` is an optional
  // palette key the shipped glyph is painted in, and "" and undefined are
  // the same leg of it: Icons.url paints foreground_0 by default but reads
  // "" as a real key and resolves Theme.color("") to #000000, so an absent
  // tone must reach it as undefined.
  function url(name, fallback, colorKey): string {
    const n = String(name ?? "").trim()
    if (n === "") return ""
    const fb = String(fallback ?? "")
    const tone = String(colorKey ?? "").trim()
    // NUL-separated, and NUL is the one character neither an app name, a theme
    // icon name nor a palette key can contain, so two inputs that differ in any
    // field always produce different keys. A plain separator would let
    // ("a-b", "") and ("a", "b") collide on one entry. The tone is a field of
    // its own because the resolved value depends on it: ("app", "", "red") must
    // not be served the entry cached for ("app", ""). Normalized to "" here so
    // "red" and " red " are one entry rather than two, and so the "" and
    // undefined spellings of "no tone" share the entry they both resolve to.
    const ck = n + "\u0000" + fb + "\u0000" + tone
    const hit = BoundedCache.get(root._cache, ck)
    if (hit !== undefined) return hit
    const resolved = root._resolve(n, fb, tone)
    BoundedCache.put(root._cache, ck, resolved)
    return resolved
  }

  function _resolve(name, fallback, colorKey) {
    // A desktop entry may carry an absolute path or a file: URL as its
    // Icon= value rather than a theme name. Neither leg below can serve
    // one - Icons.url looks in the shipped set and iconPath looks in the
    // theme - so the path is its own answer. Both legs ignore `colorKey`: the
    // file is drawn exactly as it shipped, because a sender's own artwork is
    // not a glyph this shell recolors.
    if (name.startsWith("file:")) return name
    if (name.startsWith("/")) return "file://" + name
    // Icon themes and the shipped asset set both key on lower-case names,
    // but a window class is whatever the app's binary called itself
    // ("Firefox", "Code"), so each lookup is tried in lower case first and
    // in the original spelling second. The retry only ever adds a hit.
    const lower = name.toLowerCase()
    // Theme files are frequently mixed-case where senders are not:
    // "org.nicotine_plus.nicotine" arrives lower-case while the theme
    // ships "org.nicotine_plus.Nicotine", and neither spelling above can
    // see the other (theme lookup is case-sensitive). Each dot-separated
    // segment with an upper-cased first letter is therefore tried too -
    // the reverse-DNS TailCase convention - which turns that whole class
    // of miss into a hit instead of a provider warning per requesting
    // slot. Bounded by the segment count (names are short), memoized with
    // the entry, and the extra probes only ever add a hit.
    const cands = [lower]
    if (name !== lower) cands.push(name)
    const segs = name.split(".")
    for (let i = 0; i < segs.length; i++) {
      // Upper-case the first letter and any letter following a separator,
      // preserving each separator in place ("nicotine" -> "Nicotine",
      // "a-b_c" -> "A-B_C").
      const titled = segs[i].replace(/(^|[-_:+])([a-zA-Z])/g,
        (m, sep, ch) => sep + ch.toUpperCase())
      if (titled === segs[i]) continue
      const cand = segs.slice(0, i).join(".") + (i > 0 ? "." : "")
        + titled + (i + 1 < segs.length ? "." + segs.slice(i + 1).join(".") : "")
      if (cands.indexOf(cand) < 0) cands.push(cand)
    }
    // Icons.url resolves a palette key against the live palette, so a caller
    // passing a KEY stays correctly toned across a theme switch. undefined
    // rather than "" for the no-tone case: Icons.url reads "" as a key and
    // Theme.color("") is #000000, so an empty tone would paint the glyph
    // black instead of leaving it on the default foreground_0.
    const key = colorKey === "" ? undefined : colorKey
    for (const candidate of cands) {
      const themed = Icons.url(candidate, key)
      if (themed !== "") return themed
    }
    // The checked overload is the one that returns "" on a miss instead of
    // a missing-texture URL, so a caller can tell "no icon" from "icon".
    // Probed per candidate for the same case reason as above: a hit here
    // returns the plain URL, so a mixed-case theme file resolves without
    // ever reaching the fallback leg (and its load-time warning).
    for (const candidate of cands) {
      const hit = String(Quickshell.iconPath(candidate, true))
      if (hit !== "") return hit
    }
    if (fallback !== "") return String(Quickshell.iconPath(lower, fallback))
    return ""
  }

  // Live entry count of the URL cache. A function and not a property: the
  // map is mutated in place, so a binding over the count would evaluate
  // once against an empty cache and then report that number forever.
  function cacheSize() {
    return BoundedCache.size(root._cache)
  }

  // The bound as a fact rather than a claim. A count above zero is this
  // cache paying for its own ceiling, not an error.
  function diagnostics() {
    const cache = BoundedCache.diagnostics(root._cache)
    return {
      tag: root.tag,
      urlCacheSize: cache.size,
      urlCacheCap: cache.capacity,
      urlCacheHits: cache.hits,
      urlCacheMisses: cache.misses,
      urlCacheStores: cache.stores,
      urlCacheEvictions: cache.evictions
    }
  }
}
