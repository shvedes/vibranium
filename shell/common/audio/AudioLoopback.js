.pragma library

var CHANNEL_RE = /_([A-Za-z0-9]{1,4})$/
var PORT_ROW_RE = /^[ \t]*([0-9]+)[ \t]+(.+?)[ \t]*$/
var LINK_ROW_RE = /^[ \t]*([0-9]+)[ \t]+[|](<-|->)[ \t]+([0-9]+)[ \t]+(.+?)[ \t]*$/
var GLOB_RE = /[*?]/

function safePath(path) {
  if (typeof path !== "string") return false
  const value = path.trim()
  return value !== "" && value.charAt(0) !== "-"
    && value.indexOf("\u0000") < 0 && value.indexOf("\n") < 0 && !GLOB_RE.test(value)
}

function nodeId(node) {
  if (!node) return ""
  const id = node.id
  if (typeof id === "number" && isFinite(id) && id >= 0) return String(Math.round(id))
  if (typeof id === "string" && /^\d+$/.test(id.trim())) return id.trim()
  return ""
}

function nodeName(node) {
  return node && typeof node.name === "string" ? node.name.trim() : ""
}

function ports(text, name, prefix) {
  const out = []
  if (typeof text !== "string" || !safePath(name)) return out
  // Prefix match, not first-colon split: a node NAME may itself contain
  // a colon ("alsa:foo" serves "alsa:foo:capture_FL"), and splitting on
  // the first colon reads the name as "alsa" and misses every port.
  const head = name + ":"
  const lines = text.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "").trim()
    if (line.slice(0, head.length) !== head) continue
    const port = line.slice(head.length).trim()
    if (port.indexOf(prefix) !== 0) continue
    const path = name + ":" + port
    if (!safePath(path)) return []
    out.push({ name: port, path: path })
  }
  return out
}

function channelKey(port) {
  const match = CHANNEL_RE.exec(typeof port === "string" ? port : "")
  return match === null ? "" : match[1].toLowerCase()
}

// Pair all channels or refuse the incomplete layout.
function plan(sourceName, sinkName, outputText, inputText) {
  if (!safePath(sourceName) || !safePath(sinkName) || sourceName === sinkName) {
    return { pairs: [], error: "default audio devices have unsafe or identical names" }
  }
  const outputs = ports(outputText, sourceName, "capture_")
  const inputs = ports(inputText, sinkName, "playback_")
  if (outputs.length === 0 || inputs.length === 0) {
    return { pairs: [], error: "default input or output has no usable audio ports" }
  }
  const solo = outputs.length === 1 && inputs.length === 1
    && channelKey(outputs[0].name) === "" && channelKey(inputs[0].name) === ""
  const used = ({})
  const pairs = []
  for (let i = 0; i < outputs.length; i++) {
    const key = channelKey(outputs[i].name)
    let found = -1
    for (let j = 0; j < inputs.length; j++) {
      if (used[j] === true) continue
      if (key === "" ? solo && channelKey(inputs[j].name) === ""
        : channelKey(inputs[j].name) === key) { found = j; break }
    }
    if (found < 0) return { pairs: [], error: "input and output channel layouts do not match" }
    used[found] = true
    pairs.push({ output: outputs[i].path, input: inputs[found].path })
  }
  return pairs.length === inputs.length
    ? { pairs: pairs, error: "" }
    : { pairs: [], error: "input and output channel layouts do not match" }
}

// Each endpoint is shown twice by pw-link; its link id deduplicates them.
function parseLinks(text) {
  const out = []
  if (typeof text !== "string" || text === "") return out
  const seen = ({})
  let current = ""
  const lines = text.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    const link = LINK_ROW_RE.exec(line)
    if (link !== null) {
      if (current === "") continue
      const route = link[2] === "<-"
        ? { id: link[1], output: link[4].trim(), input: current }
        : { id: link[1], output: current, input: link[4].trim() }
      if (seen[route.id] === true) continue
      seen[route.id] = true
      if (safePath(route.output) && safePath(route.input)) out.push(route)
      continue
    }
    const row = PORT_ROW_RE.exec(line)
    current = row === null || row[2].charAt(0) === "|" ? "" : row[2].trim()
  }
  return out
}

function identifyLinks(links, nodes) {
  const ids = ({})
  for (let i = 0; nodes && i < nodes.length; i++) {
    const name = nodeName(nodes[i])
    const id = nodeId(nodes[i])
    if (name !== "" && id !== "") ids[name] = id
  }
  const out = []
  for (let i = 0; Array.isArray(links) && i < links.length; i++) {
    const link = links[i]
    const sourceId = ids[link.output.split(":")[0]]
    const sinkId = ids[link.input.split(":")[0]]
    if (sourceId !== undefined && sinkId !== undefined) {
      out.push({ id: link.id, sourceId: sourceId, sinkId: sinkId,
        output: link.output, input: link.input })
    }
  }
  return out
}

function validRoutes(routes) {
  const out = []
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    const route = routes[i]
    const sourceId = route ? String(route.sourceId ?? "") : ""
    const sinkId = route ? String(route.sinkId ?? "") : ""
    if (!route || !/^\d+$/.test(sourceId) || !/^\d+$/.test(sinkId)
      || !safePath(route.output) || !safePath(route.input)) continue
    out.push({ sourceId: sourceId, sinkId: sinkId,
      output: route.output, input: route.input })
  }
  return out
}

function routesForDefault(pairs, sourceId, sinkId) {
  const out = []
  if (!Array.isArray(pairs) || !/^\d+$/.test(sourceId) || !/^\d+$/.test(sinkId)) return out
  for (let i = 0; i < pairs.length; i++) {
    const pair = pairs[i]
    if (pair && safePath(pair.output) && safePath(pair.input)) {
      out.push({ sourceId: sourceId, sinkId: sinkId,
        output: pair.output, input: pair.input })
    }
  }
  return out
}

function sameRoute(a, b) {
  return !!a && !!b && a.output === b.output && a.input === b.input
}

function contains(routes, route) {
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    if (sameRoute(routes[i], route)) return true
  }
  return false
}

function containsEndpoints(routes, route) {
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    const candidate = routes[i]
    if (candidate && candidate.output === route.output && candidate.input === route.input) return true
  }
  return false
}

function sameRouteIdentity(a, b) {
  if (!a || !b) return false
  if (a.output !== b.output || a.input !== b.input) return false
  if (a.sourceId !== undefined && b.sourceId !== undefined
    && String(a.sourceId) !== String(b.sourceId)) return false
  if (a.sinkId !== undefined && b.sinkId !== undefined
    && String(a.sinkId) !== String(b.sinkId)) return false
  return true
}

function containsRouteIdentity(routes, route) {
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    if (sameRouteIdentity(routes[i], route)) return true
  }
  return false
}

function removalSteps(links, owned, desired) {
  const steps = []
  for (let i = 0; Array.isArray(owned) && i < owned.length; i++) {
    const route = owned[i]
    if (containsRouteIdentity(desired, route)) continue
    steps.push({ argv: ["pw-link", "-d", route.output, route.input] })
  }
  return steps
}

function removeFromOwned(owned, command) {
  const routes = validRoutes(owned)
  if (!command || !Array.isArray(command.argv) || command.argv.length !== 4
    || command.argv[0] !== "pw-link" || command.argv[1] !== "-d") return routes
  return routes.filter(route => route.output !== command.argv[2] || route.input !== command.argv[3])
}

function addOwned(owned, desired, command) {
  const routes = validRoutes(owned)
  if (!command || !Array.isArray(command.argv) || command.argv.length !== 3
    || command.argv[0] !== "pw-link") return routes
  for (let i = 0; Array.isArray(desired) && i < desired.length; i++) {
    const route = desired[i]
    if (!route || route.output !== command.argv[1] || route.input !== command.argv[2]
      || containsEndpoints(routes, route)) continue
    routes.push(route)
    break
  }
  return routes
}

function persistableRoutes(routes) {
  const out = []
  const valid = validRoutes(routes)
  for (let i = 0; i < valid.length; i++) {
    const route = valid[i]
    const copy = { output: route.output, input: route.input }
    if (!containsEndpoints(out, copy)) out.push(copy)
  }
  return out
}

// Endpoint-only persisted pairs (the persistableRoutes shape, without node
// ids) validated back into usable pairs. ids are graph state and are not
// persisted: the next reconcile reidentifies endpoints against the live
// graph, so a stale id must never be trusted across a reboot.
function validPairs(pairs) {
  const out = []
  if (!Array.isArray(pairs)) return out
  for (let i = 0; i < pairs.length; i++) {
    const pair = pairs[i]
    if (!pair || !safePath(pair.output) || !safePath(pair.input)) continue
    const copy = { output: pair.output, input: pair.input }
    if (containsEndpoints(out, copy)) continue
    out.push(copy)
  }
  return out
}



function connectionSteps(links, owned, desired) {
  const steps = []
  for (let i = 0; Array.isArray(desired) && i < desired.length; i++) {
    const route = desired[i]
    if (contains(links, route) || contains(owned, route)) continue
    steps.push({ argv: ["pw-link", route.output, route.input] })
  }
  return steps
}

function identityForEndpoints(routes, endpoint) {
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    const route = routes[i]
    if (route && route.output === endpoint.output && route.input === endpoint.input) {
      return { sourceId: String(route.sourceId), sinkId: String(route.sinkId) }
    }
  }
  return null
}

function reidentify(routes, links, sourceId, sinkId) {
  const out = []
  for (let i = 0; Array.isArray(routes) && i < routes.length; i++) {
    const route = routes[i]
    let identity = identityForEndpoints(links, route)
    if (identity === null && route.sourceId === String(sourceId) && route.sinkId === String(sinkId)) {
      identity = { sourceId: String(sourceId), sinkId: String(sinkId) }
    }
    if (identity !== null) {
      const next = { sourceId: identity.sourceId, sinkId: identity.sinkId,
        output: route.output, input: route.input }
      if (!contains(out, next)) out.push(next)
    }
  }
  return out
}

function adoptExisting(links, desired, owned) {
  const out = validRoutes(owned)
  for (let i = 0; Array.isArray(desired) && i < desired.length; i++) {
    const route = desired[i]
    if (contains(out, route)) continue
    for (let j = 0; Array.isArray(links) && j < links.length; j++) {
      const link = links[j]
      if (!sameRoute(route, link)) continue
      out.push(route)
      break
    }
  }
  return out
}
