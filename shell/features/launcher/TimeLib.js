.pragma library
// Time engine for AppLauncher: "time in <city>" plus typed-time conversion.
// Pure-JS city parsing, timezone resolution and time conversion - no Qt
// imports, no Intl dependency (Quickshell's QJSEngine has no Intl global,
// so everything the shell path touches is plain string matching plus Date
// arithmetic).
//
// NOTE: live clock formatting lives in AppLauncher.qml via `TZ=<zone> date`
// (Process), not here, and the format that probe asks for is the zone's own
// dial rather than the OS's (LauncherLib.timeProbeFormat) - so the readings
// formatTimeIn() returns below, pinned to 24 hours for a stable test, are not
// the shape a row shows. formatTimeIn()/tryTime() are Node/test-only helpers
// that need Intl and are never called from QML. tryConvert() needs no Intl
// and runs on both paths.
//
// Usage (QML + tests):
//   TimeLib.parseTimeQuery(query) -> null | city string ("" when empty)
//   TimeLib.resolveTimezone(city) -> IANA string | null
//   TimeLib.toDisplayName(city) -> title-cased display string
//   TimeLib.zoneContinent(tz) -> "Europe" for "Europe/Madrid"
//   TimeLib.parseConvertQuery(query) -> null | { time, date, tz }
//   TimeLib.tryConvert(query, now?) -> null | { ok:true, label, sub, ... }
// Usage (Node/tests only, need Intl):
//   TimeLib.formatTimeIn(tz, now?) / TimeLib.tryTime(query, now?)
//
// Matching is case-insensitive: "time in Madrid", "TIME IN BANGKOK" and
// "time in chicago" all resolve, as do "7:55pm cst" and "7:55PM CST".
// Unknown cities return ok:false so the caller can render an error entry;
// a query that is neither "time in ..." nor "<time> <tz>" claims nothing.

// Explicit city -> IANA map (keys are normalized: lowercased, underscores
// and dashes folded to spaces, whitespace collapsed). Covers capitals,
// major metros and aliases whose names are NOT their zone names
// (beijing -> Asia/Shanghai, new york -> America/New_York, ...). Any other
// zone city (e.g. "oslo" -> Europe/Oslo) resolves dynamically by scanning
// Intl.supportedValuesOf("timeZone") for a matching tail segment.
var CITY_TO_TZ = {
    // Europe
    "london": "Europe/London",
    "paris": "Europe/Paris",
    "berlin": "Europe/Berlin",
    "madrid": "Europe/Madrid",
    "barcelona": "Europe/Madrid",
    "valencia": "Europe/Madrid",
    "seville": "Europe/Madrid",
    "sevilla": "Europe/Madrid",
    "bilbao": "Europe/Madrid",
    "rome": "Europe/Rome",
    "milan": "Europe/Rome",
    "naples": "Europe/Rome",
    "lisbon": "Europe/Lisbon",
    "porto": "Europe/Lisbon",
    "amsterdam": "Europe/Amsterdam",
    "brussels": "Europe/Brussels",
    "vienna": "Europe/Vienna",
    "prague": "Europe/Prague",
    "warsaw": "Europe/Warsaw",
    "krakow": "Europe/Warsaw",
    "budapest": "Europe/Budapest",
    "athens": "Europe/Athens",
    "istanbul": "Europe/Istanbul",
    "ankara": "Europe/Istanbul",
    "moscow": "Europe/Moscow",
    "saint petersburg": "Europe/Moscow",
    "st petersburg": "Europe/Moscow",
    "kyiv": "Europe/Kyiv",
    "kiev": "Europe/Kyiv",
    "stockholm": "Europe/Stockholm",
    "oslo": "Europe/Oslo",
    "copenhagen": "Europe/Copenhagen",
    "helsinki": "Europe/Helsinki",
    "dublin": "Europe/Dublin",
    "zurich": "Europe/Zurich",
    "geneva": "Europe/Zurich",
    "belgrade": "Europe/Belgrade",
    "bucharest": "Europe/Bucharest",
    "sofia": "Europe/Sofia",
    "zagreb": "Europe/Zagreb",
    "sarajevo": "Europe/Sarajevo",
    "skopje": "Europe/Skopje",
    "bratislava": "Europe/Bratislava",
    "ljubljana": "Europe/Ljubljana",
    "riga": "Europe/Riga",
    "vilnius": "Europe/Vilnius",
    "tallinn": "Europe/Tallinn",
    // Asia
    "bangkok": "Asia/Bangkok",
    "tokyo": "Asia/Tokyo",
    "osaka": "Asia/Tokyo",
    "kyoto": "Asia/Tokyo",
    "singapore": "Asia/Singapore",
    "hong kong": "Asia/Hong_Kong",
    "shanghai": "Asia/Shanghai",
    "beijing": "Asia/Shanghai",
    "seoul": "Asia/Seoul",
    "busan": "Asia/Seoul",
    "dubai": "Asia/Dubai",
    "abu dhabi": "Asia/Dubai",
    "doha": "Asia/Qatar",
    "mumbai": "Asia/Kolkata",
    "delhi": "Asia/Kolkata",
    "new delhi": "Asia/Kolkata",
    "kolkata": "Asia/Kolkata",
    "calcutta": "Asia/Kolkata",
    "chennai": "Asia/Kolkata",
    "bangalore": "Asia/Kolkata",
    "bengaluru": "Asia/Kolkata",
    "hyderabad": "Asia/Kolkata",
    "karachi": "Asia/Karachi",
    "lahore": "Asia/Karachi",
    "dhaka": "Asia/Dhaka",
    "jakarta": "Asia/Jakarta",
    "manila": "Asia/Manila",
    "taipei": "Asia/Taipei",
    "kuala lumpur": "Asia/Kuala_Lumpur",
    "hanoi": "Asia/Ho_Chi_Minh",
    "ho chi minh": "Asia/Ho_Chi_Minh",
    "ho chi minh city": "Asia/Ho_Chi_Minh",
    "saigon": "Asia/Ho_Chi_Minh",
    "phnom penh": "Asia/Phnom_Penh",
    "vientiane": "Asia/Vientiane",
    "yangon": "Asia/Yangon",
    "rangoon": "Asia/Yangon",
    "colombo": "Asia/Colombo",
    "kathmandu": "Asia/Kathmandu",
    "riyadh": "Asia/Riyadh",
    "jeddah": "Asia/Riyadh",
    "tel aviv": "Asia/Jerusalem",
    "jerusalem": "Asia/Jerusalem",
    "baghdad": "Asia/Baghdad",
    "tehran": "Asia/Tehran",
    "baku": "Asia/Baku",
    "tbilisi": "Asia/Tbilisi",
    "yerevan": "Asia/Yerevan",
    "almaty": "Asia/Almaty",
    "tashkent": "Asia/Tashkent",
    "ulaanbaatar": "Asia/Ulaanbaatar",
    "kabul": "Asia/Kabul",
    "islamabad": "Asia/Karachi",
    // Americas
    "chicago": "America/Chicago",
    "dallas": "America/Chicago",
    "houston": "America/Chicago",
    "minneapolis": "America/Chicago",
    "new orleans": "America/Chicago",
    "mexico city": "America/Mexico_City",
    "new york": "America/New_York",
    "nyc": "America/New_York",
    "boston": "America/New_York",
    "miami": "America/New_York",
    "atlanta": "America/New_York",
    "washington": "America/New_York",
    "philadelphia": "America/New_York",
    "detroit": "America/Detroit",
    "los angeles": "America/Los_Angeles",
    "san francisco": "America/Los_Angeles",
    "san diego": "America/Los_Angeles",
    "seattle": "America/Los_Angeles",
    "portland": "America/Los_Angeles",
    "las vegas": "America/Los_Angeles",
    "vancouver": "America/Vancouver",
    "denver": "America/Denver",
    "salt lake city": "America/Denver",
    "phoenix": "America/Phoenix",
    "anchorage": "America/Anchorage",
    "honolulu": "Pacific/Honolulu",
    "toronto": "America/Toronto",
    "montreal": "America/Toronto",
    "ottawa": "America/Toronto",
    "calgary": "America/Edmonton",
    "edmonton": "America/Edmonton",
    "winnipeg": "America/Winnipeg",
    "halifax": "America/Halifax",
    "st johns": "America/St_Johns",
    "havana": "America/Havana",
    "kingston": "America/Jamaica",
    "san juan": "America/Puerto_Rico",
    "santo domingo": "America/Santo_Domingo",
    "panama": "America/Panama",
    "san jose": "America/Costa_Rica",
    "guatemala": "America/Guatemala",
    "bogota": "America/Bogota",
    "lima": "America/Lima",
    "quito": "America/Guayaquil",
    "guayaquil": "America/Guayaquil",
    "caracas": "America/Caracas",
    "la paz": "America/La_Paz",
    "santiago": "America/Santiago",
    "buenos aires": "America/Argentina/Buenos_Aires",
    "montevideo": "America/Montevideo",
    "asuncion": "America/Asuncion",
    "sao paulo": "America/Sao_Paulo",
    "rio de janeiro": "America/Sao_Paulo",
    "rio": "America/Sao_Paulo",
    "brasilia": "America/Sao_Paulo",
    "salvador": "America/Bahia",
    // Africa
    "cairo": "Africa/Cairo",
    "lagos": "Africa/Lagos",
    "nairobi": "Africa/Nairobi",
    "johannesburg": "Africa/Johannesburg",
    "cape town": "Africa/Johannesburg",
    "durban": "Africa/Johannesburg",
    "casablanca": "Africa/Casablanca",
    "rabat": "Africa/Casablanca",
    "algiers": "Africa/Algiers",
    "tunis": "Africa/Tunis",
    "tripoli": "Africa/Tripoli",
    "accra": "Africa/Accra",
    "dakar": "Africa/Dakar",
    "addis ababa": "Africa/Addis_Ababa",
    "khartoum": "Africa/Khartoum",
    "kinshasa": "Africa/Kinshasa",
    "luanda": "Africa/Luanda",
    "abidjan": "Africa/Abidjan",
    // Oceania
    "sydney": "Australia/Sydney",
    "melbourne": "Australia/Melbourne",
    "brisbane": "Australia/Brisbane",
    "perth": "Australia/Perth",
    "adelaide": "Australia/Adelaide",
    "darwin": "Australia/Darwin",
    "auckland": "Pacific/Auckland",
    "wellington": "Pacific/Auckland",
    "suva": "Pacific/Fiji",
    "fiji": "Pacific/Fiji",
    "guam": "Pacific/Guam",
    "papeete": "Pacific/Tahiti",
    // Atlantic
    "reykjavik": "Atlantic/Reykjavik"
};

// Fallback zone pool for engines without Intl.supportedValuesOf.
// Quickshell's QJSEngine has no Intl global, so under the shell this
// static list (system tzdata snapshot) is what dynamic tail matching
// scans. Node/tests prefer Intl.supportedValuesOf when present.
var FALLBACK_ZONES = [
    "Africa/Abidjan", "Africa/Accra", "Africa/Addis_Ababa", "Africa/Algiers",
    "Africa/Asmara", "Africa/Asmera", "Africa/Bamako", "Africa/Bangui",
    "Africa/Banjul", "Africa/Bissau", "Africa/Blantyre", "Africa/Brazzaville",
    "Africa/Bujumbura", "Africa/Cairo", "Africa/Casablanca", "Africa/Ceuta",
    "Africa/Conakry", "Africa/Dakar", "Africa/Dar_es_Salaam", "Africa/Djibouti",
    "Africa/Douala", "Africa/El_Aaiun", "Africa/Freetown", "Africa/Gaborone",
    "Africa/Harare", "Africa/Johannesburg", "Africa/Juba", "Africa/Kampala",
    "Africa/Khartoum", "Africa/Kigali", "Africa/Kinshasa", "Africa/Lagos",
    "Africa/Libreville", "Africa/Lome", "Africa/Luanda", "Africa/Lubumbashi",
    "Africa/Lusaka", "Africa/Malabo", "Africa/Maputo", "Africa/Maseru",
    "Africa/Mbabane", "Africa/Mogadishu", "Africa/Monrovia", "Africa/Nairobi",
    "Africa/Ndjamena", "Africa/Niamey", "Africa/Nouakchott", "Africa/Ouagadougou",
    "Africa/Porto-Novo", "Africa/Sao_Tome", "Africa/Timbuktu", "Africa/Tripoli",
    "Africa/Tunis", "Africa/Windhoek", "America/Adak", "America/Anchorage",
    "America/Anguilla", "America/Antigua", "America/Araguaina", "America/Argentina/Buenos_Aires",
    "America/Argentina/Catamarca", "America/Argentina/ComodRivadavia", "America/Argentina/Cordoba", "America/Argentina/Jujuy",
    "America/Argentina/La_Rioja", "America/Argentina/Mendoza", "America/Argentina/Rio_Gallegos", "America/Argentina/Salta",
    "America/Argentina/San_Juan", "America/Argentina/San_Luis", "America/Argentina/Tucuman", "America/Argentina/Ushuaia",
    "America/Aruba", "America/Asuncion", "America/Atikokan", "America/Atka",
    "America/Bahia", "America/Bahia_Banderas", "America/Barbados", "America/Belem",
    "America/Belize", "America/Blanc-Sablon", "America/Boa_Vista", "America/Bogota",
    "America/Boise", "America/Buenos_Aires", "America/Cambridge_Bay", "America/Campo_Grande",
    "America/Cancun", "America/Caracas", "America/Catamarca", "America/Cayenne",
    "America/Cayman", "America/Chicago", "America/Chihuahua", "America/Ciudad_Juarez",
    "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica", "America/Coyhaique",
    "America/Creston", "America/Cuiaba", "America/Curacao", "America/Danmarkshavn",
    "America/Dawson", "America/Dawson_Creek", "America/Denver", "America/Detroit",
    "America/Dominica", "America/Edmonton", "America/Eirunepe", "America/El_Salvador",
    "America/Ensenada", "America/Fort_Nelson", "America/Fort_Wayne", "America/Fortaleza",
    "America/Glace_Bay", "America/Godthab", "America/Goose_Bay", "America/Grand_Turk",
    "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil",
    "America/Guyana", "America/Halifax", "America/Havana", "America/Hermosillo",
    "America/Indiana/Indianapolis", "America/Indiana/Knox", "America/Indiana/Marengo", "America/Indiana/Petersburg",
    "America/Indiana/Tell_City", "America/Indiana/Vevay", "America/Indiana/Vincennes", "America/Indiana/Winamac",
    "America/Indianapolis", "America/Inuvik", "America/Iqaluit", "America/Jamaica",
    "America/Jujuy", "America/Juneau", "America/Kentucky/Louisville", "America/Kentucky/Monticello",
    "America/Knox_IN", "America/Kralendijk", "America/La_Paz", "America/Lima",
    "America/Los_Angeles", "America/Louisville", "America/Lower_Princes", "America/Maceio",
    "America/Managua", "America/Manaus", "America/Marigot", "America/Martinique",
    "America/Matamoros", "America/Mazatlan", "America/Mendoza", "America/Menominee",
    "America/Merida", "America/Metlakatla", "America/Mexico_City", "America/Miquelon",
    "America/Moncton", "America/Monterrey", "America/Montevideo", "America/Montreal",
    "America/Montserrat", "America/Nassau", "America/New_York", "America/Nipigon",
    "America/Nome", "America/Noronha", "America/North_Dakota/Beulah", "America/North_Dakota/Center",
    "America/North_Dakota/New_Salem", "America/Nuuk", "America/Ojinaga", "America/Panama",
    "America/Pangnirtung", "America/Paramaribo", "America/Phoenix", "America/Port-au-Prince",
    "America/Port_of_Spain", "America/Porto_Acre", "America/Porto_Velho", "America/Puerto_Rico",
    "America/Punta_Arenas", "America/Rainy_River", "America/Rankin_Inlet", "America/Recife",
    "America/Regina", "America/Resolute", "America/Rio_Branco", "America/Rosario",
    "America/Santa_Isabel", "America/Santarem", "America/Santiago", "America/Santo_Domingo",
    "America/Sao_Paulo", "America/Scoresbysund", "America/Shiprock", "America/Sitka",
    "America/St_Barthelemy", "America/St_Johns", "America/St_Kitts", "America/St_Lucia",
    "America/St_Thomas", "America/St_Vincent", "America/Swift_Current", "America/Tegucigalpa",
    "America/Thule", "America/Thunder_Bay", "America/Tijuana", "America/Toronto",
    "America/Tortola", "America/Vancouver", "America/Virgin", "America/Whitehorse",
    "America/Winnipeg", "America/Yakutat", "America/Yellowknife", "Antarctica/Casey",
    "Antarctica/Davis", "Antarctica/DumontDUrville", "Antarctica/Macquarie", "Antarctica/Mawson",
    "Antarctica/McMurdo", "Antarctica/Palmer", "Antarctica/Rothera", "Antarctica/South_Pole",
    "Antarctica/Syowa", "Antarctica/Troll", "Antarctica/Vostok", "Arctic/Longyearbyen",
    "Asia/Aden", "Asia/Almaty", "Asia/Amman", "Asia/Anadyr",
    "Asia/Aqtau", "Asia/Aqtobe", "Asia/Ashgabat", "Asia/Ashkhabad",
    "Asia/Atyrau", "Asia/Baghdad", "Asia/Bahrain", "Asia/Baku",
    "Asia/Bangkok", "Asia/Barnaul", "Asia/Beirut", "Asia/Bishkek",
    "Asia/Brunei", "Asia/Calcutta", "Asia/Chita", "Asia/Choibalsan",
    "Asia/Chongqing", "Asia/Chungking", "Asia/Colombo", "Asia/Dacca",
    "Asia/Damascus", "Asia/Dhaka", "Asia/Dili", "Asia/Dubai",
    "Asia/Dushanbe", "Asia/Famagusta", "Asia/Gaza", "Asia/Harbin",
    "Asia/Hebron", "Asia/Ho_Chi_Minh", "Asia/Hong_Kong", "Asia/Hovd",
    "Asia/Irkutsk", "Asia/Istanbul", "Asia/Jakarta", "Asia/Jayapura",
    "Asia/Jerusalem", "Asia/Kabul", "Asia/Kamchatka", "Asia/Karachi",
    "Asia/Kashgar", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Khandyga",
    "Asia/Kolkata", "Asia/Krasnoyarsk", "Asia/Kuala_Lumpur", "Asia/Kuching",
    "Asia/Kuwait", "Asia/Macao", "Asia/Macau", "Asia/Magadan",
    "Asia/Makassar", "Asia/Manila", "Asia/Muscat", "Asia/Nicosia",
    "Asia/Novokuznetsk", "Asia/Novosibirsk", "Asia/Omsk", "Asia/Oral",
    "Asia/Phnom_Penh", "Asia/Pontianak", "Asia/Pyongyang", "Asia/Qatar",
    "Asia/Qostanay", "Asia/Qyzylorda", "Asia/Rangoon", "Asia/Riyadh",
    "Asia/Saigon", "Asia/Sakhalin", "Asia/Samarkand", "Asia/Seoul",
    "Asia/Shanghai", "Asia/Singapore", "Asia/Srednekolymsk", "Asia/Taipei",
    "Asia/Tashkent", "Asia/Tbilisi", "Asia/Tehran", "Asia/Tel_Aviv",
    "Asia/Thimbu", "Asia/Thimphu", "Asia/Tokyo", "Asia/Tomsk",
    "Asia/Ujung_Pandang", "Asia/Ulaanbaatar", "Asia/Ulan_Bator", "Asia/Urumqi",
    "Asia/Ust-Nera", "Asia/Vientiane", "Asia/Vladivostok", "Asia/Yakutsk",
    "Asia/Yangon", "Asia/Yekaterinburg", "Asia/Yerevan", "Atlantic/Azores",
    "Atlantic/Bermuda", "Atlantic/Canary", "Atlantic/Cape_Verde", "Atlantic/Faeroe",
    "Atlantic/Faroe", "Atlantic/Jan_Mayen", "Atlantic/Madeira", "Atlantic/Reykjavik",
    "Atlantic/South_Georgia", "Atlantic/St_Helena", "Atlantic/Stanley", "Australia/ACT",
    "Australia/Adelaide", "Australia/Brisbane", "Australia/Broken_Hill", "Australia/Canberra",
    "Australia/Currie", "Australia/Darwin", "Australia/Eucla", "Australia/Hobart",
    "Australia/LHI", "Australia/Lindeman", "Australia/Lord_Howe", "Australia/Melbourne",
    "Australia/NSW", "Australia/North", "Australia/Perth", "Australia/Queensland",
    "Australia/South", "Australia/Sydney", "Australia/Tasmania", "Australia/Victoria",
    "Australia/West", "Australia/Yancowinna", "Brazil/Acre", "Brazil/DeNoronha",
    "Brazil/East", "Brazil/West", "Europe/Amsterdam", "Europe/Andorra",
    "Europe/Astrakhan", "Europe/Athens", "Europe/Belfast", "Europe/Belgrade",
    "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Bucharest",
    "Europe/Budapest", "Europe/Busingen", "Europe/Chisinau", "Europe/Copenhagen",
    "Europe/Dublin", "Europe/Gibraltar", "Europe/Guernsey", "Europe/Helsinki",
    "Europe/Isle_of_Man", "Europe/Istanbul", "Europe/Jersey", "Europe/Kaliningrad",
    "Europe/Kiev", "Europe/Kirov", "Europe/Kyiv", "Europe/Lisbon",
    "Europe/Ljubljana", "Europe/London", "Europe/Luxembourg", "Europe/Madrid",
    "Europe/Malta", "Europe/Mariehamn", "Europe/Minsk", "Europe/Monaco",
    "Europe/Moscow", "Europe/Nicosia", "Europe/Oslo", "Europe/Paris",
    "Europe/Podgorica", "Europe/Prague", "Europe/Riga", "Europe/Rome",
    "Europe/Samara", "Europe/San_Marino", "Europe/Sarajevo", "Europe/Saratov",
    "Europe/Simferopol", "Europe/Skopje", "Europe/Sofia", "Europe/Stockholm",
    "Europe/Tallinn", "Europe/Tirane", "Europe/Tiraspol", "Europe/Ulyanovsk",
    "Europe/Uzhgorod", "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna",
    "Europe/Vilnius", "Europe/Volgograd", "Europe/Warsaw", "Europe/Zagreb",
    "Europe/Zaporozhye", "Europe/Zurich", "Indian/Antananarivo", "Indian/Chagos",
    "Indian/Christmas", "Indian/Cocos", "Indian/Comoro", "Indian/Kerguelen",
    "Indian/Mahe", "Indian/Maldives", "Indian/Mauritius", "Indian/Mayotte",
    "Indian/Reunion", "Pacific/Apia", "Pacific/Auckland", "Pacific/Bougainville",
    "Pacific/Chatham", "Pacific/Chuuk", "Pacific/Easter", "Pacific/Efate",
    "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji", "Pacific/Funafuti",
    "Pacific/Galapagos", "Pacific/Gambier", "Pacific/Guadalcanal", "Pacific/Guam",
    "Pacific/Honolulu", "Pacific/Johnston", "Pacific/Kanton", "Pacific/Kiritimati",
    "Pacific/Kosrae", "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas",
    "Pacific/Midway", "Pacific/Nauru", "Pacific/Niue", "Pacific/Norfolk",
    "Pacific/Noumea", "Pacific/Pago_Pago", "Pacific/Palau", "Pacific/Pitcairn",
    "Pacific/Pohnpei", "Pacific/Ponape", "Pacific/Port_Moresby", "Pacific/Rarotonga",
    "Pacific/Saipan", "Pacific/Samoa", "Pacific/Tahiti", "Pacific/Tarawa",
    "Pacific/Tongatapu", "Pacific/Truk", "Pacific/Wake", "Pacific/Wallis",
    "Pacific/Yap"
];

function _str(v) {
    if (v === undefined || v === null) return ""
    return String(v)
}

// Normalized lookup key: trim, fold separators, strip diacritics,
// collapse whitespace, lowercase.
function normalizeCity(s) {
    var t = _str(s).trim()
    if (t === "") return ""
    t = t.replace(/[_-]+/g, " ")
    try {
        if (typeof t.normalize === "function")
            t = t.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    } catch (e) {}
    t = t.replace(/\s+/g, " ").trim().toLowerCase()
    return t
}

// "time in <city>" detector, case-insensitive. Returns null when the query
// is not a time query, otherwise the raw city part trimmed ("" when the
// user typed only "time in" with nothing after it).
function parseTimeQuery(query) {
    var t = _str(query).trim()
    if (t === "") return null
    if (/^time\s+in\s*$/i.test(t)) return ""
    var m = t.match(/^time\s+in\s+(.+?)\s*$/i)
    if (!m) return null
    return _str(m[1]).trim()
}

function getAllTimeZones() {
    try {
        if (typeof Intl !== "undefined" && Intl.supportedValuesOf) {
            var z = Intl.supportedValuesOf("timeZone")
            if (z && z.length > 0) return z
        }
    } catch (e) {}
    return FALLBACK_ZONES
}

// Case-insensitive city -> IANA timezone, or null.
function resolveTimezone(city) {
    var norm = normalizeCity(city)
    if (norm === "") return null
    if (Object.prototype.hasOwnProperty.call(CITY_TO_TZ, norm))
        return CITY_TO_TZ[norm]
    var zones = getAllTimeZones()
    for (var i = 0; i < zones.length; i++) {
        var z = zones[i]
        var slash = z.lastIndexOf("/")
        var tail = slash >= 0 ? z.substring(slash + 1) : z
        if (normalizeCity(tail) === norm) return z
    }
    return null
}

// Display name: title-case each word ("BANGKOK" -> "Bangkok",
// "new york" -> "New York", "chicago" -> "Chicago").
function toDisplayName(cityRaw) {
    var t = _str(cityRaw).trim().replace(/\s+/g, " ")
    if (t === "") return ""
    var parts = t.split(" ")
    for (var i = 0; i < parts.length; i++) {
        var w = parts[i]
        if (w === "") continue
        var subs = w.split("-")
        for (var j = 0; j < subs.length; j++) {
            if (subs[j].length > 0)
                subs[j] = subs[j].charAt(0).toUpperCase() + subs[j].substring(1).toLowerCase()
        }
        parts[i] = subs.join("-")
    }
    return parts.join(" ")
}

// Continent (first IANA segment): "Europe" for "Europe/Madrid",
// "America" for "America/Argentina/Buenos_Aires". Pure string split.
function zoneContinent(tz) {
    var t = _str(tz)
    if (t === "") return ""
    var slash = t.indexOf("/")
    return slash < 0 ? t : t.substring(0, slash)
}

// { time: "14:32", date: "Fri, 11 Sep" } in tz, or null on failure.
// Node/test-only: needs Intl, which Quickshell's QJSEngine lacks.
function formatTimeIn(tz, now) {
    try {
        var d = (now instanceof Date) ? now : ((now === undefined || now === null) ? new Date() : new Date(now))
        if (isNaN(d.getTime())) return null
        var timeFmt = new Intl.DateTimeFormat("en-GB", {
            timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false
        })
        var dateFmt = new Intl.DateTimeFormat("en-GB", {
            timeZone: tz, weekday: "short", day: "numeric", month: "short"
        })
        return { time: timeFmt.format(d), date: dateFmt.format(d) }
    } catch (e) {
        return null
    }
}

// High-level entry: null when not a time query, otherwise
// { ok:true, city, display, timezone, time, date } or
// { ok:false, city, display, timezone, error: "empty"|"unknown"|"format" }.
// Node/test-only: needs Intl via formatTimeIn(); QML resolves the zone with
// resolveTimezone() and formats via the TZ=date process instead.
function tryTime(query, now) {
    var city = parseTimeQuery(query)
    if (city === null) return null
    if (city === "")
        return { ok: false, city: "", display: "", timezone: "", error: "empty" }
    var tz = resolveTimezone(city)
    if (!tz)
        return { ok: false, city: city, display: toDisplayName(city), timezone: "", error: "unknown" }
    var base = (now === undefined || now === null) ? new Date() : (now instanceof Date ? now : new Date(now))
    var fmt = formatTimeIn(tz, base)
    if (!fmt)
        return { ok: false, city: city, display: toDisplayName(city), timezone: tz, error: "format" }
    return { ok: true, city: city, display: toDisplayName(city), timezone: tz, time: fmt.time, date: fmt.date }
}

