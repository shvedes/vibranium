// Weather/Model.js - pure weather logic for the Vibranium bar module.
//
// Lineage: inspired by Omarchy's shell/plugins/panels/weather/Model.js
// (dual-source strategy: fast Open-Meteo primary + slow wttr.in fallback,
// location file {name, latitude, longitude}, IP auto-detect, imperial
// auto-detection). This file is NOT a copy: the icon mapping returns
// Vibranium SVG icon names (shell/assets/icons/weather-*.svg, rendered
// through Icons.url and recolored to the palette) instead of nerd-font
// glyphs, and every function is written against that contract.
//
// Rules: no Qt/QML imports here - only plain JS so the logic stays
// testable from node (mirroring how Omarchy tests its Model.js).
// Callers pass todayString ("yyyy-MM-dd") and formatters in; the module
// never reads the clock itself.

// A latitude/longitude pair is usable only when both members are finite
// numbers inside their real range. An isNaN-only check is not enough:
// parseFloat("Infinity") succeeds, and an out-of-range pair is a
// malformed request to every provider, not a usable location.
function coordinatesOf(latitude, longitude) {
  var lat = parseFloat(String(latitude))
  var lon = parseFloat(String(longitude))
  if (!isFinite(lat) || !isFinite(lon)) return null
  if (lat < -90 || lat > 90) return null
  if (lon < -180 || lon > 180) return null
  return { latitude: lat, longitude: lon }
}

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...}.
// Missing, blank, or unparseable means IP auto-detect; so does a pair that
// fails the range check, which lands in the same name-only state.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset
    var pair = coordinatesOf(data.latitude, data.longitude)
    return {
      name: typeof data.name === "string" ? data.name.trim() : "",
      latitude: pair === null ? null : pair.latitude,
      longitude: pair === null ? null : pair.longitude
    }
  } catch (e) {
    return unset
  }
}

// wttr.in path segment for a configured location: exact coordinates when
// both are present and in range, the URL-encoded name as fallback
// (hand-edited files may only carry a name), empty for IP auto-detect.
function wttrLocationQuery(location, latitude, longitude) {
  var pair = coordinatesOf(latitude, longitude)
  if (pair !== null) return pair.latitude + "," + pair.longitude
  var name = String(location || "").trim()
  return name === "" ? "" : encodeURIComponent(name)
}

// Open-Meteo geocoding response -> suggestion rows for the location picker.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []
    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function (part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").trim()
  if (name === "") return { name: "", latitude: null, longitude: null }
  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion
  return { name: name, latitude: null, longitude: null }
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function celsiusToFahrenheit(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : (n * 9 / 5) + 32
}

function formatTemp(value, useImperial) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°" + (useImperial ? "F" : "C")
}

// One decimal, for readings whose integer part alone is too coarse to be
// honest: 0.4 mm of rain rounds to no rain at all.
function oneDecimal(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  if (isNaN(n)) return ""
  return String(Math.round(n * 10) / 10)
}

// Both providers report pressure in hPa (wttr.in calls it mbar, the same
// unit under its older name); imperial reads it in inHg. The divisor
// spells the constant rather than carrying a pre-multiplied factor.
function hpaToInHg(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  if (isNaN(n)) return ""
  return String(Math.round(n / 33.8639 * 100) / 100)
}

function mmToInches(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  if (isNaN(n)) return ""
  return String(Math.round(n / 25.4 * 100) / 100)
}

function normalizedUnit(value) {
  return String(value || "").trim().toLowerCase()
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name)
    || /^en[_-]LR($|[_.-])/.test(name)
    || /^my($|[_.-])/.test(name)
}

function countryUsesImperial(countryName) {
  var country = String(countryName || "").trim().replace(/[._-]+/g, " ").toLowerCase()
  if (!country) return null
  if (country === "us" || country === "usa"
    || country === "united states" || country === "united states of america") return true
  if (country === "liberia" || country === "myanmar" || country === "burma") return true
  return false
}

// Precedence: explicit setting override > wttr-reported country >
// system locale. Mirrors Omarchy so US users get °F out of the box.
function shouldUseImperial(unitOverride, localeName, countryName) {
  var unit = normalizedUnit(unitOverride)
  if (unit === "imperial") return true
  if (unit === "metric") return false
  var countryPreference = countryUsesImperial(countryName)
  if (countryPreference !== null) return countryPreference
  return localeUsesImperial(localeName)
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

function openMeteoForecastDays(dailyForecastReport, todayString, count) {
  var want = parseInt(count, 10)
  if (isNaN(want) || want < 1) want = 7
  var daily = dailyForecastReport && dailyForecastReport.daily ? dailyForecastReport.daily : null
  if (!daily || !daily.time) return []
  var hourly = dailyForecastReport.hourly || null
  var result = []
  for (var i = 0; i < daily.time.length && result.length < want; ++i) {
    var date = daily.time[i]
    if (!isFutureForecastDate(date, todayString)) continue
    var maxC = daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""
    var minC = daily.temperature_2m_min ? daily.temperature_2m_min[i] : ""
    var feelsMaxC = daily.apparent_temperature_max ? daily.apparent_temperature_max[i] : ""
    result.push({
      date: date,
      maxtempC: roundedTemp(maxC),
      mintempC: roundedTemp(minC),
      maxtempF: roundedTemp(celsiusToFahrenheit(maxC)),
      mintempF: roundedTemp(celsiusToFahrenheit(minC)),
      feelsC: roundedTemp(feelsMaxC),
      feelsF: roundedTemp(celsiusToFahrenheit(feelsMaxC)),
      precipProb: roundedTemp(daily.precipitation_probability_max ? daily.precipitation_probability_max[i] : ""),
      windKmph: roundedTemp(daily.wind_speed_10m_max ? daily.wind_speed_10m_max[i] : ""),
      windMph: roundedTemp(kmhToMph(daily.wind_speed_10m_max ? daily.wind_speed_10m_max[i] : "")),
      humidity: humidityMaxForDate(hourly, date),
      openMeteoWeatherCode: daily.weather_code ? daily.weather_code[i] : null
    })
  }
  return result
}

// km/h -> mph, ""-tolerant like the temperature helpers.
function kmhToMph(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : n * 0.621371
}

// Peak relative humidity for one calendar date from the hourly series
// (hourly.time entries are "YYYY-MM-DDTHH:MM" in the requested timezone).
// "" when the series is absent - verbose rows then omit humidity.
function humidityMaxForDate(hourly, dateString) {
  var day = String(dateString || "").slice(0, 10)
  if (!day || !hourly || !hourly.time || !hourly.relative_humidity_2m) return ""
  var best = null
  for (var i = 0; i < hourly.time.length; i++) {
    if (String(hourly.time[i] || "").slice(0, 10) !== day) continue
    var n = parseFloat(String(hourly.relative_humidity_2m[i]))
    if (!isNaN(n) && (best === null || n > best)) best = n
  }
  return best === null ? "" : String(Math.round(best))
}

// Next `count` hourly entries starting at the next hour boundary,
// crossing midnight into tomorrow (labels repeat: 23, 0, 1...).
// `step` takes every Nth entry of the series, so a caller can read a
// 12-hour outlook as six cells on a two-hour cadence instead of twelve
// cells, which the strip cannot render at a readable width anyway.
// Hourly stamps are "YYYY-MM-DDTHH:MM" wall time in the requested
// timezone: anchor them at UTC ("Z") and subtract the response's
// utc_offset_seconds to recover true epochs, so the comparison
// against nowUtcMs is machine-timezone independent. [] when the
// hourly series is absent (wttr fallback) - the island hides the
// row then.
function openMeteoHourlyForecast(dailyForecastReport, nowUtcMs, count, step) {
  var want = parseInt(count, 10)
  if (isNaN(want) || want < 1) want = 8
  var every = parseInt(step, 10)
  if (isNaN(every) || every < 1) every = 1
  var hourly = dailyForecastReport && dailyForecastReport.hourly ? dailyForecastReport.hourly : null
  if (!hourly || !hourly.time || !hourly.temperature_2m) return []
  var offsetMs = (parseFloat(dailyForecastReport.utc_offset_seconds) || 0) * 1000
  var result = []
  var seen = 0
  for (var i = 0; i < hourly.time.length && result.length < want; ++i) {
    var stamp = String(hourly.time[i] || "")
    var whenMs = Date.parse(stamp + ":00Z") - offsetMs
    if (isNaN(whenMs) || whenMs < nowUtcMs) continue
    // A skipped hour still counts against the step: the walk advances
    // through the series rather than packing entries against the front.
    if (seen % every !== 0) { seen++; continue }
    seen++
    var tempC = hourly.temperature_2m[i]
    result.push({
      time: stamp,
      hour: parseInt(stamp.slice(11, 13), 10) || 0,
      tempC: roundedTemp(tempC),
      tempF: roundedTemp(celsiusToFahrenheit(tempC)),
      precipProb: roundedTemp(hourly.precipitation_probability ? hourly.precipitation_probability[i] : ""),
      isDay: hourly.is_day ? Number(hourly.is_day[i]) !== 0 : true,
      openMeteoWeatherCode: hourly.weather_code ? hourly.weather_code[i] : null
    })
  }
  return result
}

// Open-Meteo bundles current conditions with the daily forecast request
// and answers far faster than wttr.in. Normalize them to wttr's
// current_condition shape so the island can use either source
// interchangeably. Open-Meteo reports metric (°C, km/h).
function openMeteoCurrentCondition(dailyForecastReport) {
  var current = dailyForecastReport && dailyForecastReport.current ? dailyForecastReport.current : null
  if (!current || current.temperature_2m === undefined || current.temperature_2m === null) return null
  return {
    temp_C: roundedTemp(current.temperature_2m),
    temp_F: roundedTemp(celsiusToFahrenheit(current.temperature_2m)),
    FeelsLikeC: roundedTemp(current.apparent_temperature),
    FeelsLikeF: roundedTemp(celsiusToFahrenheit(current.apparent_temperature)),
    windspeedKmph: roundedTemp(current.wind_speed_10m),
    windspeedMiles: roundedTemp(kmhToMph(current.wind_speed_10m)),
    humidity: roundedTemp(current.relative_humidity_2m),
    pressure: roundedTemp(current.pressure_msl),
    cloudcover: roundedTemp(current.cloud_cover),
    precipMM: oneDecimal(current.precipitation),
    openMeteoWeatherCode: current.weather_code,
    isDay: current.is_day
  }
}

// Resolved bar/island icon: an SVG name from shell/assets/icons
// (see the ICON SET note at the bottom of this file).
function currentIcon(current, fallback) {
  if (!current) return fallback || ""
  if (current.openMeteoWeatherCode !== undefined && current.openMeteoWeatherCode !== null)
    return iconForWmoCode(current.openMeteoWeatherCode, Number(current.isDay) === 0)
  if (current.weatherCode !== undefined && current.weatherCode !== null)
    return iconForCode(current.weatherCode, false)
  return fallback || ""
}

// wttr.in has no day/night flag. Use its icon only to fill an empty
// initial state, never to replace a day/night-aware icon from Open-Meteo.
function provisionalCurrentIcon(current, resolvedIcon) {
  return resolvedIcon || currentIcon(current, "")
}

function wttrNextForecastDays(report, todayString, count) {
  var want = parseInt(count, 10)
  if (isNaN(want) || want < 1) want = 7
  var days = report && report.weather ? report.weather : []
  var result = []
  for (var i = 0; i < days.length && result.length < want; ++i) {
    // wttr.in only ever ships ~3 days; enrich each with verbose detail
    // from the hourly entry nearest noon so the fallback renders the
    // same rows as the primary source.
    if (isFutureForecastDate(days[i].date, todayString)) result.push(enrichWttrDay(days[i]))
  }
  return result
}

// Attach the verbose detail fields (feels/precip/wind/humidity) to a
// wttr.in day from its noon-hourly entry. Missing pieces stay "" and
// the verbose line omits them.
function enrichWttrDay(day) {
  var h = noonHourly(day) || {}
  day.feelsC = roundedTemp(h.FeelsLikeC)
  day.feelsF = roundedTemp(h.FeelsLikeF)
  day.precipProb = roundedTemp(h.chanceofrain)
  day.windKmph = roundedTemp(h.windspeedKmph)
  day.windMph = roundedTemp(h.windspeedMiles)
  day.humidity = roundedTemp(h.humidity)
  return day
}

// The hourly entry nearest noon: representative conditions for a day.
function noonHourly(day) {
  if (!day || !day.hourly || day.hourly.length === 0) return null
  var best = day.hourly[0]
  var bestDist = 9999
  for (var i = 0; i < day.hourly.length; ++i) {
    var t = parseInt(String(day.hourly[i].time || "0"), 10)
    var dist = Math.abs(t - 1200)
    if (dist < bestDist) {
      bestDist = dist
      best = day.hourly[i]
    }
  }
  return best
}

function buildForecastDays(report, dailyForecastReport, todayString) {
  var days = openMeteoForecastDays(dailyForecastReport, todayString)
  return days.length > 0 ? days : wttrNextForecastDays(report, todayString)
}

function bareTempForDay(day, kind, useImperial) {
  if (!day) return ""
  var v = useImperial
    ? (kind === "max" ? day.maxtempF : day.mintempF)
    : (kind === "max" ? day.maxtempC : day.mintempC)
  if (v === undefined || v === null || v === "") return ""
  return v + "°"
}

// One hourlyForecast entry -> bare "18°" in the requested unit.
function hourTemp(entry, useImperial) {
  if (!entry) return ""
  var v = useImperial ? entry.tempF : entry.tempC
  return v === undefined || v === null || v === "" ? "" : v + "°"
}

// Same WMO mapping as days, honoring the entry's day/night flag so
// evening hours get the moon variants. "" when no code is known.
function hourIcon(entry) {
  if (!entry) return ""
  if (entry.openMeteoWeatherCode === undefined || entry.openMeteoWeatherCode === null) return ""
  return iconForWmoCode(entry.openMeteoWeatherCode, !entry.isDay)
}
function dayIcon(day) {
  if (!day) return ""
  if (day.openMeteoWeatherCode !== undefined && day.openMeteoWeatherCode !== null)
    return iconForWmoCode(day.openMeteoWeatherCode, false)
  var best = noonHourly(day)
  if (!best) return ""
  return iconForCode(best.weatherCode, false)
}

// One-line verbose detail for a forecast day:
// "Feels 21° · Wind 14 km/h · Hum 63% · Rain 20%".
// Sources may omit fields ("" skips them); "" when nothing is known.
function dayDetailsLine(day, useImperial) {
  if (!day) return ""
  var parts = []
  var feels = useImperial ? day.feelsF : day.feelsC
  if (feels !== undefined && feels !== null && feels !== "") parts.push("Feels " + feels + "°")
  var wind = useImperial ? day.windMph : day.windKmph
  if (wind !== undefined && wind !== null && wind !== "") {
    parts.push("Wind " + wind + (useImperial ? " mph" : " km/h"))
  }
  if (day.humidity !== undefined && day.humidity !== null && day.humidity !== "") {
    parts.push("Hum " + day.humidity + "%")
  }
  if (day.precipProb !== undefined && day.precipProb !== null && day.precipProb !== "") {
    parts.push("Rain " + day.precipProb + "%")
  }
  return parts.join(" · ")
}

// WMO weather codes (Open-Meteo) -> Vibranium SVG icon names.
// Day/night variants exist for conditions where the sun/moon reads
// differently (clear, partly cloudy, fog, light showers/snow); steady
// rain/snow/thunderstorm share one glyph. Unknown codes fall back to
// overcast rather than an empty box.
function iconForWmoCode(code, night) {
  var c = parseInt(String(code == null ? "" : code), 10)
  if (isNaN(c)) return "weather-overcast"
  if (c === 0) return night ? "weather-clear-night" : "weather-clear-day"
  if (c === 1 || c === 2) return night ? "weather-partly-cloudy-night" : "weather-partly-cloudy-day"
  if (c === 3) return "weather-overcast"
  if (c === 45 || c === 48) return night ? "weather-fog-night" : "weather-fog-day"
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57) return "weather-drizzle"
  if (c === 61 || c === 63 || c === 65 || c === 66 || c === 67
    || c === 80 || c === 81 || c === 82) return "weather-rain"
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return "weather-snow"
  if (c === 95 || c === 96 || c === 99) return "weather-thunderstorm"
  return "weather-overcast"
}

// wttr.in numeric codes -> the same SVG set (fallback path when
// Open-Meteo is unreachable). Grouping mirrors Omarchy's mapping so both
// sources agree on what the user sees.
function iconForCode(code, night) {
  var c = parseInt(String(code == null ? "" : code), 10)
  if (isNaN(c)) return "weather-overcast"
  switch (c) {
  case 113: return night ? "weather-clear-night" : "weather-clear-day"
  case 116: return night ? "weather-partly-cloudy-night" : "weather-partly-cloudy-day"
  case 119: case 122: return "weather-overcast"
  case 143: case 248: case 260: return night ? "weather-fog-night" : "weather-fog-day"
  case 176: case 263: case 353: return night ? "weather-showers-night" : "weather-showers-day"
  case 179: case 227: case 230: case 323: case 326: case 368:
    return night ? "weather-snow-showers-night" : "weather-snow-showers-day"
  case 182: case 185: case 281: case 284: case 311: case 314:
  case 317: case 320: case 350: case 362: case 365: case 374: case 377: return "weather-sleet"
  case 200: case 386: case 389: case 392: case 395: return "weather-thunderstorm"
  case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359:
    return "weather-drizzle"
  case 329: case 332: case 335: case 338: case 371: return "weather-snow"
  default: return "weather-overcast"
  }
}

// REQUIRED ICON SET (shell/assets/icons/*.svg, monochrome so Icons.qml
// can recolor them to the palette - see the answer notes for sources):
//   weather-clear-day, weather-clear-night,
//   weather-partly-cloudy-day, weather-partly-cloudy-night,
//   weather-overcast,
//   weather-fog-day, weather-fog-night,
//   weather-drizzle,
//   weather-showers-day, weather-showers-night,
//   weather-snow-showers-day, weather-snow-showers-night,
//   weather-sleet, weather-thunderstorm, weather-snow
// (15 files; weather-overcast doubles as the unknown-code fallback.)

if (typeof module !== "undefined") {
  module.exports = {
    coordinatesOf: coordinatesOf,
    parseLocationFile: parseLocationFile,
    wttrLocationQuery: wttrLocationQuery,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    isFutureForecastDate: isFutureForecastDate,
    roundedTemp: roundedTemp,
    celsiusToFahrenheit: celsiusToFahrenheit,
    formatTemp: formatTemp,
    oneDecimal: oneDecimal,
    hpaToInHg: hpaToInHg,
    mmToInches: mmToInches,
    normalizedUnit: normalizedUnit,
    localeUsesImperial: localeUsesImperial,
    countryUsesImperial: countryUsesImperial,
    shouldUseImperial: shouldUseImperial,
    dayName: dayName,
    openMeteoForecastDays: openMeteoForecastDays,
    kmhToMph: kmhToMph,
    humidityMaxForDate: humidityMaxForDate,
    noonHourly: noonHourly,
    enrichWttrDay: enrichWttrDay,
    openMeteoCurrentCondition: openMeteoCurrentCondition,
    currentIcon: currentIcon,
    provisionalCurrentIcon: provisionalCurrentIcon,
    wttrNextForecastDays: wttrNextForecastDays,
    buildForecastDays: buildForecastDays,
    bareTempForDay: bareTempForDay,
    openMeteoHourlyForecast: openMeteoHourlyForecast,
    hourTemp: hourTemp,
    hourIcon: hourIcon,
    dayDetailsLine: dayDetailsLine,
    dayIcon: dayIcon,
    iconForWmoCode: iconForWmoCode,
    iconForCode: iconForCode
  }
}
