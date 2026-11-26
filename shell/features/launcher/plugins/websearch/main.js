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

  // One URL builder for the UI activation and the public `plugin command
  // websearch url` command. The command returns the string; opening a browser stays in
  // the activation path.
  function searchUrl(query) {
    return engine().url + encodeURIComponent(query)
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
      const url = searchUrl(query)
      api.execDetached("app2unit -S both -s app-graphical.slice -- xdg-open "
        + shellQuote(url) + "\n")
    },
    ipc: {
      url: function (query) {
        const s = String(query ?? "")
        if (s.trim() === "") return null
        return searchUrl(s)
      }
    }
  }
})()
