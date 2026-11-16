.pragma library

// LAYER-SHELL SURFACE SPECIFICATION
// =================================
//
// Normative. This table is the contract for every layer surface the shell maps.
// A window's namespace MUST name a row here, and nothing else in the tree may
// declare a layer, an exclusion mode, a mask policy or an order. When this file
// and a declaration disagree, the declaration is wrong and the suites say so.
//
// ## Conformance
//
// 1. A namespace MUST be `vibranium:<lowercase-hyphen>` and MUST appear in
//    exactly one row. A row is a surface CLASS, not a window: every window that
//    keeps the same contract shares the name, and the row lists those windows
//    as `clients`.
// 2. A row MUST carry exactly the fields of `FIELDS`, in that order, each value
//    inside its domain in `DOMAINS`. An unknown field is a conformance failure,
//    not an extension point.
// 3. A client MUST map exactly one class. A view that names two rows is an
//    ambiguity: `validate` reports it, and the class it meant is unknowable.
// 4. A class whose `order` is not 0 MUST declare `rule: true`. An order no
//    Hyprland rule carries is an intent the compositor never hears.
// 5. `focus` states the strongest keyboard mode a class may reach, not a mode
//    it holds while closed. A view that may reach `exclusive` MUST gate the
//    grab on its own open state.
// 6. An edit to this table reaches three files: the declaring view, the rule in
//    `default/hypr/window-rules.lua`, and two suites. A half-done edit fails a
//    suite; that is the point.
//
// ## Fields
//
//   field      type                 domain                      required
//   layer      integer, wlr enum    BACKGROUND|BOTTOM|TOP|OVERLAY   yes
//   focus      string               none|ondemand|exclusive     yes
//   exclusion  string               normal|ignore               yes
//   mask       string               none|empty|content          yes
//   mapped     string               always|open                 yes
//   order      integer              Hyprland rule order, 0 = default   yes
//   rule       boolean              true if a layer rule is required   yes
//   clients    array of strings     the views that map the class, non-empty   yes
//
// Layer levels are the `wlr-layer-shell-unstable-v1` enum. They are integers
// because this is a pure JS library with no Qt imports; `LayerSurface` maps them
// back to `WlrLayer`.
var BACKGROUND = 0
var BOTTOM = 1
var TOP = 2
var OVERLAY = 3

var FIELDS = ["layer", "focus", "exclusion", "mask", "mapped", "order", "rule", "clients"]

var DOMAINS = {
  layer: [BACKGROUND, BOTTOM, TOP, OVERLAY],
  focus: ["none", "ondemand", "exclusive"],
  exclusion: ["normal", "ignore"],
  mask: ["none", "empty", "content"],
  mapped: ["always", "open"]
}

var NAME_PATTERN = /^vibranium:[a-z]+(-[a-z]+)*$/

// `order` counts DOWN: the lowest value renders on top. `0` means the
// compositor default, which needs no rule for ordering.
//
// A class earns a row only when it differs from every other row in something
// the compositor or the input path can observe: layer, keyboard mode, exclusion,
// input region, mapping, order or rule. A class that differs in nothing is a
// duplicate, and the whole list would be one row longer with no new fact in it.
var SPECS = {
  // The wallpaper is drawn by the shell rather than by a daemon, on the one
  // layer that sits under everything a window can put on a screen.
  "vibranium:wallpaper": { layer: BACKGROUND, focus: "none", exclusion: "ignore", mask: "none", mapped: "always", order: 0, rule: false, clients: ["wallpaper"] },

  // The bar is the only surface that reserves space, and Bottom is the level
  // that keeps it there. A tiled window can never overlap it (the exclusive
  // zone), a floating window can draw over it (a bar that punched through a
  // float would be a layer surface pretending to be chrome), and a fullscreen
  // toplevel covers it outright rather than fading it like the Top layer.
  "vibranium:bar": { layer: BOTTOM, focus: "none", exclusion: "normal", mask: "none", mapped: "always", order: 0, rule: false, clients: ["bar"] },

  // The bar's move/drop proxy. Full-screen for the session on purpose: the
  // gesture needs the surface under the pointer for the whole drag, and a held
  // pointer only stays on the pressed surface while some window of this client
  // holds keyboard focus - a strip-sized proxy would drop the drag the moment
  // the cursor left the bar. The content mask is what keeps the idle surface
  // from eating module clicks.
  "vibranium:bar-drag": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "content", mapped: "always", order: 0, rule: false, clients: ["bar-move"] },

  // The capture host is on Top and invisible: it is mapped for the
  // frame -> grab -> decode hop only, and an empty input region keeps the
  // pointer off it for that interval.
  "vibranium:capture": { layer: TOP, focus: "none", exclusion: "ignore", mask: "empty", mapped: "open", order: 0, rule: false, clients: ["screenshot-host"] },

  // Overlay rather than Top: Hyprland fades the whole Top layer when a window
  // goes fullscreen, which is why the island and the pile both left it. The
  // rule's order puts the island under the modal visits (0) and over the
  // notification pile (2).
  "vibranium:island": { layer: OVERLAY, focus: "ondemand", exclusion: "ignore", mask: "none", mapped: "open", order: 1, rule: true, clients: ["island"] },

  // The visits: every full-screen menu-family scrim, plus the two modals that
  // are not MenuLib (the polkit prompt and the network QR). One class because
  // they keep one contract - a dim on every screen, the panel and the exclusive
  // keyboard on the primary alone - and because they are already mutually
  // exclusive through SurfaceClaim: eight of these nine claim the screen when
  // they open, so only one can be up at a time. The polkit prompt is the
  // exception - it is summoned by the system rather than by the user, and
  // standing it down for a menu would deny an authentication nobody asked the
  // shell to cancel - so it shares the class but not the claim.
  "vibranium:modal": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false, clients: ["menu", "launcher", "clipboard", "power", "pass", "theme-picker", "wallpaper-picker", "polkit", "network-qr"] },

  // The transient menus that hang off something else: the tray's context menu
  // and the desktop's right-click menu. OnDemand only while open - neither has
  // a card of its own to draw a keyboard into, and Escape is the whole keyboard
  // surface. Both claim the screen like a visit: a context menu and a fullscreen
  // visit cannot share it, and a popup left mapped under a visit's dim would
  // reappear when the visit closed.
  "vibranium:popup": { layer: OVERLAY, focus: "ondemand", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false, clients: ["tray", "wallpaper-menu"] },

  // The passive read-outs: the OSD and the tooltip. They show text and take no
  // pointer, so one click-through class covers both.
  "vibranium:hud": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "empty", mapped: "open", order: 0, rule: false, clients: ["osd", "tooltip"] },

  // The notification pile keeps its own class because it is the one overlay
  // ordered under the island, and a card is the only surface whose input region
  // is its own drawn box.
  "vibranium:notifications": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "content", mapped: "open", order: 2, rule: true, clients: ["notifications"] },

  // The dots stay mapped for the session: an Overlay map/unmap on every
  // fullscreen toggle re-maps the surface and replays the layer fade. The rule
  // carries them over the session lock, which draws above every layer.
  "vibranium:privacy": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "empty", mapped: "always", order: -1, rule: true, clients: ["privacy"] },

  // The capture surfaces. The two selectors keep separate classes because the
  // capture flow tells them apart by namespace: it waits for the picker's
  // `closelayer` event before it grabs the frame, and one shared name would let
  // the region selector's unmap settle the picker's handoff. The annotator is
  // the one visit overlay allowed to share the screen with another - it is the
  // last step of a capture the user asked for - so its rule orders it above the
  // modal band.
  "vibranium:capture-region": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: true, clients: ["region-selector"] },
  "vibranium:capture-picker": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: true, clients: ["target-picker"] },
  "vibranium:annotate": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: -1, rule: true, clients: ["annotation-editor"] },

  // The color pick samples pixels, so it has to sit above the annotator's
  // board: -2 is one step over the annotator's -1 and two over the modal band.
  "vibranium:color-pick": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: -2, rule: true, clients: ["color-picker"] }
}

function spec(namespace) {
  return Object.prototype.hasOwnProperty.call(SPECS, namespace) ? SPECS[namespace] : null
}

function has(namespace) {
  return Object.prototype.hasOwnProperty.call(SPECS, namespace)
}

function names() {
  return Object.keys(SPECS)
}

// The views that map a window with this namespace, or an empty list for a
// namespace the table does not know.
function clientsOf(namespace) {
  var s = spec(namespace)
  return s === null ? [] : s.clients
}

function layerFor(namespace) {
  var s = spec(namespace)
  return s === null ? OVERLAY : s.layer
}

function focusFor(namespace) {
  var s = spec(namespace)
  return s === null ? "none" : s.focus
}

function exclusionFor(namespace) {
  var s = spec(namespace)
  return s === null ? "ignore" : s.exclusion
}

// The namespace a Hyprland layer rule must match, when the class needs one.
function needsRule(namespace) {
  var s = spec(namespace)
  return s !== null && s.rule === true
}

// Every namespace with order != 0, which is exactly the set a rule has to
// order: the compositor's default order is 0.
function orderedNames() {
  return names().filter(function (n) { return SPECS[n].order !== 0 })
}

// Namespaces declared by more than one row, which would make one layer rule
// govern two classes silently.
function duplicates() {
  var seen = {}
  var dupes = []
  names().forEach(function (n) {
    if (seen[n] === true) dupes.push(n)
    seen[n] = true
  })
  return dupes
}

// The conformance clauses above, applied to a table. Returns one string per
// violation and an empty array for a conforming table. Production code never
// calls this - the JS suite runs it against the shipped table and against
// deliberately broken ones - so it stays a reader of the data rather than a
// gate in the mapping path.
function validate(table) {
  var specs = table === undefined ? SPECS : table
  var problems = []
  var owners = {}

  Object.keys(specs).forEach(function (name) {
    var row = specs[name]
    if (!NAME_PATTERN.test(name)) {
      problems.push(name + ": name is not vibranium:<lowercase-hyphen>")
    }
    FIELDS.forEach(function (field) {
      if (!Object.prototype.hasOwnProperty.call(row, field)) {
        problems.push(name + ": missing field " + field)
      }
    })
    Object.keys(row).forEach(function (field) {
      if (FIELDS.indexOf(field) < 0) {
        problems.push(name + ": unknown field " + field)
      }
    })
    Object.keys(DOMAINS).forEach(function (field) {
      if (row[field] !== undefined && DOMAINS[field].indexOf(row[field]) < 0) {
        problems.push(name + ": " + field + " is outside its domain")
      }
    })
    if (typeof row.order !== "number" || row.order % 1 !== 0) {
      problems.push(name + ": order is not an integer")
    } else if (row.order !== 0 && row.rule !== true) {
      problems.push(name + ": order " + row.order + " without a rule")
    }
    if (typeof row.rule !== "boolean") {
      problems.push(name + ": rule is not a boolean")
    }
    if (!Array.isArray(row.clients) || row.clients.length === 0) {
      problems.push(name + ": clients is not a non-empty list")
      return
    }
    row.clients.forEach(function (client) {
      if (typeof client !== "string" || client === "") {
        problems.push(name + ": a client is not a name")
        return
      }
      if (Object.prototype.hasOwnProperty.call(owners, client)) {
        problems.push(client + ": mapped by both " + owners[client] + " and " + name)
      }
      owners[client] = name
    })
  })

  return problems
}
