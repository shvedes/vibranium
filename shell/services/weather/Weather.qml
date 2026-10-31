pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import qs.common
import "Model.js" as Model

// Weather service - single source of truth for forecast data. Owns the
// location file, both fetch trees (wttr.in fallback + Open-Meteo
// primary), the refresh cadence with its retry burst, the location
// editor state and every derived readout; the bar module and its island
// are thin views over this state.
//
// Why a service: the bar zone rebuilds every module delegate on any
// membership toggle, so per-instance reports died with the delegate -
// each toggle restarted the fetches from null and the icon flipped
// loading -> wttr -> open-meteo (the 2-3x flicker), once per monitor.
// Shared and always warm, a recreated delegate binds last-good data
// instantly and toggles spawn no fetches at all.
//
// Data strategy (adapted from Omarchy's weather panel):
//   - Open-Meteo is the fast primary: one request bundles current
//     conditions + 7-day forecast, no API key, WMO codes map straight to
//     our SVG set. With coordinates it fires immediately.
//   - wttr.in ?format=j1 is the fallback: slower and capped at ~3 days,
//     and it is the fallback only for a refresh that has coordinates. A
//     refresh without any goes to wttr.in first, because Open-Meteo needs
//     latitude/longitude and resolving them from the IP is what wttr.in
//     is for; that is the location-resolution step, not a fallback, and
//     the island still works when Open-Meteo is unreachable.
//   - One cycle carries one provider request: the Open-Meteo query is the
//     whole refresh, and the wttr.in leg is a cycle of its own entered
//     once the Open-Meteo burst is spent.
//   - Location lives in the shared shell.jsonc "weather" section as
//     {"name", "latitude", "longitude"} (same shape as Omarchy, so the
//     format is familiar). A missing/empty section means IP auto-detect.
//   - Units: shell.statusbar.weatherUnit override ("auto", "metric",
//     "imperial") > wttr-reported country > system locale. A cycle that
//     never reaches wttr.in carries no country, so the locale decides.
//   - Refresh every shell.statusbar.weatherRefreshMinutes (default 15),
//     with a short retry burst so waking with the network down does not
//     leave a stale icon until the next cycle.
Singleton {
  id: root

  readonly property string tag: "weather"

  // --- location state (ShellState "weather" section) ---

  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property string locationQuery: Model.wttrLocationQuery(
    configuredLocationState.name,
    configuredLocationState.latitude, configuredLocationState.longitude)
  // Read through the same range-validated boundary the provider query uses,
  // so an out-of-range or non-finite pair never counts as configured.
  readonly property bool hasConfiguredCoordinates:
    Model.coordinatesOf(configuredLocationState.latitude, configuredLocationState.longitude) !== null

  Component.onCompleted: {
    // Location source of truth is shell.jsonc.
    root._syncLocationFromState()
  }

  Connections {
    target: AppState
    function onRevChanged() { root._syncLocationFromState() }
  }

  // Re-read the section (reactive through AppState.rev); assign only
  // on real change so the sync never loops back into a fetch.
  function _syncLocationFromState() {
    const sec = ShellState.section("weather")
    const next = Model.parseLocationFile(sec ? JSON.stringify(sec) : "")
    const cur = root.configuredLocationState
    if (cur && cur.name === next.name && cur.latitude === next.latitude && cur.longitude === next.longitude) return
    root.configuredLocationState = next
  }

  onLocationQueryChanged: {
    if (root.savingLocation) root.savingLocationQueryStarted = true
    root.forecastRetries = 0
    root.dailyForecastRetries = 0
    root._abortForecast()
    root._abortDailyForecast()
    // The place changed, so only a person changed it: the UI editor writes
    // the section, and an external write of the same section is a person too.
    Qt.callLater(root.refresh)
  }

  // --- weather reports (last-good kept on failure, like Omarchy) ---

  property var report: null // wttr.in j1
  property var dailyForecastReport: null // open-meteo
  property int forecastRetries: 0
  property int dailyForecastRetries: 0
  // Set when the wttr.in leg of the cycle in flight is the fallback for a
  // refresh that has coordinates. refresh() clears it and
  // _startWttrFallback() sets it, so the flag never outlives the cycle it
  // describes.
  property bool wttrFallbackActive: false
  // No validated coordinate pair could be resolved, so the daily forecast
  // request is declined rather than sent malformed. Distinct from a fetch
  // still in flight, which is not a fault.
  readonly property bool forecastUnavailable: root._forecastUnavailable
  property bool _forecastUnavailable: false

  // Location editor state (the island drives these; shared so two
  // monitors never edit divergently).
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""
  // Newest geocoding request. Bumped on every recorded query change, on
  // every issued request, and when the editor opens or closes, so a response
  // is matched against the request that is still current.
  property int _geocodeGeneration: 0

  // Shared bar/island icon: SVG name from Model.js ("" while loading).
  property string conditionIcon: ""
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(root.dailyForecastReport)
  readonly property var current: (root.hasConfiguredCoordinates && root.openMeteoCurrent)
    ? root.openMeteoCurrent
    : ((root.report && root.report.current_condition && root.report.current_condition[0])
      ? root.report.current_condition[0] : root.openMeteoCurrent)
  readonly property var areaInfo: (root.report && root.report.nearest_area && root.report.nearest_area[0])
    ? root.report.nearest_area[0] : null
  readonly property var forecastDays: Model.buildForecastDays(
    root.report, root.dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  // Hourly outlook: seven cells on a two-hour cadence starting at the next
  // full hour, not eight consecutive hours. The strip sizes its cells to
  // what they print, so entries buy width, not resolution: dropping to six
  // left the card with room to spare, and eight would crowd the row.
  // Crossing midnight into tomorrow (open-meteo only, [] on the wttr
  // fallback) - the island's full-width hourly row above the 7-day strip.
  // Re-evaluated per refresh; no clock timer.
  readonly property var hourlyForecast: Model.openMeteoHourlyForecast(
    root.dailyForecastReport, Date.now(), 7, 2)
  readonly property string reportCountry: (root.areaInfo && root.areaInfo.country && root.areaInfo.country[0])
    ? root.areaInfo.country[0].value : ""

  readonly property bool useImperial: Model.shouldUseImperial(
    String(Settings.value("shell.statusbar.weatherUnit") ?? ""), Qt.locale().name, root.reportCountry)
  // Hour labels share the bar clock's format: "21:00" in 24h, "9 PM"
  // in 12h. Read off the shared verdict, not the key.
  readonly property bool clockUse12h: TimeFormat.use12h
  readonly property int refreshMinutes: Math.max(1, parseInt(Settings.value("shell.statusbar.weatherRefreshMinutes"), 10) || 15)
  // Verbose forecast rows (per-day feels/wind/humidity/rain), toggled in
  // Settings -> Bar -> Module options -> Weather.
  readonly property bool verbose: Settings.value("shell.statusbar.weatherVerbose") === true
  // Temperature label next to the icon, toggled in the same place.
  // Anything but an explicit false keeps it on, matching the schema
  // default of true for pre-existing configs.
  readonly property bool showTemp: Settings.value("shell.statusbar.weatherShowTemp") !== false

  // The place the report is about: the configured name when there is one,
  // else the area a wttr.in nearest_area reported. A configured pair that
  // carries no name has no honest label - wttr.in ?format=%l would report the
  // place derived from the request IP, not from the coordinates in the URL,
  // so a machine in Berlin holding a hand-edited Tokyo pair would label
  // itself Berlin. Blank is the truthful reading of a config with no name.
  readonly property string reportLocation: root.configuredLocation
    || ((root.areaInfo && root.areaInfo.areaName && root.areaInfo.areaName[0]) ? root.areaInfo.areaName[0].value : "")
  readonly property string reportTempNum: root.current
    ? String(root.useImperial ? root.current.temp_F : root.current.temp_C) : ""
  readonly property string tempUnit: "°" + (root.useImperial ? "F" : "C")
  readonly property string reportFeels: root.current
    ? Model.formatTemp(root.useImperial ? root.current.FeelsLikeF : root.current.FeelsLikeC, root.useImperial) : ""
  readonly property string reportWind: root.current
    ? (root.useImperial ? (root.current.windspeedMiles + " mph") : (root.current.windspeedKmph + " km/h")) : ""
  readonly property string reportHumidity: root.current ? (root.current.humidity + "%") : ""
  // Second hero row. The three ride the same current block the row above
  // already reads, so they cost no extra request; wttr.in spells them
  // pressure / cloudcover / precipMM and Model.openMeteoCurrentCondition
  // normalizes onto exactly those keys, so one shape serves both sources.
  // Each guards on its own value: a payload missing the field renders
  // nothing rather than a bare cap or a lone unit.
  readonly property string reportPressure: root.current && root.current.pressure !== ""
    ? (root.useImperial ? Model.hpaToInHg(root.current.pressure) + " inHg" : root.current.pressure + " hPa")
    : ""
  readonly property string reportCloud: root.current && root.current.cloudcover !== ""
    ? root.current.cloudcover + "%" : ""
  readonly property string reportPrecip: root.current && root.current.precipMM !== ""
    ? (root.useImperial ? Model.mmToInches(root.current.precipMM) + " in" : root.current.precipMM + " mm")
    : ""

  readonly property string tooltipText: {
    if (root.forecastUnavailable) return "Weather unavailable - no valid location"
    if (!root.current) return root.reportLocation !== "" ? root.reportLocation + " - fetching forecast..." : "Fetching forecast..."
    return root.reportLocation + "\n" + root.reportTempNum + root.tempUnit
      + "\nFeels " + root.reportFeels + "\nWind " + root.reportWind + "\nHum " + root.reportHumidity
  }
  // module falls back to tooltipText.
  readonly property var tooltipLines: {
    if (!root.current) return []
    return [
      { icon: "city", text: root.reportLocation },
      { icon: "thermometer", text: root.reportTempNum + root.tempUnit + " (" + root.reportFeels + ")" },
      { icon: "wind", text: root.reportWind },
      { icon: "weather-droplet", text: root.reportHumidity }
    ]
  }

  // One cycle issues at most one provider request: the Open-Meteo query is
  // the whole refresh, and the wttr.in leg is a separate cycle of its own,
  // entered only when the Open-Meteo burst is spent. Both legs retry through
  // their own burst, so one provider in flight is a property of the state
  // machine rather than a scheduling accident.
  function refresh() {
    root.forecastRetries = 0
    root.dailyForecastRetries = 0
    root.wttrFallbackActive = false
    if (root._hasCoordinates()) {
      root.refreshDailyForecast()
    } else {
      // IP auto-detect goes to the provider that resolves a place from the
      // IP, which is not a fallback: Open-Meteo needs latitude/longitude and
      // no step in the service can produce them without a place name. The
      // wttr.in leg is the location-resolution step here, and its
      // nearest_area is what the Open-Meteo query is built from. The two legs
      // stay sequential - the wttr.in answer has to land before there are
      // coordinates to ask about - so they are never in flight together.
      root._startForecast()
    }
  }

  // The wttr.in fallback leg for a refresh that has coordinates: reachable
  // only once the Open-Meteo burst is spent, which happens with that request
  // settled. Refusing while the wttr.in leg is in flight is the guard that
  // keeps one provider request per cycle.
  function _startWttrFallback() {
    if (root._forecastReq) return
    root.wttrFallbackActive = true
    root.forecastRetries = 0
    root._startForecast()
  }

  // The coordinate pair every provider query is built from: the configured
  // one when it validates, else the pair a wttr.in nearest_area supplied.
  // Both members go through the same range check, so a provider-reported
  // area is not trusted input either.
  function _coordinates() {
    if (root.hasConfiguredCoordinates)
      return Model.coordinatesOf(root.configuredLocationState.latitude, root.configuredLocationState.longitude)
    const area = root.areaInfo
    if (!area) return null
    return Model.coordinatesOf(area.latitude, area.longitude)
  }

  function _hasCoordinates() {
    return root._coordinates() !== null
  }

  // No validated coordinate pair means no request at all: the provider gets
  // a well-formed query or nothing.
  function refreshDailyForecast() {
    if (root._dailyReq) return
    const pair = root._coordinates()
    if (!pair) {
      // The wttr.in leg may still be in flight and its nearest_area may yet
      // supply a pair, so the verdict waits for that leg to settle and only
      // then reports unavailable.
      root._forecastUnavailable = root._forecastReq === null
      return
    }
    root._forecastUnavailable = false
    const url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(pair.latitude))
      + "&longitude=" + encodeURIComponent(String(pair.longitude))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + ",apparent_temperature_max,precipitation_probability_max,wind_speed_10m_max"
      + "&hourly=temperature_2m,relative_humidity_2m,weather_code,precipitation_probability,is_day"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m"
      + ",pressure_msl,cloud_cover,precipitation,weather_code,is_day"
      + "&forecast_days=8&timezone=auto"
    root._startDailyForecast(url)
  }

  // Unit toggle (the island's hero temperature). Writes the unit opposite
  // to the one currently reading, not the opposite of the raw setting: the
  // setting may be "auto" and answered by the country or the locale, and a
  // click has to move the readout, not restate a preference that produced
  // it. The write is the schema option, so it is validated and persisted,
  // and useImperial re-reads it - every readout follows from the one write.
  function toggleUnits() {
    const next = root.useImperial ? "metric" : "imperial"
    Settings.setOption("shell.statusbar.weatherUnit", next)
  }

  // --- location editing (island calls in; same flow as Omarchy) ---

  function startEditingLocation() {
    root.editingLocation = true
    root.savingLocation = false
    root.savingLocationQueryStarted = false
    root._invalidateGeocode()
  }

  function cancelEditingLocation() {
    root.editingLocation = false
    root.savingLocation = false
    root.savingLocationQueryStarted = false
    root._invalidateGeocode()
  }

  function commitLocation(text, suggestions, selectedIndex) {
    const location = Model.locationCommit(text, suggestions, selectedIndex)
    if (location.name === "") {
      root.clearLocation()
      return
    }
    root.savingLocation = true
    root.savingLocationQueryStarted = false
    root.configuredLocationState = { name: location.name, latitude: location.latitude, longitude: location.longitude }
    root.persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    root.persistLocation("", null, null)
    root.cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    root.savingLocation = true
    root.savingLocationQueryStarted = false
    root.configuredLocationState = { name: suggestion.name, latitude: suggestion.latitude, longitude: suggestion.longitude }
    root.persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (root.savingLocation && root.savingLocationQueryStarted) root.cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name === "") {
      ShellState.setSection("weather", { name: "", latitude: null, longitude: null })
      // Clearing is synchronous enough: drop back to auto-detect now.
      root.configuredLocationState = { name: "", latitude: null, longitude: null }
      Qt.callLater(root.refresh)
      return
    }
    let loc
    if (name && latitude !== null && longitude !== null)
      loc = { name: name, latitude: latitude, longitude: longitude }
    else
      loc = { name: name }
    ShellState.setSection("weather", loc)
    root._afterLocationSaved()
  }

  // Post-save refresh: the section write is synchronous in memory (flush is
  // debounced), so the same sequence runs inline.
  function _afterLocationSaved() {
    if (!root.savingLocation) return
    if (!root.savingLocationQueryStarted) {
      root.savingLocationQueryStarted = true
      root.forecastRetries = 0
      root.dailyForecastRetries = 0
      root._abortForecast()
      root._abortDailyForecast()
      Qt.callLater(root.refresh)
    }
  }

  function requestGeocode(query) {
    const q = String(query || "").trim()
    if (q.length < 2) {
      root._invalidateGeocode()
      return
    }
    if (q !== root.geocodePendingQuery) root._geocodeGeneration++
    root.geocodePendingQuery = q
    geocodeDebounce.restart()
  }

  // Drops the in-flight geocode request and retires its generation, so a
  // response already on the wire can no longer land. Clears the suggestion
  // list the same way an empty query does.
  function _invalidateGeocode() {
    geocodeDebounce.stop()
    root._abortGeocode()
    root._geocodeGeneration++
    root.geocodePendingQuery = ""
    root.geocodeActiveQuery = ""
    root.locationSuggestions = []
    root.suggestionIndex = 0
  }

  function startGeocode() {
    root.geocodeActiveQuery = root.geocodePendingQuery
    const generation = root._geocodeGeneration
    const query = root.geocodeActiveQuery
    const tail = "&count=10&language=en&format=json"
    const url = "https://geocoding-api.open-meteo.com/v1/search?name="
      + encodeURIComponent(query) + tail
    root._startGeocode(url, generation)
  }

  function dayName(dateString) {
    return Model.dayName(dateString, date => Qt.formatDate(date, "dddd"))
  }

  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, root.useImperial)
  }

  function dayIcon(day) {
    return Model.dayIcon(day)
  }

  // Bare temp ("18°") and icon for one hourlyForecast entry.
  function hourTemp(entry) {
    return Model.hourTemp(entry, root.useImperial)
  }

  function hourIcon(entry) {
    return Model.hourIcon(entry)
  }

  // Full clock label for one hourlyForecast entry ("21:00", "9 PM").
  // The carrier Date only feeds Qt's padding/meridiem logic; the hour
  // is the entry's target-zone wall hour.
  function hourLabel(entry) {
    if (!entry) return ""
    const d = new Date(2000, 0, 1, entry.hour, 0)
    return root.clockUse12h ? Qt.formatDateTime(d, "h AP") : Qt.formatDateTime(d, "HH:mm")
  }

  function dayDetailsLine(day) {
    return Model.dayDetailsLine(day, root.useImperial)
  }

  // --- fetch transport (XMLHttpRequest, no curl forks) ---

  // In-flight request handles (null when idle); aborting marks them dead
  // so no callback fires, mirroring `proc.running = false` semantics.
  property var _forecastReq: null
  property var _dailyReq: null
  property var _geocodeReq: null

  // Minimal GET: onDone gets the response text, or "" on any failure
  // (timeout, HTTP error). Superseded handles never call back.
  // User-Agent spoofs curl: wttr.in serves bot-gate HTML to unknown
  // agents (which would poison JSON.parse), while the curl agent gets
  // the payloads the endpoints serve.
  //
  // onDone also carries the transport's own reason for handing back
  // nothing, so a caller reports the branch that produced the failure
  // instead of inventing a code at each site.
  function _get(url, timeoutMs, onDone) {
    const target = _netTarget(url)
    let xhr = null
    try { xhr = new XMLHttpRequest() } catch (e) { Qt.callLater(() => { onDone("", "no_transport", target) }); return { abort() {} } }
    // Never tear down TLS mid-flight: aborting a handshaking QSslSocket
    // logs device-not-open reads. Stale responses die via the dead flag
    // while the socket drains on its own; the timeout bounds the wait.
    const handle = { dead: false, abort() { handle.dead = true } }
    const finish = (text, code) => { if (handle.dead) return; handle.dead = true; onDone(text, code, target) }
    xhr.onreadystatechange = () => {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 200) {
        finish(String(xhr.responseText || ""), "")
        return
      }
      finish("", _netStatusCode(xhr.status))
    }
    try { xhr.ontimeout = () => finish("", "timeout") } catch (e) {}
    try {
      xhr.timeout = timeoutMs
      xhr.open("GET", url)
      try { xhr.setRequestHeader("User-Agent", "curl/8.5.0") } catch (e) {}
      xhr.send()
    } catch (e) { finish("", "send_failed") }
    return handle
  }

  // The host a request went to, which is what onDone hands back with every
  // answer: everything after the scheme and before the first `/`, `?` or `#`.
  function _netTarget(url) {
    const full = String(url === undefined || url === null ? "" : url)
    const at = full.indexOf("://")
    const rest = at < 0 ? full : full.slice(at + 3)
    const cut = rest.search(/[\/?#]/)
    return cut < 0 ? rest : rest.slice(0, cut)
  }

  // A DONE with no HTTP status is a deadline or a dead route, and the two
  // arrive at the same readyState with the same status 0 - naming either
  // would claim a distinction the transport cannot make. It is named for
  // what was observed, so `http_` stays the class with a real status in it.
  function _netStatusCode(status) {
    const code = Number(status)
    return code === 0 ? "status_0" : "http_" + String(status)
  }

  function _abortForecast() {
    if (root._forecastReq) { root._forecastReq.abort(); root._forecastReq = null }
  }

  function _abortDailyForecast() {
    if (root._dailyReq) { root._dailyReq.abort(); root._dailyReq = null }
  }

  function _abortGeocode() {
    if (root._geocodeReq) { root._geocodeReq.abort(); root._geocodeReq = null }
  }

  function _startForecast() {
    if (root._forecastReq) return
    const query = root.locationQuery
    const url = "https://wttr.in/" + query + "?format=j1"
    root._forecastReq = root._get(url, 10000, (text, code, host) => {
      root._forecastReq = null
      root._onForecast(text, code, host)
    })
  }

  function _onForecast(text, code, host) {
    const raw = String(text || "").trim()
    if (!raw) {
      root.scheduleForecastRetry(host, code)
      return
    }
    try {
      const parsed = JSON.parse(raw)
      root.report = parsed
      // The wttr.in leg carries no day/night flag, so its icon only ever
      // fills an empty state (Model.provisionalCurrentIcon keeps a resolved
      // one). Filling it is right for the location-resolution leg and wrong
      // for a configured pair that is still waiting on its Open-Meteo
      // answer, where a wttr.in icon arriving first is the
      // loading -> wttr -> open-meteo flicker. A fallback leg has no second
      // answer coming, so it fills the gap instead.
      if (!root.hasConfiguredCoordinates || root.wttrFallbackActive)
        root.conditionIcon = Model.provisionalCurrentIcon(
          parsed.current_condition && parsed.current_condition[0], root.conditionIcon)
      root.forecastRetries = 0
      // Whichever provider answered a save carries the committed place, so
      // either one ends it. finishSavingLocation() is the guard that this is
      // a save in progress at all.
      root.finishSavingLocation()
      // A reported area is the pair source of last resort: it answers the
      // auto-detect cycle, and a configured pair always wins, so a wttr.in
      // answer never redirects the query for a location the user committed.
      if (!root.hasConfiguredCoordinates) root.refreshDailyForecast()
    } catch (e) {
      // A 200 the provider did not mean as JSON: the bot-gate HTML the
      // spoofed agent exists to avoid, or a truncated body.
      root.scheduleForecastRetry(host, "parse")
    }
  }

  // One burst per leg, capped, so running out of attempts is a terminal
  // outcome with no static counterpart: the last good report is what stays
  // on screen until the next cycle, and nothing in the source says so.
  function scheduleForecastRetry(host, code) {
    if (root.forecastRetries >= 3) {
      // A spent wttr.in burst ends the cycle: the leg is the fallback for a
      // refresh that has coordinates and the location-resolution step for
      // one that has none, and re-issuing it asks the same host the same
      // question. The last good report stays on screen until the next cycle.
      root.wttrFallbackActive = false
      return
    }
    root.forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: root._startForecast()
  }

  function scheduleDailyForecastRetry(host, code) {
    if (root.dailyForecastRetries >= 3) {
      // The Open-Meteo burst is spent, so a refresh that has coordinates
      // hands the cycle over to the fallback leg. With no usable pair there
      // is nothing to hand over to: the wttr.in leg already ran, as the
      // location-resolution step, and asking it again is the same question
      // with the same answer, so its own burst decides the cycle.
      if (root._hasCoordinates()) root._startWttrFallback()
      return
    }
    root.dailyForecastRetries++
    dailyForecastRetryTimer.restart()
  }

  Timer {
    id: dailyForecastRetryTimer
    interval: 2500
    onTriggered: root.refreshDailyForecast()
  }

  function _startDailyForecast(url) {
    if (root._dailyReq) return
    root._dailyReq = root._get(url, 5000, (text, code, host) => {
      root._dailyReq = null
      root._onDailyForecast(text, code, host)
    })
  }

  function _onDailyForecast(text, code, host) {
    const raw = String(text || "").trim()
    if (!raw) {
      root.scheduleDailyForecastRetry(host, code)
      return
    }
    try {
      const parsed = JSON.parse(raw)
      const parsedCurrent = Model.openMeteoCurrentCondition(parsed)
      root.dailyForecastReport = parsed
      root.conditionIcon = Model.currentIcon(parsedCurrent, root.conditionIcon)
      root.dailyForecastRetries = 0
      root.finishSavingLocation()
    } catch (e) {
      root.scheduleDailyForecastRetry(host, "parse")
    }
  }

  function _startGeocode(url, generation) {
    if (root._geocodeReq) return
    root._geocodeReq = root._get(url, 5000, (text, code, host) => {
      root._geocodeReq = null
      root._onGeocode(text, generation, code, host)
    })
  }

  // A reply applies only to the generation that requested it. A superseded
  // reply is dropped, and the query that replaced it goes out instead, so a
  // late answer can never overwrite the results of a newer keystroke.
  function _onGeocode(text, generation, code, host) {
    if (generation === root._geocodeGeneration) {
      // The endpoint answers with a document even when it found nothing, so
      // no document at all is a transport failure and not a zero-hit answer.
      // Nothing downstream can tell those two apart today.
      root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
      root.suggestionIndex = 0
      return
    }
    // Dropping a late answer is a correct outcome, not a failure, and it
    // is silent: the empty suggestion list it leaves behind reads
    // as "no matches" rather than as a keystroke that lost its race.
    if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
  }

  // Collapses the island's per-keystroke requestGeocode into one request
  // per pause: the pending query is replaced on every keystroke, and this
  // fires only after the last one. It calls startGeocode, not
  // requestGeocode: the latter re-arms this timer, so routing through it
  // would pair the two into an endless 300ms loop. The retry after a
  // dropped late answer re-enters startGeocode directly (above) and skips
  // this on purpose: one follow-up to a lost race, not a fan-out.
  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: {
      if (root._geocodeReq) return
      root.startGeocode()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
