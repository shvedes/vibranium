.pragma library

.import "../../../../common/collections/DeviceList.js" as DeviceList
.import "../../../../common/theme/DeviceIcons.js" as DeviceIcons
.import "../../../../common/text/Format.js" as Format

// Pure helpers for the Bluetooth bar module: device projections, sorting,
// section titles and row subtext. No Qt imports - deterministic and
// unit-drivable, like the network module's Model.js.

// Human label for a device: deviceName/name, falling back to the address.
function deviceLabel(device) {
  let d = device || {}
  let name = String(d.deviceName || d.name || "").trim()
  if (name !== "") return name
  let addr = String(d.address || "")
  return addr === "" ? "Unknown device" : addr
}

// Is the device remembered (paired/bonded/trusted)?
function isKnown(device) {
  let d = device || {}
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
    let o = r || {}
    return [(o.address || ""), (o.name || ""), (o.icon || ""),
      (!!o.connected), (!!o.known), (!!o.pairing), (!!o.trusted),
      (!!o.batteryAvailable), (Number(o.battery) || 0)].join("\u0001")
  })
}

// Icon stem for a row, canonicalized in common/theme/DeviceIcons.js so
// every module shares one class matcher. Empty when the class is
// unknown - callers fall back to the bluetooth icon.
function deviceIconName(row) {
  let r = row || {}
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

// Section title for a sorted row, tiered through DeviceList. A row opens a
// header when its tier differs from the row above it, and is a continuation
// otherwise, so every section is one contiguous run of the sorted order.
//
// The tiers are the SORT's own - connected, then remembered, then the rest -
// so a header can never open above a row the sort placed out of that tier's
// order. Tiering on `known` alone did exactly that: a connected-but-unpaired
// device sorted ahead of a paired one and opened an AVAILABLE section, which
// the next row's PAIRED header then closed, giving one header per row on a
// mixed list.
//
// The helpers are nested because a .pragma library publishes every top-level
// declaration, and this module's surface is pinned by its suite.
function sectionTitleFor(index, rows) {
  function tierOf(row) {
    let r = row || {}
    if (r.connected) return "connected"
    return r.known ? "paired" : "available"
  }
  function titleOf(tier) {
    if (tier === "connected") return "CONNECTED DEVICES"
    return tier === "paired" ? "PAIRED DEVICES" : "AVAILABLE DEVICES"
  }
  return DeviceList.sectionTitleFor(index, rows, function(row, prev, i) {
    let tier = tierOf(row)
    if (i === 0 || tierOf(prev) !== tier) return titleOf(tier)
    return ""
  })
}

// Subtext for a device row: the battery level when the device reports one,
// otherwise whether it is remembered ("Paired") or brand new ("Available").
function subtextFor(row) {
  let r = row || {}
  if (r.batteryAvailable) {
    let battery = Number(r.battery)
    if (isFinite(battery)) return "Battery " + Format.percentInt(battery) + "%"
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
  // `sorted.length` is read unguarded downstream, so the LIST must be an
  // array (null throws, pinned); a string walks its characters, a number
  // walks nothing. The projection is the shared sectioned list with this
  // module's row type and trailing scan header.
  return DeviceList.sectionedEntries(
    sorted,
    function(row, prev, i) { return sectionTitleFor(i, sorted) },
    function(row) { return { type: "device", row: row } },
    includeAvailableHeader ? "AVAILABLE DEVICES" : "")
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
