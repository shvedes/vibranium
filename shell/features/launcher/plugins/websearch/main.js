// Web-search plugin: falls back to a web query when no local application
// matches.
//
// The engine follows the GLOBAL_SEARCH_ENGINE setting (same enum as the
// settings catalog: google, duckduckgo, bing, brave). Launch parity with
// the wrapper: xdg-open inside app2unit's transient systemd
// scope so browser processes stay tracked by the session. Detachment is
// guaranteed by the service's execDetached().
(function() {
  let api = null

  const ENGINES = {
    google: {
      label: "Google",
      url: "https://www.google.com/search?q="
    },
    duckduckgo: {
      label: "DuckDuckGo",
      url: "https://duckduckgo.com/?q="
    },
    bing: {
      label: "Bing",
      url: "https://bing.com/search?q="
    },
    brave: {
      label: "Brave",
      url: "https://search.brave.com/search?q="
    }
  }

  // Adopt-lib: delegates to api.shellQuote (StringUtils.shellQuote
  // semantics). The operation is a default grant on every policy, so the
  // api is always present; there is no fallback copy to drift.
  function shellQuote(s) {
    return api.shellQuote(s)
  }

  function engine() {
    const key = String(api.setting("shell.launcher.searchEngine") ?? "google")
    return ENGINES[key] || ENGINES.google
  }

  VibraniumPlugin = {
    init: function(context) {
      api = context
    },

    // Web-search mode shows exactly one action for the typed query. An
    // empty query answers with a hint row instead (the service tags it
    // non-activatable), mirroring the time plugin hint.
    items: function(query) {
      const e = engine()
      if (String(query ?? "").trim() === "") {
        return [{
          label: "Search in " + e.label,
          sub: "Type to search",
          desc: "",
          icon: "internet-web-browser",
          data: {}
        }]
      }
      return [{
        label: "Search in " + e.label,
        sub: String(query ?? ""),
        desc: "",
        icon: "internet-web-browser",
        data: {}
      }]
    },

    activate: function(item, query) {
      const e = engine()
      const url = e.url + encodeURIComponent(query)
      api.execDetached("app2unit -S both -s app-graphical.slice -- xdg-open "
        + shellQuote(url) + "\n")
    }
  }
})()
