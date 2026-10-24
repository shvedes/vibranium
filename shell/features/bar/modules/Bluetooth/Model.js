.pragma library

.import "../../../../common/collections/DeviceList.js" as DeviceList
.import "../../../../common/theme/DeviceIcons.js" as DeviceIcons

// Pure helpers for the Bluetooth bar module: device projections, sorting,
// section titles and row subtext. No Qt imports - deterministic and
// unit-drivable, like the network module's Model.js.

// Human label for a device: deviceName/name, falling back to the address.
function deviceLabel(device) {
  var d = device || {}
  var name = String(d.deviceName || d.name || "").trim()
  if (name !== "") return name
  var addr = String(d.address || "")
  return addr === "" ? "Unknown device" : addr
}

// Is the device remembered (paired/bonded/trusted)?
function isKnown(device) {
  var d = device || {}
  return !!d.paired || !!d.bonded || !!d.trusted
}

// Primitive snapshot of a BluetoothDevice - list models must not hold live
// QObject wrappers (BlueZ churn can destroy them mid-incubation). Actions
// resolve the backend object via the island's deviceForAddress().
function deviceRow(device) {
  if (!device) return null
  return {
    address: device.address || "",
    name: String(device.deviceName || device.name || ""),
    // A plain string (the device-type icon), not a QObject - safe to snapshot.
    icon: String(device.icon || ""),
    connected: !!device.connected,
    known: isKnown(device),
    pairing: !!device.pairing,
    trusted: !!device.trusted,
    batteryAvailable: !!device.batteryAvailable,
    battery: device.battery !== undefined ? device.battery : 0
  }
}

// Skip the assignment when nothing visible changed: syncDevices
// rebuilds a fresh array every poll tick; assigning it unconditionally
// resets the ListView model and recreates every delegate (scroll
// pursuit + settle restore fight over contentY mid-dropdown).
// Keyed through common/collections/DeviceList.js so every module's poll
// shares one equality shape.
function deviceRowsEqual(a, b) {
  return DeviceList.rowsEqual(a, b, function(r) {
    var o = r || {}
    return [(o.address || ""), (o.name || ""), (o.icon || ""),
      (!!o.connected), (!!o.known), (!!o.pairing), (!!o.trusted),
      (!!o.batteryAvailable), (Number(o.battery) || 0)].join("\u0001")
  })
}

// Icon stem for a row, canonicalized in common/theme/DeviceIcons.js so
// every module shares one class matcher. Empty when the class is
// unknown - callers fall back to the bluetooth icon.
function deviceIconName(row) {
  var r = row || {}
  return DeviceIcons.iconForDeviceClass(r.icon)
}

// Connected first, then remembered, then the rest, each by name.
// Tiered through common/collections/DeviceList.js; the name tiebreak
// stays here.
function sortDeviceRows(rows) {
  // The rank reads are unguarded on purpose: a null ENTRY throws (pinned),
  // while a null LIST is handled by the shared Array.isArray guard - the
  // island builds rows from deviceRow(), which refuses falsy devices, so
  // an entry is never null in production.
  return DeviceList.sortRows(rows,
    function(r) { return r.connected },
    function(r) { return r.known },
    function(a, b) { return deviceLabel(a).localeCompare(deviceLabel(b)) })
}

// Section title for a sorted row, tiered through DeviceList. Remembered
// (paired) devices open "PAIRED DEVICES", anything else opens
// "AVAILABLE DEVICES".
function sectionTitleFor(index, rows) {
  return DeviceList.sectionTitleFor(index, rows, function(row, prev, i) {
    if (row.known) {
      if (i === 0 || !prev.known) return "PAIRED DEVICES"
      return ""
    }
    if (i === 0 || (prev && prev.known)) return "AVAILABLE DEVICES"
    return ""
  })
}

// Subtext for a device row: the battery level when the device reports one,
// otherwise whether it is remembered ("Paired") or brand new ("Available").
function subtextFor(row) {
  var r = row || {}
  if (r.batteryAvailable) {
    var pct = Math.round(Number(r.battery) * 100)
    if (isFinite(pct)) return "Battery " + pct + "%"
  }
  return r.known ? "Paired" : "Available"
}

// Flat ListView entries for the sorted device rows: an inline
// { type: "header", title } entry at every section start, then
// { type: "device", row } entries. When `includeAvailableHeader` is set
// (adapter enabled) a trailing "AVAILABLE DEVICES" header is always
// appended - even when the section has no rows - so the scan control is
// reachable without any discovered devices.
function listEntries(sorted, includeAvailableHeader) {
  // `sorted.length` is read unguarded, so the LIST must be an array (null
  // throws, pinned); a string walks its characters, a number walks
  // nothing. The section header per row routes through sectionTitleFor,
  // which tiers through DeviceList.
  var entries = []
  var cur = ""
  for (var i = 0; i < sorted.length; i++) {
    var t = sectionTitleFor(i, sorted)
    if (t !== "") {
      cur = t
      entries.push({ type: "header", title: t })
    }
    entries.push({ type: "device", row: sorted[i] })
  }
  if (includeAvailableHeader && cur !== "AVAILABLE DEVICES") {
    entries.push({ type: "header", title: "AVAILABLE DEVICES" })
  }
  return entries
}

if (typeof module !== "undefined") {
  module.exports = {
    deviceLabel: deviceLabel,
    isKnown: isKnown,
    deviceRow: deviceRow,
    deviceIconName: deviceIconName,
    sortDeviceRows: sortDeviceRows,
    sectionTitleFor: sectionTitleFor,
    subtextFor: subtextFor,
    listEntries: listEntries
  }
}
