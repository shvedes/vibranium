.pragma library

// The five mixer tabs, in the order the user arrives with them. One file so
// the window that draws the chips, the facade that holds a pending tab and the
// `app call audioMixer ...` help all agree about what a tab ID is.
var tabs = [
  { key: "apps", label: "Apps", icon: "music" },
  { key: "devices", label: "Devices", icon: "speaker" },
  { key: "recording", label: "Recording", icon: "mic-on" },
  { key: "configuration", label: "Configuration", icon: "settings-general" },
  { key: "graph", label: "Graph", icon: "link" }
]

function keys() {
  const out = []
  for (let i = 0; i < tabs.length; i++) out.push(tabs[i].key)
  return out
}

function isValid(key) {
  if (typeof key !== "string") return false
  for (let i = 0; i < tabs.length; i++) if (tabs[i].key === key) return true
  return false
}
