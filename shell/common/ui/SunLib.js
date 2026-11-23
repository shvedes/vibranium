// Pure solar-time math for the clock island's day pane.
//
// The NOAA simplified solar-position equations: a fractional year angle
// gives the equation of time and solar declination, and the zenith hour
// angle turns those into event times. No Qt, no network, no process - the
// caller supplies the date and a coordinate pair, and everything else is
// arithmetic. Times are approximations, accurate to a few minutes away
// from the poles.
//
// Longitude is east-positive; the provider pair from the weather service
// already uses that convention. The returned Dates are real instants, so
// formatting stays with the shared ClockFmt primitive and follows the
// shell's 12/24-hour setting.

.pragma library

.import "CalendarLib.js" as CalendarLib

var RAD = Math.PI / 180
// Sunrise uses the standard refraction correction; civil twilight ends at
// six degrees below the horizon.
var ZENITH_SUNRISE = 90.833
var ZENITH_CIVIL = 96
var MINUTES_PER_DAY = 1440

function validPair(latitude, longitude) {
  const lat = Number(latitude)
  const lon = Number(longitude)
  if (!isFinite(lat) || !isFinite(lon)) return null
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null
  return { latitude: lat, longitude: lon }
}

function solarTerms(date) {
  const doy = CalendarLib.dayOfYear(date.getFullYear(), date.getMonth(), date.getDate())
  const g = 2 * Math.PI / 365 * (doy - 1)
  const eqtime = 229.18 * (0.000075 + 0.001868 * Math.cos(g)
    - 0.032077 * Math.sin(g) - 0.014615 * Math.cos(2 * g)
    - 0.040849 * Math.sin(2 * g))
  const decl = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g)
    - 0.006758 * Math.cos(2 * g) + 0.000907 * Math.sin(2 * g)
    - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g)
  return { eqtime: eqtime, decl: decl }
}

function hourAngle(zenith, latitude, decl) {
  const lat = latitude * RAD
  const cosH = Math.cos(zenith * RAD) / (Math.cos(lat) * Math.cos(decl))
    - Math.tan(lat) * Math.tan(decl)
  if (cosH > 1) return { polar: "night" }
  if (cosH < -1) return { polar: "day" }
  return { angle: Math.acos(cosH) / RAD }
}

function atMinutes(baseMs, minutes) {
  if (!isFinite(minutes)) return null
  return new Date(baseMs + Math.round(minutes) * 60000)
}

// Sunrise, sunset, solar noon, civil dawn/dusk and day length for one
// calendar day. Returns null for an invalid date or coordinate pair.
// A polar day or night has no crossing times; the length is 24h or 0.
function forDate(date, latitude, longitude) {
  if (!date || !isFinite(date.getTime())) return null
  const pair = validPair(latitude, longitude)
  if (pair === null) return null

  const terms = solarTerms(date)
  const noon = 720 - 4 * pair.longitude - terms.eqtime
  const sun = hourAngle(ZENITH_SUNRISE, pair.latitude, terms.decl)
  const civil = hourAngle(ZENITH_CIVIL, pair.latitude, terms.decl)
  const base = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())

  const polar = sun.polar || null
  const hasSun = polar === null
  const angle = hasSun ? sun.angle : 0
  return {
    date: date,
    latitude: pair.latitude,
    longitude: pair.longitude,
    solarNoon: atMinutes(base, noon),
    sunrise: hasSun ? atMinutes(base, noon - 4 * angle) : null,
    sunset: hasSun ? atMinutes(base, noon + 4 * angle) : null,
    dawn: civil.polar === undefined ? atMinutes(base, noon - 4 * civil.angle) : null,
    dusk: civil.polar === undefined ? atMinutes(base, noon + 4 * civil.angle) : null,
    dayLengthMinutes: hasSun ? Math.round(8 * angle) : (polar === "day" ? MINUTES_PER_DAY : 0),
    polar: polar
  }
}

// "13h 22m" style span, shared by the pane and its tests.
function span(minutes) {
  const n = Math.max(0, Math.round(Number(minutes)))
  const h = Math.floor(n / 60)
  const m = n % 60
  return h + "h " + (m < 10 ? "0" : "") + m + "m"
}

if (typeof module !== "undefined") {
  module.exports = {
    validPair: validPair,
    solarTerms: solarTerms,
    hourAngle: hourAngle,
    atMinutes: atMinutes,
    forDate: forDate,
    span: span
  }
}
