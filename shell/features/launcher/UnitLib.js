.pragma library
// Unit converter engine for AppLauncher: natural-language
// "<value><unit> [in|into|to|as|->|= <unit>]" plus bare "<value><unit>"
// with a per-unit default target. Pure-JS, no Qt imports.
//
// Four stages, always in this order:
//
//   preprocess  Text only. An unpadded arrow becomes " -> ", a leading
//               filler word is dropped ("convert", "calc", "what is",
//               "how many"), the two inverted question forms are rewritten
//               into the canonical shape, and a trailing "please", "?" or
//               "!" is dropped. A trailing quote is never dropped: the
//               double and single quotes are the inch and the foot.
//   source      parseSource scans number/unit pairs left to right, so
//               "6 ft 2 in" is one quantity and "5m" is the same shape as
//               "5 m". Each further term is converted into the first term's
//               unit and added.
//   target      The text after the keyword. A bare query has none, so it
//               answers with a LIST of targets: pickDefault(value, from)
//               first, then the dimension's shortlist as far as each reading
//               is still readable (see pickTargets and readable).
//   check       Dimensions, the absolute-zero floor, the result range.
//
// A unit spelling is normalized before the alias table is consulted, and a
// number may carry thousands grouping ("1,000 km") in the same form the
// currency engine accepts. A decimal comma is not accepted: "1,5" is the
// grouping prefix of a number that never ends, so reading it as 1.5 would be
// a guess, and a silent guess is the one thing this engine must not do.
//
// Usage: UnitLib.isPotentialUnit(query) -> bool (cheap gate)
//        UnitLib.tryConvert(query) -> null | result
//        UnitLib.tryAll(query) -> null | result[]
//   ok:   { ok: true, value, from, to, out, formatted, copy, phrase,
//           label, inputText }
//   hint: { ok: false, error: "incomplete"|"unknown-target"|
//           "incompatible"|"unphysical"|"out-of-range", expr, label, sub }
// null means "not a unit query" - caller falls through to apps.
//
// The two entries share one parse and one set of checks: tryConvert answers
// with a single conversion, which is what an explicit "in <unit>" asks for and
// what the head of a bare list is, and tryAll is the list. A bare query that
// cannot be converted at all (-300 C) is a statement about the QUERY, so it
// keeps one row rather than one per target.
//
// An answer carries the pair three ways: `copy` is what lands on the clipboard,
// `label` is the compact form the row is titled with, and `phrase` is the same
// conversion as a sentence - "3600 joules is 0.001 kilowatt-hours" - which is
// what the row's sub line says.

var UNITS = [
  { sym: "A", dim: "length", factor: 1e-10, def: "nm",
    names: ["a", "angstrom", "angstroms", "angstre"] },
  { sym: "nm", dim: "length", factor: 1e-9, def: "in",
    names: ["nm", "nanometer", "nanometers", "nanometre", "nanometres"] },
  { sym: "um", dim: "length", factor: 1e-6, def: "in",
    names: ["um", "micron", "microns", "micrometer", "micrometers", "micrometre", "micrometres"] },
  // A thousandth of an inch: wire gauge and paper thickness. "mil" is the
  // NATO angle unit elsewhere, but that reading is a fraction of a radian
  // and useless on its own, so the name belongs to the length.
  { sym: "thou", dim: "length", factor: 2.54e-5, def: "mm",
    names: ["thou", "thous", "mil", "mils"] },
  { sym: "mm", dim: "length", factor: 0.001, def: "in",
    names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"] },
  { sym: "cm", dim: "length", factor: 0.01, def: "in",
    names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"] },
  { sym: "dm", dim: "length", factor: 0.1, def: "cm",
    names: ["dm", "decimeter", "decimeters", "decimetre", "decimetres"] },
  { sym: "m", dim: "length", factor: 1, def: "ft",
    names: ["m", "meter", "meters", "metre", "metres"] },
  { sym: "dam", dim: "length", factor: 10, def: "m",
    names: ["dam", "decameter", "decameters", "decametre", "decametres"] },
  { sym: "hm", dim: "length", factor: 100, def: "m",
    names: ["hm", "hectometer", "hectometers", "hectometre", "hectometres"] },
  // The ladder stops at megametres. Every sym has to claim its own
  // lowercased name, and Gm would have to claim "gm", which is the gram in
  // every medicine context and in every typed abbreviation on a pharmacy
  // label.
  { sym: "km", dim: "length", factor: 1000, def: "mi",
    names: ["km", "kms", "kilometer", "kilometers", "kilometre", "kilometres"] },
  { sym: "in", dim: "length", factor: 0.0254, def: "cm",
    names: ["in", "inch", "inches", "\""] },
  { sym: "hand", dim: "length", factor: 0.1016, def: "in",
    names: ["hand", "hands", "handspan", "handspans"] },
  { sym: "ft", dim: "length", factor: 0.3048, def: "m",
    names: ["ft", "foot", "feet", "'"] },
  { sym: "yd", dim: "length", factor: 0.9144, def: "m",
    names: ["yd", "yard", "yards"] },
  { sym: "fathom", dim: "length", factor: 1.8288, def: "ft",
    names: ["fathom", "fathoms"] },
  { sym: "mi", dim: "length", factor: 1609.344, def: "km",
    names: ["mi", "mile", "miles"] },
  { sym: "nmi", dim: "length", factor: 1852, def: "km",
    names: ["nmi", "nauticalmile", "nauticalmiles"] },
  // The speed of light is not here: "c" is the Celsius alias and the alias
  // table is case-folded, so a light-speed row would shadow every degree.
  { sym: "au", dim: "length", factor: 1.495978707e11, def: "km",
    names: ["au", "astronomicalunit", "astronomicalunits"] },
  // The light ladder, from the second up to the year. A light year is not a
  // separate idea from the ones below it - it is the same light over a longer
  // time - and they are what makes the ladder readable at the scales where a
  // kilometre stops meaning anything: the Moon is 1.28 light-seconds away and
  // the nearest star 4.24 light-years.
  //
  // Every factor is a whole multiple of the metre's own definition, 299792458
  // metres, so `1 ls` is exactly 299792458 m and `1 ly` comes out at the
  // defined light year rather than at a rounded copy of it.
  //
  // A light MONTH is deliberately absent. The time table has a month now, but
  // as a convention (one twelfth of the 365-day year, 730 hours) and not as a
  // calendar month, and a light month on top of a convention is a convention
  // squared.
  { sym: "ls", dim: "length", factor: 299792458, def: "km",
    names: ["ls", "lightsecond", "lightseconds"] },
  { sym: "lmin", dim: "length", factor: 17987547480, def: "km",
    names: ["lmin", "lightminute", "lightminutes"] },
  { sym: "lh", dim: "length", factor: 1079252848800, def: "km",
    names: ["lh", "lighthour", "lighthours"] },
  { sym: "ld", dim: "length", factor: 25902068371200, def: "km",
    names: ["ld", "lightday", "lightdays"] },
  { sym: "lw", dim: "length", factor: 181314478598400, def: "km",
    names: ["lw", "lightweek", "lightweeks"] },
  { sym: "ly", dim: "length", factor: 9.4607304725808e15, def: "km",
    names: ["ly", "lightyear", "lightyears"] },
  { sym: "pc", dim: "length", factor: 3.085677581491367e16, def: "ly",
    names: ["pc", "parsec", "parsecs"] },
  { sym: "ng", dim: "mass", factor: 1e-12, def: "ug",
    names: ["ng", "nanogram", "nanograms"] },
  { sym: "ug", dim: "mass", factor: 1e-9, def: "mg",
    names: ["ug", "microgram", "micrograms"] },
  { sym: "mg", dim: "mass", factor: 1e-6, def: "oz",
    names: ["mg", "milligram", "milligrams"] },
  { sym: "grain", dim: "mass", factor: 6.479891e-8, def: "mg",
    names: ["gr", "grain", "grains"] },
  { sym: "carat", dim: "mass", factor: 0.0002, def: "mg",
    names: ["ct", "carat", "carats"] },
  { sym: "g", dim: "mass", factor: 0.001, def: "oz",
    names: ["g", "gram", "grams", "gramme", "grammes"] },
  { sym: "dg", dim: "mass", factor: 1e-4, def: "g",
    names: ["dg", "decigram", "decigrams"] },
  { sym: "dag", dim: "mass", factor: 0.01, def: "kg",
    names: ["dag", "decagram", "decagrams"] },
  { sym: "hg", dim: "mass", factor: 0.1, def: "kg",
    names: ["hg", "hectogram", "hectograms"] },
  { sym: "kg", dim: "mass", factor: 1, def: "lb",
    names: ["kg", "kilogram", "kilograms", "kilo", "kilos"] },
  // The mass table has no hundredweight and no quarter: a hundredweight is
  // 100 pounds in the US and 112 in the UK, and a quarter is a quarter of
  // what. Each one needs a question asked first, and a unit row cannot ask
  // one.
  { sym: "t", dim: "mass", factor: 1000, def: "ton",
    names: ["t", "tonne", "tonnes", "metricton", "metrictons"] },
  { sym: "oz", dim: "mass", factor: 0.028349523125, def: "g",
    names: ["oz", "ounce", "ounces"] },
  { sym: "lb", dim: "mass", factor: 0.45359237, def: "kg",
    names: ["lb", "lbs", "pound", "pounds"] },
  { sym: "st", dim: "mass", factor: 6.35029318, def: "kg",
    names: ["st", "stone", "stones"] },
  { sym: "slug", dim: "mass", factor: 14.593902937206364, def: "kg",
    names: ["slug", "slugs"] },
  { sym: "ton", dim: "mass", factor: 907.18474, def: "t",
    names: ["ton", "tons", "shortton", "shorttons"] },
  { sym: "longton", dim: "mass", factor: 1016.0469088, def: "t",
    names: ["longton", "longtons"] },
  { sym: "ml", dim: "volume", factor: 0.001, def: "floz",
    names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres",
      "cc", "cm3", "cm^3", "cubiccentimeter", "cubiccentimeters",
      "cubiccentimetre", "cubiccentimetres"] },
  { sym: "cl", dim: "volume", factor: 0.01, def: "ml",
    names: ["cl", "centiliter", "centiliters", "centilitre", "centilitres"] },
  { sym: "dl", dim: "volume", factor: 0.1, def: "cl",
    names: ["dl", "deciliter", "deciliters", "decilitre", "decilitres"] },
  // A litre's neighbour is the millilitre. A third of a gallon is a number
  // nobody asks for.
  { sym: "l", dim: "volume", factor: 1, def: "ml",
    names: ["l", "liter", "liters", "litre", "litres", "dm3", "dm^3"] },
  { sym: "hl", dim: "volume", factor: 100, def: "l",
    names: ["hl", "hectoliter", "hectoliters", "hectolitre", "hectolitres"] },
  { sym: "tsp", dim: "volume", factor: 0.00492892159375, def: "ml",
    names: ["tsp", "teaspoon", "teaspoons"] },
  { sym: "tbsp", dim: "volume", factor: 0.01478676478125, def: "ml",
    names: ["tbsp", "tablespoon", "tablespoons"] },
  { sym: "floz", dim: "volume", factor: 0.0295735295625, def: "ml",
    names: ["floz", "fluidounce", "fluidounces", "usfloz"] },
  { sym: "gill", dim: "volume", factor: 0.11829411825, def: "ml",
    names: ["gill", "gills"] },
  { sym: "cup", dim: "volume", factor: 0.2365882365, def: "ml",
    names: ["cup", "cups"] },
  { sym: "pt", dim: "volume", factor: 0.473176473, def: "l",
    names: ["pt", "pint", "pints"] },
  { sym: "qt", dim: "volume", factor: 0.946352946, def: "l",
    names: ["qt", "quart", "quarts"] },
  { sym: "gal", dim: "volume", factor: 3.785411784, def: "l",
    names: ["gal", "gallon", "gallons", "usgal", "usgallon", "usgallons"] },
  { sym: "bbl", dim: "volume", factor: 158.987294928, def: "l",
    names: ["bbl", "barrel", "barrels"] },
  { sym: "in3", dim: "volume", factor: 0.016387064, def: "ml",
    names: ["in3", "in^3", "cubicinch", "cubicinches", "cuin"] },
  { sym: "ft3", dim: "volume", factor: 28.316846592, def: "l",
    names: ["ft3", "ft^3", "cubicfoot", "cubicfeet", "cuft"] },
  { sym: "m3", dim: "volume", factor: 1000, def: "ft3",
    names: ["m3", "m^3", "cubicmeter", "cubicmeters", "cubicmetre", "cubicmetres"] },
  { sym: "ukfloz", dim: "volume", factor: 0.0284130625, def: "ml",
    names: ["ukfloz", "ukfluidounce", "ukfluidounces", "impfloz"] },
  { sym: "ukpt", dim: "volume", factor: 0.56826125, def: "l",
    names: ["ukpt", "ukpint", "ukpints", "imppt"] },
  { sym: "ukqt", dim: "volume", factor: 1.1365225, def: "l",
    names: ["ukqt", "ukquart", "ukquarts", "impqt"] },
  { sym: "ukgal", dim: "volume", factor: 4.54609, def: "l",
    names: ["ukgal", "ukgallon", "ukgallons", "impgal", "imperialgallon", "imperialgallons"] },
  { sym: "m/s", dim: "speed", factor: 1, def: "mph",
    names: ["m/s", "mps", "meterpersecond", "meterspersecond", "metrepersecond"] },
  // Mach is not a constant without an air temperature and a pressure, and
  // the two it needs are not in the query.
  { sym: "m/min", dim: "speed", factor: 0.016666666666666666, def: "km/h",
    names: ["m/min", "meterperminute", "metersperminute", "metreperminute", "metresperminute"] },
  { sym: "km/h", dim: "speed", factor: 1000 / 3600, def: "mph",
    names: ["km/h", "kmh", "kph", "kmph", "km/hr", "kilometreperhour",
      "kilometresperhour", "kilometerperhour", "kilometersperhour"] },
  { sym: "mph", dim: "speed", factor: 0.44704, def: "km/h",
    names: ["mph", "mi/h", "mi/hr", "mileperhour", "milesperhour"] },
  { sym: "ft/s", dim: "speed", factor: 0.3048, def: "m/s",
    names: ["ft/s", "fps", "footpersecond", "feetpersecond"] },
  { sym: "ft/min", dim: "speed", factor: 0.00508, def: "m/s",
    names: ["ft/min", "footperminute", "feetperminute"] },
  { sym: "kn", dim: "speed", factor: 1852 / 3600, def: "km/h",
    names: ["kn", "kt", "knot", "knots"] },
  { sym: "C", dim: "temperature", def: "F",
    names: ["c", "celsius", "centigrade", "degc", "degreescelsius"] },
  { sym: "F", dim: "temperature", def: "C",
    names: ["f", "fahrenheit", "degf", "degreesfahrenheit"] },
  { sym: "K", dim: "temperature", def: "C",
    names: ["k", "kelvin", "degreeskelvin"] },
  { sym: "Re", dim: "temperature", def: "C",
    names: ["re", "reaumur", "reaumurs", "r\u00e9aumur"] },
  { sym: "R", dim: "temperature", def: "K",
    names: ["r", "rankine", "rankines"] },
  { sym: "nm2", dim: "area", factor: 1e-18, def: "um2",
    names: ["nm2", "nm^2", "sqnm"] },
  { sym: "um2", dim: "area", factor: 1e-12, def: "mm2",
    names: ["um2", "um^2", "squm"] },
  { sym: "mm2", dim: "area", factor: 1e-6, def: "cm2",
    names: ["mm2", "mm^2", "sqmm", "squaremillimeter", "squaremillimeters",
      "squaremillimetre", "squaremillimetres"] },
  { sym: "cm2", dim: "area", factor: 0.0001, def: "in2",
    names: ["cm2", "cm^2", "sqcm", "squarecentimeter", "squarecentimeters",
      "squarecentimetre", "squarecentimetres"] },
  { sym: "dm2", dim: "area", factor: 0.01, def: "cm2",
    names: ["dm2", "dm^2", "sqdm"] },
  { sym: "m2", dim: "area", factor: 1, def: "ft2",
    names: ["m2", "m^2", "sqm", "squaremeter", "squaremeters", "squaremetre", "squaremetres"] },
  { sym: "ha", dim: "area", factor: 10000, def: "ac",
    names: ["ha", "hectare", "hectares"] },
  { sym: "km2", dim: "area", factor: 1000000, def: "mi2",
    names: ["km2", "km^2", "sqkm", "squarekilometer", "squarekilometers",
      "squarekilometre", "squarekilometres"] },
  { sym: "in2", dim: "area", factor: 0.00064516, def: "cm2",
    names: ["in2", "in^2", "sqin", "squareinch", "squareinches"] },
  { sym: "ft2", dim: "area", factor: 0.09290304, def: "m2",
    names: ["ft2", "ft^2", "sqft", "squarefoot", "squarefeet"] },
  { sym: "yd2", dim: "area", factor: 0.83612736, def: "m2",
    names: ["yd2", "yd^2", "sqyd", "squareyard", "squareyards"] },
  { sym: "ac", dim: "area", factor: 4046.8564224, def: "ha",
    names: ["ac", "acre", "acres"] },
  { sym: "mi2", dim: "area", factor: 2589988.110336, def: "km2",
    names: ["mi2", "mi^2", "sqmi", "squaremile", "squaremiles"] },
  { sym: "ns", dim: "time", factor: 1e-9, def: "us",
    names: ["ns", "nanosecond", "nanoseconds"] },
  { sym: "us", dim: "time", factor: 1e-6, def: "ms",
    names: ["us", "microsecond", "microseconds"] },
  { sym: "ms", dim: "time", factor: 0.001, def: "s",
    names: ["ms", "millisecond", "milliseconds"] },
  { sym: "s", dim: "time", factor: 1, def: "min",
    names: ["s", "sec", "secs", "second", "seconds"] },
  { sym: "min", dim: "time", factor: 60, def: "h",
    names: ["min", "mins", "minute", "minutes"] },
  { sym: "h", dim: "time", factor: 3600, def: "d",
    names: ["h", "hr", "hrs", "hour", "hours"] },
  { sym: "d", dim: "time", factor: 86400, def: "wk",
    names: ["d", "day", "days"] },
  { sym: "wk", dim: "time", factor: 604800, def: "d",
    names: ["wk", "wks", "week", "weeks"] },
  { sym: "fortnight", dim: "time", factor: 1209600, def: "d",
    names: ["fortnight", "fortnights"] },
  // A year is 365 days in this table. The light-year row above is the IAU's,
  // which is the 365.25-day Julian year (see jyr), so the two differ on
  // purpose: 1 ly is 365.25 light-days and 1 yr is 365 days.
  { sym: "yr", dim: "time", factor: 31536000, def: "d",
    names: ["yr", "yrs", "year", "years"] },
  { sym: "decade", dim: "time", factor: 315360000, def: "yr",
    names: ["decade", "decades"] },
  { sym: "century", dim: "time", factor: 3153600000, def: "yr",
    names: ["century", "centuries"] },
  { sym: "erg", dim: "energy", factor: 1e-7, def: "J",
    names: ["erg", "ergs"] },
  { sym: "J", dim: "energy", factor: 1, def: "cal",
    names: ["j", "joule", "joules"] },
  { sym: "kJ", dim: "energy", factor: 1000, def: "kcal",
    names: ["kj", "kilojoule", "kilojoules"] },
  { sym: "MJ", dim: "energy", factor: 1e6, def: "kJ",
    names: ["mj", "megajoule", "megajoules"] },
  { sym: "GJ", dim: "energy", factor: 1e9, def: "MJ",
    names: ["gj", "gigajoule", "gigajoules"] },
  { sym: "cal", dim: "energy", factor: 4.184, def: "J",
    names: ["cal", "calorie", "calories"] },
  { sym: "kcal", dim: "energy", factor: 4184, def: "kJ",
    names: ["kcal", "kilocalorie", "kilocalories"] },
  { sym: "Wh", dim: "energy", factor: 3600, def: "kWh",
    names: ["wh", "watthour", "watthours"] },
  { sym: "kWh", dim: "energy", factor: 3600000, def: "Wh",
    names: ["kwh", "kilowatthour", "kilowatthours"] },
  { sym: "eV", dim: "energy", factor: 1.602176634e-19, def: "J",
    names: ["ev", "electronvolt", "electronvolts"] },
  { sym: "BTU", dim: "energy", factor: 1055.05585262, def: "kJ",
    names: ["btu", "btus"] },
  { sym: "therm", dim: "energy", factor: 105505585.262, def: "kWh",
    names: ["therm", "therms"] },
  { sym: "mW", dim: "power", factor: 0.001, def: "W",
    names: ["mw", "milliwatt", "milliwatts"] },
  { sym: "W", dim: "power", factor: 1, def: "hp",
    names: ["w", "watt", "watts"] },
  { sym: "kW", dim: "power", factor: 1000, def: "hp",
    names: ["kw", "kilowatt", "kilowatts"] },
  // Megawatt is not a row: its symbol and the milliwatt symbol fold to
  // the same two characters, and only one of them can claim them.
  { sym: "GW", dim: "power", factor: 1e9, def: "kW",
    names: ["gw", "gigawatt", "gigawatts"] },
  { sym: "hp", dim: "power", factor: 745.699872, def: "kW",
    names: ["hp", "horsepower"] },
  // Brake horsepower is 1.3e-7 above the mechanical horsepower, seven orders
  // below this engine's six significant digits, and "bhp" is one more
  // alias to keep unique for a difference no reader can see.
  { sym: "PS", dim: "power", factor: 735.49875, def: "hp",
    names: ["ps", "metrichorsepower", "metrichorsepowers"] },
  { sym: "Pa", dim: "pressure", factor: 1, def: "psi",
    names: ["pa", "pascal", "pascals"] },
  { sym: "hPa", dim: "pressure", factor: 100, def: "Pa",
    names: ["hpa", "hectopascal", "hectopascals"] },
  { sym: "kPa", dim: "pressure", factor: 1000, def: "psi",
    names: ["kpa", "kilopascal", "kilopascals"] },
  { sym: "MPa", dim: "pressure", factor: 1e6, def: "bar",
    names: ["mpa", "megapascal", "megapascals"] },
  { sym: "GPa", dim: "pressure", factor: 1e9, def: "MPa",
    names: ["gpa", "gigapascal", "gigapascals"] },
  { sym: "bar", dim: "pressure", factor: 100000, def: "psi",
    names: ["bar", "bars"] },
  { sym: "mbar", dim: "pressure", factor: 100, def: "hPa",
    names: ["mbar", "millibar", "millibars"] },
  { sym: "kbar", dim: "pressure", factor: 1e8, def: "bar",
    names: ["kbar", "kilobar", "kilobars"] },
  { sym: "psi", dim: "pressure", factor: 6894.757293168, def: "kPa",
    names: ["psi", "poundspersquareinch", "lbf/in2", "lbf/in^2"] },
  { sym: "ksi", dim: "pressure", factor: 6894757.293168361, def: "psi",
    names: ["ksi", "kilopoundssquareinch"] },
  { sym: "psf", dim: "pressure", factor: 47.88025898, def: "Pa",
    names: ["psf", "poundsquarefoot"] },
  { sym: "atm", dim: "pressure", factor: 101325, def: "bar",
    names: ["atm", "atmosphere", "atmospheres"] },
  { sym: "mmHg", dim: "pressure", factor: 133.322387415, def: "kPa",
    names: ["mmhg", "torr"] },
  { sym: "inHg", dim: "pressure", factor: 3386.388640341, def: "mmHg",
    names: ["inhg", "inchofmercury", "inchesofmercury"] },
  { sym: "mmH2O", dim: "pressure", factor: 9.80665, def: "Pa",
    names: ["mmh2o", "millimeterofwater", "millimetersofwater"] },
  { sym: "inH2O", dim: "pressure", factor: 249.0889, def: "mmH2O",
    names: ["inh2o", "inchofwater", "inchesofwater"] },
  // SI decimal, so "5 GB in MB" is 5000. The 1024 reading lives on KiB,
  // MiB, GiB and TiB, which are the symbols that actually mean it.
  { sym: "B", dim: "data", factor: 1, def: "KB",
    names: ["b", "byte", "bytes"] },
  { sym: "KB", dim: "data", factor: 1e3, def: "MB",
    names: ["kb", "kilobyte", "kilobytes"] },
  { sym: "MB", dim: "data", factor: 1e6, def: "GB",
    names: ["mb", "megabyte", "megabytes"] },
  { sym: "GB", dim: "data", factor: 1e9, def: "TB",
    names: ["gb", "gigabyte", "gigabytes"] },
  { sym: "TB", dim: "data", factor: 1e12, def: "GB",
    names: ["tb", "terabyte", "terabytes"] },
  { sym: "PB", dim: "data", factor: 1e15, def: "TB",
    names: ["pb", "petabyte", "petabytes"] },
  { sym: "EB", dim: "data", factor: 1e18, def: "PB",
    names: ["eb", "exabyte", "exabytes"] },
  { sym: "bit", dim: "data", factor: 0.125, def: "B",
    names: ["bit", "bits"] },
  { sym: "kbit", dim: "data", factor: 125, def: "B",
    names: ["kbit", "kilobit", "kilobits"] },
  { sym: "Mbit", dim: "data", factor: 125000, def: "kB",
    names: ["mbit", "megabit", "megabits"] },
  { sym: "Gbit", dim: "data", factor: 125000000, def: "MB",
    names: ["gbit", "gigabit", "gigabits"] },
  { sym: "Tbit", dim: "data", factor: 125000000000, def: "GB",
    names: ["tbit", "terabit", "terabits"] },
  { sym: "KiB", dim: "data", factor: 1024, def: "MiB",
    names: ["kib", "kibibyte", "kibibytes"] },
  { sym: "MiB", dim: "data", factor: 1048576, def: "GiB",
    names: ["mib", "mebibyte", "mebibytes"] },
  { sym: "GiB", dim: "data", factor: 1073741824, def: "MiB",
    names: ["gib", "gibibyte", "gibibytes"] },
  { sym: "TiB", dim: "data", factor: 1099511627776, def: "GiB",
    names: ["tib", "tebibyte", "tebibytes"] },
  { sym: "PiB", dim: "data", factor: 1125899906842624, def: "TiB",
    names: ["pib", "pebibyte", "pebibytes"] },
  { sym: "arcsec", dim: "angle", factor: 1 / 3600, def: "arcmin",
    names: ["arcsec", "arcsecond", "arcseconds"] },
  { sym: "arcmin", dim: "angle", factor: 1 / 60, def: "deg",
    names: ["arcmin", "arcminute", "arcminutes"] },
  { sym: "grad", dim: "angle", factor: 0.9, def: "deg",
    names: ["grad", "gradian", "gradians", "gon", "gons"] },
  { sym: "deg", dim: "angle", factor: 1, def: "rad",
    names: ["deg", "degree", "degrees", "\u00b0"] },
  { sym: "rad", dim: "angle", factor: 57.29577951308232, def: "deg",
    names: ["rad", "radian", "radians"] },
  { sym: "turn", dim: "angle", factor: 360, def: "deg",
    names: ["turn", "rev", "revolution", "revolutions", "cycle", "cycles"] },
  { sym: "Hz", dim: "frequency", factor: 1, def: "kHz",
    names: ["hz", "hertz"] },
  { sym: "kHz", dim: "frequency", factor: 1000, def: "Hz",
    names: ["khz", "kilohertz"] },
  { sym: "MHz", dim: "frequency", factor: 1e6, def: "kHz",
    names: ["mhz", "megahertz"] },
  { sym: "GHz", dim: "frequency", factor: 1e9, def: "MHz",
    names: ["ghz", "gigahertz"] },
  { sym: "THz", dim: "frequency", factor: 1e12, def: "GHz",
    names: ["thz", "terahertz"] },
  { sym: "rpm", dim: "frequency", factor: 0.016666666666666666, def: "Hz",
    names: ["rpm", "revolutionsperminute"] },
  { sym: "dyn", dim: "force", factor: 1e-5, def: "N",
    names: ["dyn", "dyne", "dynes"] },
  { sym: "N", dim: "force", factor: 1, def: "lbf",
    names: ["n", "newton", "newtons"] },
  // Kilonewton is not a row: its own symbol folds to "kn", and the knot has
  // claimed those two characters.
  { sym: "kgf", dim: "force", factor: 9.80665, def: "N",
    names: ["kgf", "kilogramforce", "kilogramforces"] },
  { sym: "lbf", dim: "force", factor: 4.4482216152605, def: "N",
    names: ["lbf", "poundforce", "poundforces"] },
  // No "nm" alias here. normalizeUnit folds case, so the newton-metre would
  // answer to the same two characters as the nanometre, and "5 Nm" is a
  // nanometre query by design.
  { sym: "N\u00b7m", dim: "torque", factor: 1, def: "lbf\u00b7ft",
    names: ["n\u00b7m", "n*m", "newtonmetre", "newtonmeter", "newtonmetres", "newtonmeters"] },
  { sym: "lbf\u00b7ft", dim: "torque", factor: 1.3558179483314004, def: "N\u00b7m",
    names: ["lbf\u00b7ft", "lbf*ft", "lbfft", "footpound", "footpounds", "ftlbf", "ft*lbf",
      "ftlb", "ftlbs"] },
  // Litres per 100 km is the reciprocal of this dimension and a factor
  // ratio cannot express a reciprocal, so the row that exists is the one
  // whose factors are correct in both directions.
  { sym: "km/l", dim: "fuel", factor: 1, def: "mpg",
    names: ["km/l", "kilometersperliter", "kilometresperliter", "kml", "kmpl"] },
  { sym: "mpg", dim: "fuel", factor: 0.4251437074976, def: "km/l",
    names: ["mpg", "milespergallon", "mpgus"] },
  { sym: "mpgimp", dim: "fuel", factor: 0.354006189934, def: "mpg",
    names: ["mpgimp", "milesperimperialgallon", "imperialmpg", "mpguk"] },
  { sym: "g/L", dim: "concentration", factor: 1, def: "mg/dL",
    names: ["g/l", "gramsperliter", "gramsperlitre"] },
  { sym: "mg/dL", dim: "concentration", factor: 0.01, def: "g/L",
    names: ["mg/dl", "milligramsperdeciliter", "milligramsperdecilitre"] },
  { sym: "mg/L", dim: "concentration", factor: 0.001, def: "g/L",
    names: ["mg/l", "milligramsperliter", "milligramsperlitre"] },
  { sym: "ug/mL", dim: "concentration", factor: 0.001, def: "mg/dL",
    names: ["ug/ml", "microgramspermilliliter", "microgramspermillilitre"] },
  { sym: "mol/L", dim: "molarity", factor: 1, def: "mmol/L",
    names: ["mol/l", "molar"] },
  { sym: "mmol/L", dim: "molarity", factor: 0.001, def: "mol/L",
    names: ["mmol/l", "millimolar"] },
  { sym: "umol/L", dim: "molarity", factor: 1e-6, def: "mmol/L",
    names: ["umol/l", "micromolar"] },
  { sym: "%", dim: "fraction", factor: 0.01, def: "\u2030",
    names: ["%", "percent", "percentage", "pct"] },
  { sym: "\u2030", dim: "fraction", factor: 0.001, def: "%",
    names: ["\u2030", "permille", "perthousand"] },
  { sym: "ppm", dim: "fraction", factor: 1e-6, def: "ppb",
    names: ["ppm", "partspermillion"] },
  { sym: "ppb", dim: "fraction", factor: 1e-9, def: "ppm",
    names: ["ppb", "partsperbillion"] },
  { sym: "m3/h", dim: "flow", factor: 1, def: "l/min",
    names: ["m3/h", "m^3/h", "cubicmeterperhour", "cubicmetersperhour", "cubicmetreperhour"] },
  { sym: "l/min", dim: "flow", factor: 0.06, def: "m3/h",
    names: ["l/min", "literperminute", "litersperminute", "litreperminute", "litresperminute"] },
  { sym: "cfm", dim: "flow", factor: 1.69901079552, def: "m3/h",
    names: ["cfm", "cubicfootperminute", "cubicfeetperminute"] },
  { sym: "gpm", dim: "flow", factor: 0.22712470704, def: "l/min",
    names: ["gpm", "gallonperminute", "gallonsperminute"] }
];

// Length shorthand accepted as a speed target: "250mph in km"
// reads as km/h. One direction only - a length source with a
// speed target stays incompatible.
var SPEED_LEN = { "km": "km/h", "mi": "mph", "m": "m/s", "ft": "ft/s", "nmi": "kn" };

// A bare query answers with a NEIGHBOUR unit, and which neighbour depends on
// the dimension's shape. time's steps are irregular (60, 24, 7, 365), so the
// reading has to land inside a step of the candidate or "1 d" would answer in
// weeks; data's are a prefix ladder, where that same window strands "1 GB"
// between TB and MB. Every other dimension answers with its `def`, which is
// the other system's unit - metres to feet, kilograms to pounds - and that is
// the more useful reading than any prefix neighbour.
var DEF_LADDER = {
  time: { pick: "window",  syms: ["yr", "wk", "d", "h", "min", "s", "ms"] },
  data: { pick: "nearest", syms: ["TB", "GB", "MB", "KB", "B", "bit"] }
};

// How many rows a bare query may answer with. Five is the most a launcher
// card shows before the list reads as a pool rather than as one answer, and
// six is the ceiling the list is allowed to reach: a quantity with a dozen
// convertible siblings still gets one screenful, not a scroll.
var MAX_TARGETS = 6;

// The targets a bare query offers BEYOND its default, per dimension, in the
// order the rows are shown. This is a shortlist of what a person asks for,
// not every unit of the dimension, and the two lists disagree on purpose:
//
//   - The SI prefix ladder is mostly noise once the source is a prefix unit.
//     A gram is not "100 decigrams", and a metre is not "5 dekametres";
//     those rows exist to pad a list, so they are absent. What IS offered is
//     the other system's unit and the neighbouring rungs that a reader would
//     say out loud - which is why `5 MB` answers in bytes, kilobytes and
//     gibibytes rather than in petabytes.
//   - `hand`, `thou`, `fathom`, `carat`, `slug`, `grain`, `mil` and the
//     imperial volume and molarity rows are real and convertible, and none of
//     them is what somebody types after a bare "5". Each one is reachable by
//     naming it, which is the query shape that asks for it.
//   - A dimension with three members (torque, molarity, fuel) lists all
//     three, because the shortlist IS the dimension there.
//
// The head of the row list is not here: it is pickDefault's answer, so the
// first row of a bare query is the same row a single-answer engine showed.
var SUGGEST = {
  length: ["cm", "ft", "in", "mm", "km", "yd", "mi", "nmi", "ls", "lmin", "au", "ly", "pc"],
  mass: ["g", "lb", "oz", "st", "ton", "t", "mg", "Mearth", "Mjup", "Msun"],
  volume: ["ml", "l", "floz", "tsp", "tbsp", "cup", "gal", "pt", "qt"],
  speed: ["km/h", "mph", "m/s", "kn", "ft/s", "m/min"],
  temperature: ["F", "C", "K", "R", "Re"],
  area: ["m2", "ft2", "ha", "in2", "cm2", "km2", "ac", "yd2", "mi2"],
  time: ["s", "min", "h", "d", "wk", "yr", "ms", "month"],
  energy: ["kWh", "J", "kJ", "cal", "kcal", "Wh", "MJ", "BTU", "therm"],
  // Power has six members and four of them are worth a row. kWh, J and cal are
  // the ENERGY dimension's units, and a factor ratio cannot cross that line -
  // the engine answers "incompatible" for the pair rather than printing a
  // watt-hours reading with a joule symbol on it.
  power: ["W", "kW", "hp", "PS", "MW", "BTU/h"],
  pressure: ["Pa", "kPa", "bar", "psi", "atm", "mmHg", "MPa", "mbar", "inHg"],
  data: ["B", "KB", "MB", "GB", "KiB", "MiB", "GiB", "TB", "bit"],
  angle: ["deg", "rad", "grad", "arcmin", "arcsec", "turn"],
  frequency: ["Hz", "kHz", "MHz", "GHz", "rpm"],
  force: ["N", "lbf", "kgf", "dyn", "kN"],
  torque: ["N\u00b7m", "lbf\u00b7ft"],
  fuel: ["mpg", "km/l", "l/100km", "mpgimp"],
  concentration: ["g/L", "mg/dL", "mg/L", "ug/mL", "g/dL", "mg/mL"],
  molarity: ["mol/L", "mmol/L", "umol/L"],
  fraction: ["%", "ppm", "\u2030", "ppb"],
  flow: ["m3/h", "l/min", "cfm", "gpm", "l/s"]
};

// Extra bounds for the shortlist entries whose scale is not a person's. The
// light ladder and the AU are offered so that a Moon distance or a star can be
// read in them, but a kilometre answered as "0.004 light-seconds" and a
// parsec answered as "8577260 light-minutes" are rows that only pad the list.
// A bound is [smallest, largest] reading, and it applies on top of readable().
var SUGGEST_RANGE = {
  ls: [0.01, 1e5], lmin: [0.01, 1e5], au: [0.01, 1e5], ly: [0.01, 1e5], pc: [0.01, 1e5]
};

// How far a reading may sit from a number a person says out loud. A value is
// readable when it is within MAX_DECADES of one or of a thousand, which is the
// "a count, or a fraction of one" notion the shortlist above is written in:
// 5000 and 0.005 are both readings, 5e-6 and 5e9 are neither. It is not the
// formatter's threshold - formatNumber only reaches for exponential form past
// 1e12 and under 1e-6 - so a row can still print "1.55e+7 in2" inside this
// window. That is the formatter's documented behaviour and this bound is the
// looser of the two: the question here is whether the number is worth a row,
// not whether it is the shape the formatter prefers.
var MAX_DECADES = 5;

// Where a FRACTION stops being one. The bound above is symmetric, and that
// symmetry is right for a count and wrong for a fraction of a greater unit:
// "a twentieth of a gigabyte" is a question about capacity and answers it,
// while "a two-thousandth of a kilometre" and "a twenty-thousandth of a stone"
// are not questions anybody asks. A thousandth is the line: it keeps the
// fraction rows that carry a fact (5 MB is 0.005 GB, 7 d is 0.019 yr) and drops
// the ones that are only the next rung of a ladder seen from below.
var MIN_FRACTION = 0.001;

// Whether a converted reading is one worth a row. A zero and a non-finite
// reading fail the magnitude test rather than being special-cased, which is
// what makes an overflowing candidate drop out instead of printing "Infinity".
// What a unit is called in a sentence, for EVERY unit in the table, in UNITS
// order. The bare list could not name the 50 or so that are reachable only by
// being typed as an explicit target, and an answer that names half its units
// and symbols the rest is worse than one that is uniform - so the table covers
// the whole table and the fallback below is a guard rather than a shape.
//
// Every name is stored the way it prints. A unit name is a common noun, so it
// reads down: "3600 joules is 0.001 kilowatt-hours", not a title. The capital
// that appears is a proper noun inside a name ("Celsius", "British thermal
// unit"), where the lowercase form would be wrong English, and the suite pins
// that list - a stray capital would print "5 Metres is 500 Centimetres" and
// read like a heading. Four nouns also open with the degree sign, which is a
// prefix on the name rather than a capital, and the suite pins those too.
//
// [singular, plural] rather than a noun with a rule appended, because English
// has no such rule here: a foot is feet, an inch is inches, kelvin and hertz
// and psi take no plural at all, and only the HEAD of "square foot" or "metre
// per second" inflects - "square feet", "metres per second" - never its tail.
// Spelling both out is more data and less code, and it cannot be wrong by
// construction.
//
// British spellings, because the prose this ships in already says "metre" and
// the compound style is the one the symbol spells: a kilowatt-hour, not a
// kilowatt per hour for the energy and a kilowatt per hour for the power.
var UNIT_NOUN = {
  length: {
    "A": ["angstrom", "angstroms"],
    "nm": ["nanometre", "nanometres"],
    "um": ["micrometre", "micrometres"],
    "mm": ["millimetre", "millimetres"],
    "cm": ["centimetre", "centimetres"],
    "dm": ["decimetre", "decimetres"],
    "m": ["metre", "metres"],
    "dam": ["decametre", "decametres"],
    "hm": ["hectometre", "hectometres"],
    "km": ["kilometre", "kilometres"],
    "in": ["inch", "inches"],
    // Wire gauge and paper thickness: a thousandth of an inch. It is a name
    // rather than a number, which is why the unit table calls it one.
    "thou": ["thousandth of an inch", "thousandths of an inch"],
    "hand": ["hand", "hands"],
    "ft": ["foot", "feet"],
    "yd": ["yard", "yards"],
    "fathom": ["fathom", "fathoms"],
    "mi": ["mile", "miles"],
    "nmi": ["nautical mile", "nautical miles"],
    "au": ["astronomical unit", "astronomical units"],
    // The light ladder, hyphenated the way the symbol spells it - the noun is
    // "light-year" and not "lightyear" or "year of light", because the first is
    // how it is written and the other two are how it would be parsed.
    "ls": ["light-second", "light-seconds"],
    "lmin": ["light-minute", "light-minutes"],
    "lh": ["light-hour", "light-hours"],
    "ld": ["light-day", "light-days"],
    "lw": ["light-week", "light-weeks"],
    "ly": ["light-year", "light-years"],
    "pc": ["parsec", "parsecs"]
  },
  mass: {
    "ng": ["nanogram", "nanograms"],
    "ug": ["microgram", "micrograms"],
    "mg": ["milligram", "milligrams"],
    "grain": ["grain", "grains"],
    "carat": ["carat", "carats"],
    "g": ["gram", "grams"],
    "dg": ["decigram", "decigrams"],
    "dag": ["decagram", "decagrams"],
    "hg": ["hectogram", "hectograms"],
    "kg": ["kilogram", "kilograms"],
    "t": ["tonne", "tonnes"],
    "oz": ["ounce", "ounces"],
    "lb": ["pound", "pounds"],
    "st": ["stone", "stones"],
    "slug": ["slug", "slugs"],
    "ton": ["short ton", "short tons"],
    "longton": ["long ton", "long tons"]
  },
  volume: {
    "ml": ["millilitre", "millilitres"],
    "cl": ["centilitre", "centilitres"],
    "dl": ["decilitre", "decilitres"],
    "l": ["litre", "litres"],
    "hl": ["hectolitre", "hectolitres"],
    "tsp": ["teaspoon", "teaspoons"],
    "tbsp": ["tablespoon", "tablespoons"],
    "floz": ["fluid ounce", "fluid ounces"],
    "gill": ["gill", "gills"],
    "cup": ["cup", "cups"],
    "pt": ["pint", "pints"],
    "qt": ["quart", "quarts"],
    "gal": ["gallon", "gallons"],
    "bbl": ["barrel", "barrels"],
    "in3": ["cubic inch", "cubic inches"],
    "ft3": ["cubic foot", "cubic feet"],
    "m3": ["cubic metre", "cubic metres"],
    "ukfloz": ["imperial fluid ounce", "imperial fluid ounces"],
    "ukpt": ["imperial pint", "imperial pints"],
    "ukqt": ["imperial quart", "imperial quarts"],
    "ukgal": ["imperial gallon", "imperial gallons"]
  },
  speed: {
    "m/s": ["metre per second", "metres per second"],
    "m/min": ["metre per minute", "metres per minute"],
    "km/h": ["kilometre per hour", "kilometres per hour"],
    "mph": ["mile per hour", "miles per hour"],
    "ft/s": ["foot per second", "feet per second"],
    "ft/min": ["foot per minute", "feet per minute"],
    "kn": ["knot", "knots"]
  },
  temperature: {
    // A scale that measures a degree carries the degree sign as a prefix on its
    // FULL name - "100 \u00b0Celsius" - rather than dropping the name for the
    // symbol ("100 \u00b0C") or spelling the word out ("100 degrees Celsius").
    // The sign binds to the name and the ordinary space in phrase() separates the
    // value from the noun, so a sign-led noun needs no rule of its own: it is
    // just a noun that happens to begin with a sign.
    //
    // Kelvin is the one scale that takes no degree sign: it is an absolute
    // scale rather than a degree of anything, so its noun is the bare name.
    "C": ["\u00b0Celsius", "\u00b0Celsius"],
    "F": ["\u00b0Fahrenheit", "\u00b0Fahrenheit"],
    "K": ["kelvin", "kelvin"],
    "Re": ["\u00b0R\u00e9aumur", "\u00b0R\u00e9aumur"],
    "R": ["\u00b0Rankine", "\u00b0Rankine"]
  },
  area: {
    "nm2": ["square nanometre", "square nanometres"],
    "um2": ["square micrometre", "square micrometres"],
    "mm2": ["square millimetre", "square millimetres"],
    "cm2": ["square centimetre", "square centimetres"],
    "dm2": ["square decimetre", "square decimetres"],
    "m2": ["square metre", "square metres"],
    "ha": ["hectare", "hectares"],
    "km2": ["square kilometre", "square kilometres"],
    "in2": ["square inch", "square inches"],
    "ft2": ["square foot", "square feet"],
    "yd2": ["square yard", "square yards"],
    "ac": ["acre", "acres"],
    "mi2": ["square mile", "square miles"]
  },
  time: {
    "ns": ["nanosecond", "nanoseconds"],
    "us": ["microsecond", "microseconds"],
    "ms": ["millisecond", "milliseconds"],
    "s": ["second", "seconds"],
    "min": ["minute", "minutes"],
    "h": ["hour", "hours"],
    "d": ["day", "days"],
    "wk": ["week", "weeks"],
    "fortnight": ["fortnight", "fortnights"],
    "yr": ["year", "years"],
    "decade": ["decade", "decades"],
    "century": ["century", "centuries"]
  },
  energy: {
    "erg": ["erg", "ergs"],
    "J": ["joule", "joules"],
    "kJ": ["kilojoule", "kilojoules"],
    "MJ": ["megajoule", "megajoules"],
    "GJ": ["gigajoule", "gigajoules"],
    "cal": ["calorie", "calories"],
    "kcal": ["kilocalorie", "kilocalories"],
    "Wh": ["watt-hour", "watt-hours"],
    "kWh": ["kilowatt-hour", "kilowatt-hours"],
    "eV": ["electronvolt", "electronvolts"],
    "BTU": ["British thermal unit", "British thermal units"],
    "therm": ["therm", "therms"]
  },
  power: {
    "mW": ["milliwatt", "milliwatts"],
    "W": ["watt", "watts"],
    "kW": ["kilowatt", "kilowatts"],
    // Megawatt is not a row of its own - its symbol folds onto the milliwatt -
    // so the gigawatt is the row and the megawatt is reachable by name.
    "GW": ["gigawatt", "gigawatts"],
    // Both horsepower names are plural-invariant in English: "500 horsepower",
    // never "500 horsepowers".
    "hp": ["horsepower", "horsepower"],
    "PS": ["metric horsepower", "metric horsepower"]
  },
  pressure: {
    "Pa": ["pascal", "pascals"],
    "hPa": ["hectopascal", "hectopascals"],
    "kPa": ["kilopascal", "kilopascals"],
    "MPa": ["megapascal", "megapascals"],
    "GPa": ["gigapascal", "gigapascals"],
    "bar": ["bar", "bar"],
    "mbar": ["millibar", "millibars"],
    "kbar": ["kilobar", "kilobars"],
    "psi": ["psi", "psi"],
    "ksi": ["kilopound per square inch", "kilopounds per square inch"],
    "psf": ["pound per square foot", "pounds per square foot"],
    "atm": ["atmosphere", "atmospheres"],
    "mmHg": ["millimetre of mercury", "millimetres of mercury"],
    "inHg": ["inch of mercury", "inches of mercury"],
    "mmH2O": ["millimetre of water", "millimetres of water"],
    "inH2O": ["inch of water", "inches of water"]
  },
  data: {
    "B": ["byte", "bytes"],
    "KB": ["kilobyte", "kilobytes"],
    "MB": ["megabyte", "megabytes"],
    "GB": ["gigabyte", "gigabytes"],
    "TB": ["terabyte", "terabytes"],
    "PB": ["petabyte", "petabytes"],
    "EB": ["exabyte", "exabytes"],
    "bit": ["bit", "bits"],
    "kbit": ["kilobit", "kilobits"],
    "Mbit": ["megabit", "megabits"],
    "Gbit": ["gigabit", "gigabits"],
    "Tbit": ["terabit", "terabits"],
    "KiB": ["kibibyte", "kibibytes"],
    "MiB": ["mebibyte", "mebibytes"],
    "GiB": ["gibibyte", "gibibytes"],
    "TiB": ["tebibyte", "tebibytes"],
    "PiB": ["pebibyte", "pebibytes"]
  },
  angle: {
    "arcsec": ["arcsecond", "arcseconds"],
    "arcmin": ["arcminute", "arcminutes"],
    "grad": ["gradian", "gradians"],
    // A degree of angle has no scale name behind it, so there is nothing for a
    // sign to sit in front of: the noun is the word and stays the word.
    "deg": ["degree", "degrees"],
    "rad": ["radian", "radians"],
    "turn": ["turn", "turns"]
  },
  frequency: {
    // Hertz is plural-invariant, and so is every prefix of it: "5 kilohertz".
    "Hz": ["hertz", "hertz"],
    "kHz": ["kilohertz", "kilohertz"],
    "MHz": ["megahertz", "megahertz"],
    "GHz": ["gigahertz", "gigahertz"],
    "THz": ["terahertz", "terahertz"],
    "rpm": ["revolution per minute", "revolutions per minute"]
  },
  force: {
    "dyn": ["dyne", "dynes"],
    "N": ["newton", "newtons"],
    "kgf": ["kilogram-force", "kilogram-force"],
    "lbf": ["pound-force", "pound-force"]
  },
  torque: {
    "N\u00b7m": ["newton metre", "newton metres"],
    "lbf\u00b7ft": ["pound-force foot", "pound-force feet"]
  },
  fuel: {
    "km/l": ["kilometre per litre", "kilometres per litre"],
    "mpg": ["mile per gallon", "miles per gallon"],
    "mpgimp": ["mile per imperial gallon", "miles per imperial gallon"]
  },
  concentration: {
    "g/L": ["gram per litre", "grams per litre"],
    "mg/dL": ["milligram per decilitre", "milligrams per decilitre"],
    "mg/L": ["milligram per litre", "milligrams per litre"],
    "ug/mL": ["microgram per millilitre", "micrograms per millilitre"]
  },
  molarity: {
    "mol/L": ["mole per litre", "moles per litre"],
    "mmol/L": ["millimole per litre", "millimoles per litre"],
    "umol/L": ["micromole per litre", "micromoles per litre"]
  },
  fraction: {
    // "percent" and "permille" rather than the phrases "per cent" and "per
    // mille": a noun is capitalised at the head of a sentence, and "Per cent"
    // is not a noun. The fractional ones read as ratios, and only their head
    // inflects - "parts per million", never "parts per millions".
    "%": ["percent", "percent"],
    "\u2030": ["permille", "permille"],
    "ppm": ["part per million", "parts per million"],
    "ppb": ["part per billion", "parts per billion"]
  },
  flow: {
    "m3/h": ["cubic metre per hour", "cubic metres per hour"],
    "l/min": ["litre per minute", "litres per minute"],
    "cfm": ["cubic foot per minute", "cubic feet per minute"],
    "gpm": ["gallon per minute", "gallons per minute"]
  }
};

// ---------------------------------------------------------------------------
// Rows added after the audit. They are appended to the table instead of being
// woven into it on purpose: dimHint offers "the rest of the dimension in table
// order", and a hint that suggests a banana or a megaparsec as what you
// probably meant is worse than none, so the plain units stay in front.
//
// A row is its symbol, dimension, factor to the base, default target, the
// aliases (already in normalized form: lowercase, no spaces) and its name as a
// sentence [singular, plural]. `extra` merges into the row (recip).
// ---------------------------------------------------------------------------
function addUnit(sym, dim, factor, def, names, noun, extra) {
  var u = { sym: sym, dim: dim, factor: factor, def: def, names: names };
  if (extra) for (var k in extra) u[k] = extra[k];
  UNITS.push(u);
  if (UNIT_NOUN[dim] === undefined) UNIT_NOUN[dim] = {};
  UNIT_NOUN[dim][sym] = noun;
}

// --- astronomy and the rest of the real gaps -------------------------------
// The length ladder above stops at the parsec; the Milky Way is 30 kpc across
// and the Andromeda galaxy is 0.78 Mpc away, so the prefixes go on. IAU 2015
// nominal values for the solar and planetary radii and masses.
addUnit("Mm", "length", 1e6, "mi", ["megameter", "megameters", "megametre", "megametres"],
  ["megametre", "megametres"]);
addUnit("fermi", "length", 1e-15, "A", ["fermi", "fermis", "femtometer", "femtometers", "femtometre", "femtometres"],
  ["femtometre", "femtometres"]);
addUnit("bohr", "length", 5.29177210903e-11, "A", ["bohr", "bohrs", "bohrradius", "bohrradii"],
  ["bohr radius", "bohr radii"]);
addUnit("kpc", "length", 3.085677581491367e19, "ly", ["kpc", "kiloparsec", "kiloparsecs"],
  ["kiloparsec", "kiloparsecs"]);
addUnit("Mpc", "length", 3.085677581491367e22, "Mly", ["mpc", "megaparsec", "megaparsecs"],
  ["megaparsec", "megaparsecs"]);
addUnit("Gpc", "length", 3.085677581491367e25, "Gly", ["gpc", "gigaparsec", "gigaparsecs"],
  ["gigaparsec", "gigaparsecs"]);
addUnit("Mly", "length", 9.4607304725808e21, "Mpc", ["mly", "megalightyear", "megalightyears"],
  ["mega-light-year", "mega-light-years"]);
addUnit("Gly", "length", 9.4607304725808e24, "Gpc", ["gly", "gigalightyear", "gigalightyears"],
  ["giga-light-year", "giga-light-years"]);
addUnit("Rsun", "length", 6.957e8, "km", ["rsun", "solarradius", "solarradii"],
  ["solar radius", "solar radii"]);
addUnit("Rearth", "length", 6.371e6, "km", ["rearth", "earthradius", "earthradii"],
  ["Earth radius", "Earth radii"]);
addUnit("Rjup", "length", 7.1492e7, "km", ["rjup", "jupiterradius", "jupiterradii"],
  ["Jupiter radius", "Jupiter radii"]);
addUnit("lunar distance", "length", 3.84399e8, "km",
  ["lunardistance", "lunardistances", "moondistance", "moondistances"],
  ["lunar distance", "lunar distances"]);

addUnit("ozt", "mass", 0.0311034768, "g", ["ozt", "troyounce", "troyounces"],
  ["troy ounce", "troy ounces"]);
addUnit("Mearth", "mass", 5.9722e24, "kg", ["mearth", "earthmass", "earthmasses"],
  ["Earth mass", "Earth masses"]);
addUnit("Mjup", "mass", 1.8982e27, "Mearth", ["mjup", "jupitermass", "jupitermasses"],
  ["Jupiter mass", "Jupiter masses"]);
addUnit("Msun", "mass", 1.98841e30, "Mearth", ["msun", "solarmass", "solarmasses"],
  ["solar mass", "solar masses"]);
addUnit("Mmoon", "mass", 7.342e22, "kg", ["mmoon", "moonmass", "moonmasses", "lunarmass", "lunarmasses"],
  ["lunar mass", "lunar masses"]);

// A month is one twelfth of this table's 365-day year: 730 hours, the figure
// cloud pricing uses. It is a convention and the noun says so. Julian year and
// the astronomer's megayear and gigayear are separate rows because the light
// year above is defined on the Julian year, and the megayear is not one.
addUnit("month", "time", 2628000, "d", ["month", "months", "mo", "mos"],
  ["average month", "average months"]);
addUnit("millennium", "time", 3.1536e10, "yr", ["millennium", "millennia", "millenniums"],
  ["millennium", "millennia"]);
addUnit("jyr", "time", 31557600, "yr", ["jyr", "julianyear", "julianyears"],
  ["Julian year", "Julian years"]);
addUnit("Myr", "time", 3.1536e13, "yr", ["myr", "megayear", "megayears", "mya"],
  ["megayear", "megayears"]);
addUnit("Gyr", "time", 3.1536e16, "Myr", ["gyr", "gigayear", "gigayears", "gya"],
  ["gigayear", "gigayears"]);
addUnit("sol", "time", 88775.244, "h", ["sol", "sols"], ["sol", "sols"]);
addUnit("sidereal day", "time", 86164.0905, "h", ["siderealday", "siderealdays"],
  ["sidereal day", "sidereal days"]);
addUnit("lunar month", "time", 29.530588861 * 86400, "d",
  ["lunarmonth", "lunarmonths", "lunation", "lunations", "synodicmonth", "synodicmonths"],
  ["lunar month", "lunar months"]);

addUnit("keV", "energy", 1.602176634e-16, "J", ["kev", "kiloelectronvolt", "kiloelectronvolts"],
  ["kiloelectronvolt", "kiloelectronvolts"]);
addUnit("MeV", "energy", 1.602176634e-13, "J", ["mev", "megaelectronvolt", "megaelectronvolts"],
  ["megaelectronvolt", "megaelectronvolts"]);
addUnit("GeV", "energy", 1.602176634e-10, "J", ["gev", "gigaelectronvolt", "gigaelectronvolts"],
  ["gigaelectronvolt", "gigaelectronvolts"]);
addUnit("TeV", "energy", 1.602176634e-7, "J", ["tev", "teraelectronvolt", "teraelectronvolts"],
  ["teraelectronvolt", "teraelectronvolts"]);
// The ton of TNT is DEFINED as 4.184e9 J, which is what makes it a unit and
// not a guess about an explosive.
addUnit("TNT", "energy", 4.184e9, "GJ", ["tnt", "tontnt", "tonstnt", "tonoftnt", "tonsoftnt"],
  ["ton of TNT", "tons of TNT"]);
addUnit("kt TNT", "energy", 4.184e12, "GJ",
  ["kttnt", "kilotontnt", "kilotonstnt", "kilotonoftnt", "kilotonsoftnt"],
  ["kiloton of TNT", "kilotons of TNT"]);
addUnit("Mt TNT", "energy", 4.184e15, "GJ",
  ["mttnt", "megatontnt", "megatonstnt", "megatonoftnt", "megatonsoftnt"],
  ["megaton of TNT", "megatons of TNT"]);
addUnit("toe", "energy", 4.1868e10, "GJ", ["toe", "tonneofoilequivalent", "tonnesofoilequivalent"],
  ["tonne of oil equivalent", "tonnes of oil equivalent"]);
addUnit("boe", "energy", 6.1178632e9, "GJ", ["boe", "barrelofoilequivalent", "barrelsofoilequivalent"],
  ["barrel of oil equivalent", "barrels of oil equivalent"]);
addUnit("gge", "energy", 33.7 * 3.6e6, "kWh", ["gge", "gasolinegallonequivalent", "gallonofgasoline", "gallonsofgasoline"],
  ["gallon of gasoline equivalent", "gallons of gasoline equivalent"]);
addUnit("foe", "energy", 1e44, "J", ["foe", "foes"], ["foe", "foes"]);

addUnit("MW", "power", 1e6, "hp", ["megawatt", "megawatts"], ["megawatt", "megawatts"]);
addUnit("BTU/h", "power", 1055.05585262 / 3600, "W", ["btu/h", "btu/hr", "btuh", "btuhr", "btuperhour"],
  ["BTU per hour", "BTU per hour"]);
addUnit("tonref", "power", 12000 * 1055.05585262 / 3600, "kW",
  ["tonref", "tonofrefrigeration", "tonsofrefrigeration", "refrigerationton", "refrigerationtons"],
  ["ton of refrigeration", "tons of refrigeration"]);
addUnit("Lsun", "power", 3.828e26, "W", ["lsun", "solarluminosity", "solarluminosities"],
  ["solar luminosity", "solar luminosities"]);

// "c" is the Celsius alias, so the speed of light is only ever spelled out.
addUnit("speed of light", "speed", 299792458, "km/h", ["lightspeed", "speedoflight", "speedsoflight"],
  ["speed of light", "speeds of light"]);

addUnit("kN", "force", 1000, "lbf", ["kilonewton", "kilonewtons"], ["kilonewton", "kilonewtons"]);

addUnit("mas", "angle", 1 / 3.6e6, "arcsec", ["mas", "milliarcsecond", "milliarcseconds"],
  ["milliarcsecond", "milliarcseconds"]);
addUnit("mrad", "angle", 57.29577951308232 / 1000, "deg", ["mrad", "milliradian", "milliradians"],
  ["milliradian", "milliradians"]);

addUnit("EiB", "data", 1152921504606846976, "PiB", ["eib", "exbibyte", "exbibytes"],
  ["exbibyte", "exbibytes"]);
addUnit("ZB", "data", 1e21, "EB", ["zb", "zettabyte", "zettabytes"], ["zettabyte", "zettabytes"]);
addUnit("YB", "data", 1e24, "ZB", ["yb", "yottabyte", "yottabytes"], ["yottabyte", "yottabytes"]);

// Fuel economy is quoted in litres per 100 km everywhere but the US, and it is
// the reciprocal of km per litre, which is why the row carries the recip flag.
addUnit("l/100km", "fuel", 100, "mpg",
  ["l/100km", "l/100kilometers", "l/100kilometres", "lper100km", "literper100km", "litersper100km",
    "litresper100km", "literper100kilometers", "litersper100kilometers", "litresper100kilometres"],
  ["litre per 100 kilometres", "litres per 100 kilometres"], { recip: true });

addUnit("g/dL", "concentration", 10, "g/L", ["g/dl", "gramsperdeciliter", "gramsperdecilitre"],
  ["gram per decilitre", "grams per decilitre"]);
addUnit("mg/mL", "concentration", 1, "g/L", ["mg/ml", "milligramspermilliliter", "milligramspermillilitre"],
  ["milligram per millilitre", "milligrams per millilitre"]);
addUnit("ng/mL", "concentration", 1e-6, "ug/mL", ["ng/ml", "nanogramspermilliliter", "nanogramspermillilitre"],
  ["nanogram per millilitre", "nanograms per millilitre"]);
addUnit("ug/L", "concentration", 1e-6, "mg/L", ["ug/l", "microgramsperliter", "microgramsperlitre"],
  ["microgram per litre", "micrograms per litre"]);

addUnit("bp", "fraction", 1e-4, "%", ["bp", "bip", "bips", "basispoint", "basispoints"],
  ["basis point", "basis points"]);

addUnit("l/s", "flow", 3.6, "m3/h", ["l/s", "literpersecond", "literspersecond", "litrepersecond", "litrespersecond"],
  ["litre per second", "litres per second"]);
addUnit("m3/s", "flow", 3600, "m3/h",
  ["m3/s", "m^3/s", "cubicmeterpersecond", "cubicmeterspersecond", "cubicmetrepersecond", "cubicmetrespersecond"],
  ["cubic metre per second", "cubic metres per second"]);
addUnit("ml/min", "flow", 6e-5, "l/min",
  ["ml/min", "milliliterperminute", "millilitersperminute", "millilitreperminute", "millilitresperminute"],
  ["millilitre per minute", "millilitres per minute"]);
addUnit("l/h", "flow", 0.001, "l/min",
  ["l/h", "l/hr", "literperhour", "litersperhour", "litreperhour", "litresperhour"],
  ["litre per hour", "litres per hour"]);
addUnit("bpd", "flow", 0.158987294928 / 24, "m3/h", ["bpd", "bbl/d", "barrelperday", "barrelsperday"],
  ["barrel per day", "barrels per day"]);

addUnit("yd3", "volume", 764.554857984, "m3", ["yd3", "yd^3", "cubicyard", "cubicyards", "cuyd"],
  ["cubic yard", "cubic yards"]);
addUnit("km3", "volume", 1e12, "m3",
  ["km3", "km^3", "cubickilometer", "cubickilometers", "cubickilometre", "cubickilometres"],
  ["cubic kilometre", "cubic kilometres"]);

// Density, which the table had no dimension for. g/L stays under concentration.
addUnit("kg/m3", "density", 1, "g/cm3",
  ["kg/m3", "kg/m^3", "kilogramspercubicmeter", "kilogramspercubicmetre"],
  ["kilogram per cubic metre", "kilograms per cubic metre"]);
addUnit("g/cm3", "density", 1000, "kg/m3",
  ["g/cm3", "g/cm^3", "g/cc", "g/ml", "gramspercubiccentimeter", "gramspercubiccentimetre"],
  ["gram per cubic centimetre", "grams per cubic centimetre"]);
addUnit("lb/ft3", "density", 0.45359237 / 0.028316846592, "kg/m3",
  ["lb/ft3", "lb/ft^3", "lbs/ft3", "poundspercubicfoot"],
  ["pound per cubic foot", "pounds per cubic foot"]);
addUnit("lb/gal", "density", 0.45359237 / 0.003785411784, "kg/m3",
  ["lb/gal", "lbs/gal", "poundspergallon"], ["pound per gallon", "pounds per gallon"]);
addUnit("lb/in3", "density", 0.45359237 / 0.000016387064, "g/cm3",
  ["lb/in3", "lb/in^3", "poundspercubicinch"], ["pound per cubic inch", "pounds per cubic inch"]);

// Acceleration. The "g" of gravity is not an alias: it is the gram.
addUnit("m/s2", "acceleration", 1, "gforce",
  ["m/s2", "m/s^2", "mps2", "meterpersecondsquared", "meterspersecondsquared", "metrepersecondsquared"],
  ["metre per second squared", "metres per second squared"]);
addUnit("ft/s2", "acceleration", 0.3048, "m/s2", ["ft/s2", "ft/s^2", "footpersecondsquared", "feetpersecondsquared"],
  ["foot per second squared", "feet per second squared"]);
addUnit("gforce", "acceleration", 9.80665, "m/s2", ["gforce", "gforces", "standardgravity", "gee", "gees"],
  ["g-force", "g-force"]);

// Data rate, in bits per second. Case is the whole story here (Mb/s is a
// megabit, MB/s a megabyte), so the capitalised spellings are in CASE_OVERRIDE
// and a lowercase "mb/s" keeps the byte reading, as "mb" does.
addUnit("bps", "datarate", 1, "B/s", ["bps", "bit/s", "bitpersecond", "bitspersecond"],
  ["bit per second", "bits per second"]);
addUnit("kbps", "datarate", 1e3, "KB/s", ["kbps", "kbit/s", "kilobitpersecond", "kilobitspersecond"],
  ["kilobit per second", "kilobits per second"]);
addUnit("Mbps", "datarate", 1e6, "MB/s", ["mbps", "mbit/s", "megabitpersecond", "megabitspersecond"],
  ["megabit per second", "megabits per second"]);
addUnit("Gbps", "datarate", 1e9, "MB/s", ["gbps", "gbit/s", "gigabitpersecond", "gigabitspersecond"],
  ["gigabit per second", "gigabits per second"]);
addUnit("Tbps", "datarate", 1e12, "GB/s", ["tbps", "tbit/s", "terabitpersecond", "terabitspersecond"],
  ["terabit per second", "terabits per second"]);
addUnit("B/s", "datarate", 8, "bps", ["b/s", "bytepersecond", "bytespersecond"],
  ["byte per second", "bytes per second"]);
addUnit("KB/s", "datarate", 8e3, "kbps", ["kb/s", "kilobytepersecond", "kilobytespersecond"],
  ["kilobyte per second", "kilobytes per second"]);
addUnit("MB/s", "datarate", 8e6, "Mbps", ["mb/s", "megabytepersecond", "megabytespersecond"],
  ["megabyte per second", "megabytes per second"]);
addUnit("GB/s", "datarate", 8e9, "Gbps", ["gb/s", "gigabytepersecond", "gigabytespersecond"],
  ["gigabyte per second", "gigabytes per second"]);
addUnit("KiB/s", "datarate", 8192, "KB/s", ["kib/s", "kibibytepersecond", "kibibytespersecond"],
  ["kibibyte per second", "kibibytes per second"]);
addUnit("MiB/s", "datarate", 8388608, "MB/s", ["mib/s", "mebibytepersecond", "mebibytespersecond"],
  ["mebibyte per second", "mebibytes per second"]);
addUnit("GiB/s", "datarate", 8589934592, "GB/s", ["gib/s", "gibibytepersecond", "gibibytespersecond"],
  ["gibibyte per second", "gibibytes per second"]);

// Counts. Short-scale billion, because that is what an English query means.
// The base row exists so that a count can be asked for in plain items.
addUnit("item", "count", 1, "dozen", ["item", "items", "piece", "pieces", "pcs", "each", "sheet", "sheets"],
  ["item", "items"]);
addUnit("pair", "count", 2, "item", ["pair", "pairs"], ["pair", "pairs"]);
addUnit("dozen", "count", 12, "item", ["dozen", "dozens"], ["dozen", "dozen"]);
addUnit("baker's dozen", "count", 13, "dozen", ["bakersdozen", "bakersdozens", "baker'sdozen", "baker'sdozens"],
  ["baker's dozen", "baker's dozens"]);
addUnit("score", "count", 20, "dozen", ["score", "scores"], ["score", "score"]);
addUnit("quire", "count", 25, "item", ["quire", "quires"], ["quire", "quires"]);
addUnit("ream", "count", 500, "quire", ["ream", "reams"], ["ream", "reams"]);
addUnit("gross", "count", 144, "dozen", ["gross", "grosses"], ["gross", "gross"]);
addUnit("great gross", "count", 1728, "gross", ["greatgross", "greatgrosses"], ["great gross", "great gross"]);
addUnit("thousand", "count", 1e3, "item", ["thousand", "thousands"], ["thousand", "thousand"]);
addUnit("myriad", "count", 1e4, "thousand", ["myriad", "myriads"], ["myriad", "myriads"]);
addUnit("lakh", "count", 1e5, "thousand", ["lakh", "lakhs"], ["lakh", "lakh"]);
addUnit("million", "count", 1e6, "thousand", ["million", "millions"], ["million", "million"]);
addUnit("crore", "count", 1e7, "million", ["crore", "crores"], ["crore", "crore"]);
addUnit("billion", "count", 1e9, "million", ["billion", "billions"], ["billion", "billion"]);
addUnit("trillion", "count", 1e12, "billion", ["trillion", "trillions"], ["trillion", "trillion"]);
addUnit("googol", "count", 1e100, "trillion", ["googol", "googols"], ["googol", "googols"]);

SUGGEST.density = ["kg/m3", "g/cm3", "lb/ft3", "lb/gal"];
SUGGEST.acceleration = ["m/s2", "gforce", "ft/s2"];
SUGGEST.datarate = ["Mbps", "MB/s", "Gbps", "GB/s", "kbps", "KB/s", "MiB/s"];
SUGGEST.count = ["item", "dozen", "gross", "score", "pair", "thousand", "million"];

// --- the silly ones ---------------------------------------------------------
// Nothing below is a standard. Each row is one round, defensible number for a
// thing people really do compare to ("the size of three football fields"), the
// source of the number is in the comment, and none of them is reachable from a
// bare query: they are what you get by naming them.
//
// A word means one dimension. A football field is an area here, not a length,
// so "3 football fields in acres" works and "100 football fields in km" is
// refused as incompatible, which is the honest answer.
// Names are written the way a query is: no spaces, the multiword ones are
// tokens the parser joins ("blue whale" -> bluewhale).

// length
addUnit("banana", "length", 0.178, "cm", ["banana", "bananas"], ["banana", "bananas"]);       // 7 in, for scale
addUnit("smoot", "length", 1.7018, "ft", ["smoot", "smoots"], ["smoot", "smoots"]);           // 5 ft 7 in, Harvard Bridge
addUnit("beard-second", "length", 5e-9, "nm", ["beardsecond", "beardseconds"],
  ["beard-second", "beard-seconds"]);                                                         // 5 nm, what a beard grows in a second
addUnit("barleycorn", "length", 0.0254 / 3, "mm", ["barleycorn", "barleycorns"], ["barleycorn", "barleycorns"]);
addUnit("furlong", "length", 201.168, "mi", ["furlong", "furlongs"], ["furlong", "furlongs"]);
addUnit("chain", "length", 20.1168, "ft", ["chain", "chains"], ["chain", "chains"]);
addUnit("rod", "length", 5.0292, "ft", ["rod", "rods", "perch", "perches", "pole", "poles"], ["rod", "rods"]);
addUnit("league", "length", 4828.032, "km", ["league", "leagues"], ["league", "leagues"]);  // 3 statute miles
addUnit("cubit", "length", 0.4572, "cm", ["cubit", "cubits"], ["cubit", "cubits"]);         // 18 in
addUnit("marathon", "length", 42195, "km", ["marathon", "marathons"], ["marathon", "marathons"]);
addUnit("eiffel tower", "length", 330, "ft", ["eiffeltower", "eiffeltowers"],
  ["Eiffel Tower", "Eiffel Towers"]);                                                         // with antennas
addUnit("empire state building", "length", 443.2, "ft", ["empirestatebuilding", "empirestatebuildings"],
  ["Empire State Building", "Empire State Buildings"]);                                       // with antenna
addUnit("statue of liberty", "length", 93, "ft", ["statueofliberty", "statuesofliberty"],
  ["Statue of Liberty", "Statues of Liberty"]);                                               // ground to torch
addUnit("burj khalifa", "length", 828, "ft", ["burjkhalifa", "burjkhalifas"],
  ["Burj Khalifa", "Burj Khalifas"]);
addUnit("everest", "length", 8848.86, "ft", ["everest", "everests", "mounteverest", "mounteverests"],
  ["Mount Everest", "Mount Everests"]);
addUnit("credit card", "length", 0.0856, "mm", ["creditcard", "creditcards"],
  ["credit card", "credit cards"]);                                                           // ISO/IEC 7810 ID-1 length
addUnit("hair", "length", 7e-5, "um", ["hair", "hairs", "humanhair", "humanhairs"],
  ["human hair", "human hairs"]);                                                             // about 70 um wide
addUnit("equator", "length", 40075017, "mi", ["equator", "equators", "earthcircumference", "earthcircumferences"],
  ["Earth circumference", "Earth circumferences"]);

// mass
addUnit("elephant", "mass", 6000, "lb", ["elephant", "elephants"], ["elephant", "elephants"]);        // adult African bull
addUnit("blue whale", "mass", 150000, "elephant", ["bluewhale", "bluewhales"], ["blue whale", "blue whales"]);
addUnit("human", "mass", 62, "lb", ["human", "humans"], ["human", "humans"]);                         // world adult average
addUnit("cat", "mass", 4.5, "lb", ["cat", "cats"], ["cat", "cats"]);
addUnit("penny", "mass", 0.0025, "g", ["penny", "pennies"], ["penny", "pennies"]);                    // US cent
addUnit("nickel", "mass", 0.005, "g", ["nickel", "nickels"], ["nickel", "nickels"]);
addUnit("dime", "mass", 0.002268, "g", ["dime", "dimes"], ["dime", "dimes"]);
addUnit("grain of rice", "mass", 2e-5, "mg", ["grainofrice", "grainsofrice"], ["grain of rice", "grains of rice"]);
addUnit("paperclip", "mass", 0.001, "g", ["paperclip", "paperclips"], ["paperclip", "paperclips"]);
addUnit("stick of butter", "mass", 4 * 0.028349523125, "g", ["stickofbutter", "sticksofbutter"],
  ["stick of butter", "sticks of butter"]);                                                           // 4 oz

// time
addUnit("microfortnight", "time", 1.2096, "s", ["microfortnight", "microfortnights"],
  ["microfortnight", "microfortnights"]);
addUnit("nanocentury", "time", 3.1536, "s", ["nanocentury", "nanocenturies"],
  ["nanocentury", "nanocenturies"]);                                                                  // about pi seconds
addUnit("shake", "time", 1e-8, "ns", ["shake", "shakes"], ["shake", "shakes"]);                       // 10 ns, nuclear physics
addUnit("moment", "time", 90, "s", ["moment", "moments"], ["moment", "moments"]);                     // medieval: 1/40 hour
addUnit("heartbeat", "time", 0.8, "ms", ["heartbeat", "heartbeats"], ["heartbeat", "heartbeats"]);
addUnit("age of the universe", "time", 13.787e9 * 31536000, "Gyr", ["ageoftheuniverse", "universeage"],
  ["age of the universe", "ages of the universe"]);                                                   // Planck 2018, in this table's years

// energy
addUnit("hiroshima", "energy", 15 * 4.184e12, "kt TNT", ["hiroshima", "hiroshimas", "littleboy"],
  ["Hiroshima bomb", "Hiroshima bombs"]);                                                             // about 15 kt
addUnit("tsar bomba", "energy", 50 * 4.184e15, "Mt TNT", ["tsarbomba", "tsarbombas"],
  ["Tsar Bomba", "Tsar Bombas"]);                                                                     // 50 Mt
addUnit("lightning bolt", "energy", 1e9, "kWh", ["lightningbolt", "lightningbolts"],
  ["lightning bolt", "lightning bolts"]);                                                             // about 1 GJ
addUnit("big mac", "energy", 563 * 4184, "kcal", ["bigmac", "bigmacs"], ["Big Mac", "Big Macs"]);      // 563 kcal, US

// power
addUnit("jigawatt", "power", 1.21e9, "GW", ["jigawatt", "jigawatts"], ["jigawatt", "jigawatts"]);

// speed
addUnit("snail pace", "speed", 0.013, "mph", ["snail", "snails", "snailpace", "snailpaces"],
  ["snail pace", "snail paces"]);                                                                     // garden snail
addUnit("usain bolt", "speed", 12.42, "mph", ["usainbolt", "usainbolts"], ["Usain Bolt", "Usain Bolts"]);
addUnit("cheetah", "speed", 29, "mph", ["cheetah", "cheetahs"], ["cheetah", "cheetahs"]);
addUnit("escape velocity", "speed", 11186, "km/h",
  ["escapevelocity", "escapevelocities", "earthescapevelocity", "earthescapevelocities"],
  ["Earth escape velocity", "Earth escape velocities"]);
addUnit("iss", "speed", 7660, "km/h", ["iss", "issspeed"], ["ISS orbital speed", "ISS orbital speeds"]);

// volume
addUnit("olympic pool", "volume", 2.5e6, "m3",
  ["olympicpool", "olympicpools", "olympicswimmingpool", "olympicswimmingpools"],
  ["Olympic swimming pool", "Olympic swimming pools"]);                                               // 50 x 25 x 2 m
addUnit("soda can", "volume", 12 * 0.0295735295625, "ml", ["sodacan", "sodacans"], ["soda can", "soda cans"]);
addUnit("wine bottle", "volume", 0.75, "ml", ["winebottle", "winebottles"], ["wine bottle", "wine bottles"]);
addUnit("magnum", "volume", 1.5, "l", ["magnum", "magnums"], ["magnum", "magnums"]);
addUnit("jeroboam", "volume", 3, "l", ["jeroboam", "jeroboams"], ["jeroboam", "jeroboams"]);
addUnit("methuselah", "volume", 6, "l", ["methuselah", "methuselahs"], ["methuselah", "methuselahs"]);
addUnit("nebuchadnezzar", "volume", 15, "l", ["nebuchadnezzar", "nebuchadnezzars"],
  ["nebuchadnezzar", "nebuchadnezzars"]);
addUnit("keg", "volume", 15.5 * 3.785411784, "gal", ["keg", "kegs"], ["keg", "kegs"]);                // US half barrel
addUnit("hogshead", "volume", 63 * 3.785411784, "gal", ["hogshead", "hogsheads"], ["hogshead", "hogsheads"]);
addUnit("firkin", "volume", 9 * 4.54609, "ukgal", ["firkin", "firkins"], ["firkin", "firkins"]);      // 9 imperial gallons
addUnit("shot", "volume", 1.5 * 0.0295735295625, "ml", ["shot", "shots"], ["shot", "shots"]);         // 1.5 US fl oz
addUnit("dash", "volume", 0.00492892159375 / 8, "ml", ["dash", "dashes"], ["dash", "dashes"]);        // 1/8 tsp
addUnit("pinch", "volume", 0.00492892159375 / 16, "ml", ["pinch", "pinches"], ["pinch", "pinches"]);  // 1/16 tsp
addUnit("smidgen", "volume", 0.00492892159375 / 32, "ml", ["smidgen", "smidgens"], ["smidgen", "smidgens"]);
addUnit("drop", "volume", 5e-5, "ml", ["drop", "drops"], ["drop", "drops"]);                          // 20 drops per ml
addUnit("lake superior", "volume", 1.21e16, "km3", ["lakesuperior", "lakesuperiors"],
  ["Lake Superior", "Lake Superiors"]);                                                               // 12,100 km3

// area
addUnit("football field", "area", 57600 * 0.09290304, "ac",
  ["footballfield", "footballfields", "americanfootballfield", "americanfootballfields"],
  ["football field", "football fields"]);                                                             // 360 x 160 ft with end zones
addUnit("tennis court", "area", 2808 * 0.09290304, "ft2", ["tenniscourt", "tenniscourts"],
  ["tennis court", "tennis courts"]);                                                                 // doubles, 78 x 36 ft
addUnit("soccer pitch", "area", 7140, "ac", ["soccerpitch", "soccerpitches", "footballpitch", "footballpitches"],
  ["soccer pitch", "soccer pitches"]);                                                                // 105 x 68 m
addUnit("wales", "area", 2.0779e10, "km2", ["wales"], ["Wales", "Wales"]);
addUnit("texas", "area", 6.95662e11, "km2", ["texas"], ["Texas", "Texas"]);
addUnit("belgium", "area", 3.0689e10, "km2", ["belgium"], ["Belgium", "Belgium"]);
addUnit("rhode island", "area", 4.001e9, "km2", ["rhodeisland"], ["Rhode Island", "Rhode Island"]);
addUnit("central park", "area", 843 * 4046.8564224, "ha", ["centralpark", "centralparks"],
  ["Central Park", "Central Parks"]);                                                                 // 843 acres

// data
addUnit("nibble", "data", 0.5, "bit", ["nibble", "nibbles"], ["nibble", "nibbles"]);
addUnit("floppy", "data", 1474560, "KB", ["floppy", "floppies", "floppydisk", "floppydisks"],
  ["floppy disk", "floppy disks"]);                                                                   // 2880 x 512 B
addUnit("cdrom", "data", 737280000, "MB", ["cdrom", "cdroms"], ["CD-ROM", "CD-ROMs"]);               // 80 min, mode 1
addUnit("dvd", "data", 4707319808, "GB", ["dvd", "dvds"], ["DVD", "DVDs"]);                           // single layer
addUnit("bluray", "data", 25025314816, "GB", ["bluray", "blurays"], ["Blu-ray disc", "Blu-ray discs"]);

// acceleration
addUnit("moon gravity", "acceleration", 1.62, "m/s2", ["moongravity", "lunargravity"],
  ["lunar gravity", "lunar gravities"]);
addUnit("mars gravity", "acceleration", 3.71, "m/s2", ["marsgravity"], ["Martian gravity", "Martian gravities"]);

// The symbol -> noun lookup, flattened out of UNIT_NOUN's dimension grouping.
// The grouping is for the reader; the answer only ever needs the symbol.
var UNIT_WORD = null;

// A unit as a sentence wants it: the right number form, and nothing else. A
// unit name is a common noun and reads down - "5 metres is 500 centimetres",
// "3600 joules is 0.001 kilowatt-hours" - so there is no capitalising step here
// at all, and every name in the table above is stored the way it prints. A
// currency is the opposite case: it is a proper noun, so FxLib title-cases it.
// That difference is the reason this is not the same function twice.
function unitWord(sym, value) {
  if (UNIT_WORD === null) {
    UNIT_WORD = {};
    for (var d in UNIT_NOUN) {
      var group = UNIT_NOUN[d];
      for (var s in group) {
        if (Object.prototype.hasOwnProperty.call(group, s)) UNIT_WORD[s] = group[s];
      }
    }
  }
  var pair = UNIT_WORD[sym];
  if (pair === undefined) return String(sym);
  return Math.abs(value) === 1 ? pair[0] : pair[1];
}

// One conversion as a sentence, which is what the row's sub line says:
// "3600 joules is 0.001 kilowatt-hours". The label stays the compact
// "3600 J = 0.001 kWh" - the two are the same fact at two reading speeds, and
// the sub is the one meant to be read rather than scanned.
//
// A noun that opens with the degree sign needs nothing special here: the sign
// binds to the name and the ordinary space separates the value from the noun,
// which is what "100 \u00b0Celsius" is.
function phrase(value, fromSym, out, toSym) {
  return formatNumber(value) + " " + unitWord(fromSym, value)
    + " is " + formatNumber(out) + " " + unitWord(toSym, out);
}

// A symbol as the label and the clipboard want it: abbreviations stay symbols
// ("10 mi", "5 m"), while a unit named by its own word pluralizes
// ("5 bananas", not "5 banana"). The sub line already spells every unit out
// through unitWord; the compact forms had no plural at all, which is what
// made a plural query read back in the singular.
function displaySym(sym, value) {
  var pair = UNIT_WORD !== null ? UNIT_WORD[sym] : undefined;
  if (pair === undefined) {
    unitWord(sym, value);
    pair = UNIT_WORD[sym];
  }
  if (pair === undefined || pair === null) return String(sym);
  if (pair[0] !== sym) return String(sym);
  return unitWord(sym, value);
}

// Case-sensitive overrides, consulted before the alias table. normalizeUnit
// folds case, and a food "Cal" is a kilocalorie, so reading it as a calorie
// is out by a factor of a thousand. Only the unit token reaches this table,
// which is why the number the user typed is never rewritten.
//
// The rest of the table is the same trap at other scales, where the folded
// spelling is a different unit by a factor of a million or more: "MW" would be
// a milliwatt, "Mm" a millimetre, "kN" a knot, "Mg" a milligram, and "Mb" a
// megabyte instead of the megabit it is spelled as. Each one names the unit
// that the capitalisation says. The lowercase spelling keeps its own reading
// ("mb" is still the megabyte), so nothing that worked changes.
var CASE_OVERRIDE = {
  "Cal": "kcal", "CAL": "kcal", "Calorie": "kcal", "Calories": "kcal",
  "MW": "megawatt", "Mm": "megameter", "Mg": "tonne", "kN": "kilonewton",
  "Kb": "kbit", "Mb": "mbit", "Gb": "gbit", "Tb": "tbit",
  "Kb/s": "kbps", "Mb/s": "mbps", "Gb/s": "gbps", "Tb/s": "tbps",
  "kBps": "kb/s", "KBps": "kb/s", "MBps": "mb/s", "GBps": "gb/s"
};

var _aliasMap = null;

function aliasMap() {
  if (_aliasMap !== null) return _aliasMap;
  var m = {};
  for (var i = 0; i < UNITS.length; i++) {
    for (var j = 0; j < UNITS[i].names.length; j++) {
      m[UNITS[i].names[j]] = UNITS[i];
    }
  }
  _aliasMap = m;
  return m;
}

// The typed power of a unit that is usually written with a superscript.
var SUPERSCRIPT = { "\u00b9": "^1", "\u00b2": "^2", "\u00b3": "^3" };

// Lowercase, drop spaces/underscores/dashes so "fluid ounces"
// hits "fluidounces"; keep "/", "^" and quotes (m/s, m^2, ").
// Then transliterate the spellings a keyboard cannot reach on its own: both
// mu letters become "u" so a typed micro sign is the micrometre, the
// superscript digits become "^1".."^3" so a squared metre is m2, a degree sign
// in front of a temperature scale is dropped so a typed degree-C is C, and a
// latin small letter a with ring becomes "angstrom" so a typed angstrom sign
// is the angstrom. Folding runs first, so the ring letter is lower case when
// it is replaced.
//
// A degree sign that is NOT in front of a scale is the angle and stays, as a
// character of its own. Dropping it everywhere fused it with whatever word
// followed once the spaces went: "90 deg in rad" is split at the keyword, the
// head is retried as "90 deg in", and "deg in" with the sign gone was the inch.
// A "sq." or "cu." prefix loses its dot for the same reason a trailing one does.
function normalizeUnit(s) {
  var t = String(s === undefined || s === null ? "" : s).toLowerCase().trim();
  t = t.replace(/\u00b0\s*(?=(?:c|f|k|r|re|celsius|fahrenheit|kelvin|rankine|reaumur|r\u00e9aumur)\.*$)/, "");
  t = t.replace(/[_-]+/g, "");
  t = t.replace(/\s+/g, "");
  t = t.replace(/\.+$/g, "");
  t = t.replace(/^(sq|cu)\./, "$1");
  t = t.replace(/[\u00b5\u03bc]/g, "u");
  t = t.replace(/[\u00b9\u00b2\u00b3]/g, function (c) { return SUPERSCRIPT[c]; });
  t = t.replace(/\u00e5/g, "angstrom");
  return t;
}

function lookup(key) {
  var n = normalizeUnit(key);
  if (n === "") return null;
  var m = aliasMap();
  return Object.prototype.hasOwnProperty.call(m, n) ? m[n] : null;
}

// One unit token as the user typed it: the case-sensitive override first, the
// folded alias table second.
function unitFor(token) {
  var t = String(token === undefined || token === null ? "" : token).trim();
  if (Object.prototype.hasOwnProperty.call(CASE_OVERRIDE, t)) return lookup(CASE_OVERRIDE[t]);
  return lookup(t);
}

var _symMap = null;

// A symbol as the table spells it. The alias table folds case, so "MW" and
// "mW" are the same key there; every internal reference (a default, a
// shortlist entry) is a SYMBOL and has to mean the unit that owns it, so it is
// matched exactly first and only then by the folded spelling ("kB" is not a
// symbol, and is still the kilobyte).
function symLookup(sym) {
  if (_symMap === null) {
    _symMap = {};
    for (var i = 0; i < UNITS.length; i++) _symMap[UNITS[i].sym] = UNITS[i];
  }
  if (Object.prototype.hasOwnProperty.call(_symMap, sym)) return _symMap[sym];
  return lookup(sym);
}

// "1.500000e+13" -> "1.5e+13", "2.000000e+13" -> "2e+13".
function trimExp(e) {
  return e.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
}

// Same rounding as CalcLib.formatResult: integers plain, floats
// trimmed to 10dp, extremes in trimmed exponential form.
function formatNumber(v) {
  if (typeof v !== "number" || isNaN(v)) return "NaN";
  if (!isFinite(v)) return v > 0 ? "Infinity" : "-Infinity";
  if (v % 1 === 0) {
    if (v === 0) v = 0;
    // Past 1e15 a float is an integer only because it ran out of mantissa, and
    // printing every digit shows rounding noise as if it were a measurement
    // ("1 pc in m" is not 30856775814913670 of anything).
    if (Math.abs(v) < 1e15) return String(v);
    return trimExp(v.toExponential(6));
  }
  var abs = Math.abs(v);
  if (abs !== 0 && (abs >= 1e12 || abs < 1e-6)) return trimExp(v.toExponential(6));
  // toPrecision switches to exponent form at 1e6, which printed 1610953.344
  // as "1.61095e+6" while the integer 1609344 printed in full. Between there
  // and 1e12 a whole number is the readable answer.
  if (abs >= 999999.5) return String(Math.round(v));
  // At most 6 significant digits: "20cm" reads "7.87402 in" while
  // exact-looking results ("402.336", "2.20462") are untouched.
  var s = v.toPrecision(6);
  if (s.indexOf("e") >= 0 || s.indexOf("E") >= 0) {
    return s.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
  }
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "");
  if (s === "-0") s = "0";
  if (s === "") s = "0";
  return s;
}

// Every scale reaches Celsius, and an unknown symbol is the identity. A
// kelvin reading is what the unphysical guard compares, so the two extra
// scales are covered by the floor for free.
function toCelsius(v, sym) {
  if (sym === "F") return (v - 32) * 5 / 9;
  if (sym === "K") return v - 273.15;
  if (sym === "R") return (v - 491.67) * 5 / 9;
  if (sym === "Re") return v * 5 / 4;
  return v;
}

function fromCelsius(c, sym) {
  if (sym === "F") return c * 9 / 5 + 32;
  if (sym === "K") return c + 273.15;
  if (sym === "R") return c * 9 / 5 + 491.67;
  if (sym === "Re") return c * 4 / 5;
  return c;
}

// A leading number with optional thousands grouping, an optional leading
// decimal point (".5" and "0.5" are both typed) and an optional exponent.
// The grouping form is the currency engine's, so "1,000 km" parses here for
// the same reason "1,000 usd" parses there. The written form, commas
// included, is what the label echoes. The fraction carries a bare "." as its
// second alternative because "5.mm" is five millimetres typed with the dot of
// a decimal that has no digits behind it; the dot has to be consumed as part
// of the number, since normalizeUnit keeps a leading one and ".mm" is not a
// unit. The digits-first order inside it is what keeps "2.5" a decimal.
var RE_NUM = /^[+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+|\.)?|\.\d+)(?:e[+-]?\d+)?/i;

// An unpadded arrow. The pattern needs a ">", so a leading minus on a value
// is untouched and "-5 m in cm" keeps its sign.
var RE_ARROW = /\s*-+\s*>\s*/g;

// A leading filler word from a closed set. Any longer prefix of one of these
// would be a unit name waiting to be swallowed.
var RE_FILLER = /^(?:convert|calculate|calc|what is|what's|whats|what was|how many|how much)\s+/i;

// The two inverted question forms, both rewritten into the canonical shape:
// "how many km in 5 mi" and "5 km is how many miles" become "5 mi in km" and
// "5 km in miles". They are matched ahead of the filler strip because "how
// many" is itself a filler word, and stripping it first would leave the
// question half answered. "how much is 5 kg in lb" names the quantity before
// the unit, so its captures swap: the target is the one behind the keyword.
var RE_ASK_LAST = /^how (?:many|much) (.+?) (?:in|to|as|->|=) (.+)$/i;
var RE_ASK_IS = /^how (?:many|much) (?:is|are) (.+?) (?:in|to|as|->|=) (.+)$/i;
var RE_ASK_FIRST = /^(.+?) (?:is|are) how (?:many|much) (.+)$/i;

var RE_POLITE = /\s+(?:please|pls)\b[\s?!]*$/i;
var RE_TAIL = /[?!]+$/;

// The trailing politeness and punctuation. A quote is never in this pattern:
// it is the inch and the foot.
function stripTail(s) {
  return s.replace(RE_POLITE, "").replace(RE_TAIL, "").trim();
}

// All four rewrites in one place and one order: the arrow first, then the two
// question forms, which return early because their rewrite does not start
// with a filler word, then the filler strip, then the tail.
function preprocess(query) {
  var s = String(query === undefined || query === null ? "" : query).trim();
  s = stripTail(s.replace(RE_ARROW, " -> "));
  // The tail is dropped before the question forms are read, not after: they
  // return early, and a "please" still sitting inside a capture would rewrite
  // to "5 mi please? in km", which is not a query. Once it is gone the
  // rewrites need no tail handling of their own.
  var ask0 = s.match(RE_ASK_IS);
  if (ask0 !== null) return ask0[1] + " in " + ask0[2];
  var ask = s.match(RE_ASK_LAST);
  if (ask !== null) return ask[2] + " in " + ask[1];
  var ask2 = s.match(RE_ASK_FIRST);
  if (ask2 !== null) return ask2[1] + " in " + ask2[2];
  return s.replace(RE_FILLER, "");
}

// Cheap gate for the per-keystroke path: the preprocessed input must start
// with a number and carry a letter-ish unit char. Plain app names
// ("firefox"), pure math ("2+2") and "time in X" all fail here, and so does
// a bare "convert". It is a gate and nothing else - tryConvert calls it, so
// nothing here reaches back into the parser.
function isPotentialUnit(query) {
  var t = preprocess(query);
  if (t === "" || t.length > 128) return false;
  if (t.indexOf("\n") >= 0 || t.indexOf("\r") >= 0) return false;
  if (!RE_NUM.test(t)) return false;
  if (!/[a-zA-Z"'\/\u00b0]/.test(t)) return false;
  return true;
}

// The compact feet-and-inches form, reached only where the scan has already
// failed: "5'10" carries no inch mark and "6' 2in" puts the two numbers on
// one token. The inch group has to be there, because a bare "5'" is one foot
// and the scan resolves that on its own.
var RE_FT_IN = /^(\d+(?:\.\d+)?)\s*'\s*(\d+(?:\.\d+)?)?\s*(?:"|in\b|inch|inches)?$/i;

function parseFeetInches(text) {
  var m = String(text).match(RE_FT_IN);
  if (m === null || m[2] === undefined) return null;
  var table = aliasMap();
  var ft = table["ft"];
  var inch = table["in"];
  if (!ft || !inch) return null;
  return [{ value: Number(m[1]), unit: ft, text: m[1] },
    { value: Number(m[2]), unit: inch, text: m[2] }];
}

function isSpace(ch) {
  return ch === " " || ch === "\t";
}

// One term of a source: a number, whitespace, a unit token that runs to the
// next whitespace. The scan is left to right and has no terminator, so every
// pair it finds is another addend - "6 ft 2 in" is two terms of one length
// and "5m" is the same shape as "5 m". The number is kept as written,
// grouping commas included, because the label echoes what was typed.
function parseSource(text) {
  var s = String(text);
  var terms = [];
  var i = 0;
  while (i < s.length) {
    while (i < s.length && isSpace(s.charAt(i))) i++;
    if (i >= s.length) break;
    var m = s.substring(i).match(RE_NUM);
    if (m === null) return null;
    var written = m[0];
    var value = Number(written.replace(/,/g, ""));
    if (!isFinite(value)) return null;
    i += written.length;
    while (i < s.length && isSpace(s.charAt(i))) i++;
    var j = i;
    while (j < s.length && !isSpace(s.charAt(j))) j++;
    var unit = unitFor(s.substring(i, j));
    var end = j;
    // A name can be more than one word and normalizeUnit drops the spaces,
    // so "degrees celsius" is one alias and "degrees" on its own is a
    // different one. The token grows a word at a time, and a word that
    // resolves nothing of its own is not a reason to stop: "miles per hour"
    // has no resolvable prefix, so the growth passes through "miles per" to
    // reach the whole key. What does end the growth is a resolved key whose
    // remaining text cannot open another term, which is what keeps "6 ft 2 in"
    // at three terms - "ft 2" is the square foot, and "in" behind it is not a
    // number. Only a resolved key moves the term's end, so text that resolved
    // to nothing is scanned again as the next term instead of vanishing into
    // the unit that failed to claim it.
    var scan = end;
    for (var extra = 0; extra < 3 && scan < s.length; extra++) {
      var k = scan;
      while (k < s.length && isSpace(s.charAt(k))) k++;
      var w = k;
      while (w < s.length && !isSpace(s.charAt(w))) w++;
      if (w === k) break;
      scan = w;
      var wider = unitFor(s.substring(i, w));
      if (wider === null) continue;
      var rest = s.substring(w).replace(/^\s+/, "");
      if (rest !== "" && !RE_NUM.test(rest)) break;
      unit = wider;
      end = w;
    }
    if (unit === null) {
      // A bare number behind a length is the inches of a compound the inch
      // mark left off: "5 ft 10". Any other trailing number has no unit and
      // no reading, so it is a null rather than a number that dropped it.
      // Only a foot may lend its inches. "5 m 30" has no such reading, and
      // taking the 30 for inches would be the silent guess this engine never
      // makes.
      var lastTerm = terms.length > 0 ? terms[terms.length - 1].unit : null;
      if (i === j && j >= s.length && lastTerm !== null && lastTerm.sym === "ft") unit = aliasMap()["in"];
      else return null;
    }
    terms.push({ value: value, unit: unit, text: written });
    i = end;
  }
  return terms.length > 0 ? terms : null;
}

// Split "5m in cm" into head/target on the LAST keyword so the inch
// unit "in" in "5 in in cm" still parses (source "in", key "in").
// "into" is safe in the alternation because a split only happens where a
// unit follows the keyword.
function splitExplicit(body) {
  var m = String(body).match(/^(.*)\s+(in|into|to|as|->|=)\s+(.+?)\s*$/i);
  if (m) return { head: m[1], key: m[2], tail: m[3] };
  var mTight = String(body).match(/^(\d+(?:\.\d+)?)(in)\s+(.+?)\s*$/i);
  if (mTight) return { head: mTight[1], key: mTight[2], tail: mTight[3] };
  var m2 = String(body).match(/^(.*)\s+(in|into|to|as|->|=)\s*$/i);
  if (m2) return { head: m2[1], key: m2[2], tail: "" };
  return null;}

var _dimCache = null;

// Every symbol of one dimension, in table order. Cached, because the hint
// asks for the list on a keystroke and the table does not change.
function dimUnits(dim) {
  if (_dimCache === null) {
    _dimCache = {};
    for (var i = 0; i < UNITS.length; i++) {
      if (_dimCache[UNITS[i].dim] === undefined) _dimCache[UNITS[i].dim] = [];
      _dimCache[UNITS[i].dim].push(UNITS[i].sym);
    }
  }
  return _dimCache[dim] === undefined ? [] : _dimCache[dim];
}

// The unknown-target hint offers what the engine can actually convert: the
// source's own default first, then the rest of its dimension in table order.
// Two candidates is the floor for a suggestion list.
function dimHint(from) {
  var syms = dimUnits(from.dim);
  var out = [from.def];
  for (var i = 0; i < syms.length && out.length < 6; i++) {
    if (syms[i] === from.sym || out.indexOf(syms[i]) >= 0) continue;
    out.push(syms[i]);
  }
  return out.length < 2 ? "e.g. 5m in cm" : "did you mean: " + out.join(", ");
}

// "kg is mass, m is length" - naming both dimensions is the whole
// explanation, and it is more use than an example of a pair that cannot be
// converted at all.
function dimNote(a, b) {
  return a.sym + " is " + a.dim + ", " + b.sym + " is " + b.dim;
}

// "6 ft + 2 in": the written number and the canonical symbol of one term.
// A word-named unit keeps its plural ("5 bananas", not "5 banana"); an
// abbreviation stays the symbol ("10 mi", "5 m").
function termText(term) {
  return term.text + " " + displaySym(term.unit.sym, term.value);
}

// One conversion, for the compound sum and for the answer. Temperature goes
// through Celsius; every other dimension goes through its base unit.
//
// A unit with `recip` is the reciprocal of its dimension's base: litres per 100
// km is 100 / (km per litre), so a ratio of factors cannot express it. Its
// `factor` is the numerator of that reciprocal.
function toBase(v, u) {
  return u.recip === true ? u.factor / v : v * u.factor;
}

function fromBase(b, u) {
  return u.recip === true ? u.factor / b : b / u.factor;
}

function convertValue(value, from, to) {
  if (from.dim === "temperature") return fromCelsius(toCelsius(value, from.sym), to.sym);
  return fromBase(toBase(value, from), to);
}

function pickDefault(value, from) {
  var ladder = DEF_LADDER[from.dim];
  if (ladder === undefined) return from.def;
  var i, cand, out;
  if (ladder.pick === "window") {
    for (i = 0; i < ladder.syms.length; i++) {
      cand = symLookup(ladder.syms[i]);
      if (cand === null || cand.sym === from.sym) continue;
      out = convertValue(value, from, cand);
      if (out >= 1 && out < 1000) return cand.sym;
    }
    return from.def;
  }
  var best = null;
  var bestScore = Infinity;
  for (i = 0; i < ladder.syms.length; i++) {
    cand = symLookup(ladder.syms[i]);
    if (cand === null || cand.sym === from.sym) continue;
    out = convertValue(value, from, cand);
    // A reading under a tenth of one is the prefix one step too large, and
    // its log distance would otherwise beat every real answer.
    if (Math.abs(out) < 0.1) continue;
    var score = Math.abs(Math.log10(Math.abs(out)));
    if (score < bestScore) {
      bestScore = score;
      best = cand.sym;
    }
  }
  return best === null ? from.def : best;
}

// The targets a bare query offers, in the order the rows are shown: the
// dimension's own default first, then the shortlist as far as each reading is
// still readable, capped at MAX_TARGETS.
//
// Three things decide membership, and none of them is "the dimension has this
// unit": a candidate whose number is not readable is dropped (5 MB in TB is a
// true answer nobody asked for, and 20 cm in a fraction of a km is the same
// kind of nothing), and two targets that format to the same number are one
// row - the mass table's decigram and decagram both land on 100 for a
// kilogram, and the row is the number the user reads.
//
// The default is not a candidate but a CONTRACT: it is the row a bare query has
// always shown, so no reading bound can drop it and promote a shortlist entry
// in its place. That is also why it survives a query whose every conversion
// overflows, where the checks then report the failure against it.
function pickTargets(value, from) {
  function readable(v) {
    var a = Math.abs(v);
    if (!isFinite(a) || a < MIN_FRACTION) return false;
    var l = Math.log10(a);
    return Math.min(Math.abs(l), Math.abs(l - 3)) < MAX_DECADES;
  }
  var first = pickDefault(value, from);
  var queue = [first];
  var list = SUGGEST[from.dim];
  if (list !== undefined) {
    for (var i = 0; i < list.length; i++) {
      if (queue.indexOf(list[i]) < 0) queue.push(list[i]);
    }
  }
  var out = [];
  var numbers = [];
  for (var j = 0; j < queue.length && out.length < MAX_TARGETS; j++) {
    var cand = symLookup(queue[j]);
    if (cand === null || cand.sym === from.sym) continue;
    var reading = convertValue(value, from, cand);
    if (j > 0 && readable(reading) === false) continue;
    var range = SUGGEST_RANGE[cand.sym];
    if (j > 0 && range !== undefined
        && (Math.abs(reading) < range[0] || Math.abs(reading) > range[1])) continue;
    var text = formatNumber(reading);
    if (numbers.indexOf(text) >= 0) continue;
    numbers.push(text);
    out.push(cand.sym);
  }
  return out.length > 0 ? out : [first];
}

// The query resolved as far as the SOURCE is concerned: its value, its unit,
// the label text, and the target spec the user typed - or a null spec, which
// is what "bare" means here and is what asks for the list. A hint (ok: false)
// is a query this function understood and the checks below will reject
// whatever target it is given, so it travels as a return value rather than as
// a thrown state.
//
// depth is private: the preprocessed string comes back through it, so the
// parse only ever sees preprocessed text and a doubled filler word
// ("convert convert 5 km to mi") has a fixed number of passes to spend.
function parseQuery(query, depth) {
  if (depth === undefined) {
    var pre = preprocess(query);
    if (pre === "" || pre.length > 128 || pre.indexOf("\n") >= 0) return null;
    return parseQuery(pre, 1);
  }
  var raw = String(query);
  if (!isPotentialUnit(raw)) return null;
  var split = splitExplicit(raw);
  var headText = split === null ? raw : split.head;
  var tailText = split === null ? null : split.tail;
  var terms = parseSource(headText);
  // "5 in cm" splits at its only keyword, which leaves "5" as the source and
  // "cm" as the target; the keyword is really the source unit, so the head is
  // retried with it.
  if (terms === null && split !== null) terms = parseSource(headText + " " + split.key);
  if (terms === null) terms = parseFeetInches(headText);
  if (terms === null && split !== null) terms = parseFeetInches(headText + " " + split.key);
  if (terms === null) return null;
  if (tailText === "") {
    // A trailing keyword with no target is mid-typing, unless the keyword was
    // really a unit. "5 m in" is a mid-typing target; "6 ft 2 in" is a
    // compound whose last term is an inch, and read from the head alone it is
    // five square feet and a stray two. A read with more terms is the better
    // one and takes the query whole, so the keyword becomes a unit and the
    // answer is bare; a tie keeps the head, which is what holds "5 m in" at
    // one metre rather than five minutes - "m in" is the minute.
    var joined = split === null ? null : parseSource(headText + " " + split.key);
    if (joined !== null && joined.length > terms.length) {
      terms = joined;
      tailText = null;
    } else if (terms.length > 1 && split !== null && lookup(split.key) !== null) {
      // The head is already a whole compound and the keyword is a unit in its
      // own right, so there is no half-typed target behind it: "5 ft 10 in" is
      // five feet and ten inches. A single term is left alone, because "5 m in"
      // reads as five minutes one way and one metre the other, and the prompt
      // is the honest answer to that.
      tailText = null;
    } else {
      var open = termText(terms[0]);
      return { ok: false, error: "incomplete", expr: open, label: open, sub: "Continue typing..." };
    }
  }
  var inputText = terms.map(termText).join(" + ");
  var from = terms[0].unit;
  var value = terms[0].value;
  // A sum is only meaningful for an amount. Two temperature readings are
  // points on a scale and two fuel economies are reciprocals, so "10 C 50 F"
  // has no answer and adding them would print one anyway.
  if (terms.length > 1 && (from.dim === "temperature" || from.recip === true)) {
    return { ok: false, error: "incompatible", expr: inputText,
      label: "Cannot add " + from.dim + " values",
      sub: "convert one value at a time" };
  }
  for (var i = 1; i < terms.length; i++) {
    if (terms[i].unit.dim !== from.dim) {
      return { ok: false, error: "incompatible", expr: inputText,
        label: "Incompatible units",
        sub: dimNote(from, terms[i].unit) };
    }
    value += convertValue(terms[i].value, terms[i].unit, from);
  }
  return { ok: true, value: value, from: from, inputText: inputText,
    bare: tailText === null, toSpec: tailText };
}

// One parsed source against one target spec. Everything a conversion can be
// refused for lives here, so the single answer and the list reach the same
// verdicts by construction.
//
// toSpec is either the text the person typed, which goes through the same
// case-sensitive path the source did ("5 kJ in Cal" is kilocalories, and the
// folded table alone read it as calories, a factor of a thousand), or a unit
// the engine picked itself.
function renderTarget(q, toSpec) {
  var inputText = q.inputText;
  var from = q.from;
  var to = typeof toSpec === "string" ? unitFor(toSpec) : toSpec;
  if (!to) {
    return { ok: false, error: "unknown-target", expr: inputText,
      label: "Unknown unit '" + String(toSpec).trim() + "'",
      sub: dimHint(from) };
  }
  // Speed shorthand: length target coerces to its speed twin.
  if (from.dim === "speed" && to.dim === "length") {
    var twin = SPEED_LEN[to.sym];
    if (twin === undefined) {
      return { ok: false, error: "incompatible", expr: inputText,
        label: "Incompatible units",
        sub: "e.g. 250mph in km" };
    }
    to = symLookup(twin);
  }
  if (from.dim !== to.dim) {
    return { ok: false, error: "incompatible", expr: inputText,
      label: "Incompatible units",
      sub: dimNote(from, to) };
  }
  // Unphysical temperatures: anything under 0 K is a hint, never a
  // number. Covers both directions ("-300C in K", "-5K in C").
  if (from.dim === "temperature") {
    var kelvin = toCelsius(q.value, from.sym) + 273.15;
    if (kelvin < -1e-9) {
      return { ok: false, error: "unphysical", expr: inputText,
        label: "Below absolute zero",
        sub: inputText + " is under 0 K" };
    }
  }
  var out = convertValue(q.value, from, to);
  if (typeof out !== "number" || isNaN(out) || !isFinite(out)) {
    return { ok: false, error: "out-of-range", expr: inputText,
      label: "Result out of range",
      sub: "e.g. 5m in cm" };
  }
  var formatted = formatNumber(out);
  var copy = formatted + " " + displaySym(to.sym, out);
  return { ok: true, value: q.value, from: from.sym, to: to.sym,
    out: out, formatted: formatted, copy: copy,
    phrase: phrase(q.value, from.sym, out, to.sym),
    label: inputText + " = " + copy, inputText: inputText };
}

// Main entry, see header for the return contract. Never throws:
// unparseable input is null (caller falls through to app search).
function tryConvert(query) {
  var q = parseQuery(query);
  if (q === null || q.ok === false) return q;
  return renderTarget(q, q.bare ? symLookup(pickDefault(q.value, q.from)) : q.toSpec);
}

// The multi-answer half: a bare query answers with the list pickTargets picks
// out of the same dimension, an explicit target still answers with exactly the
// one conversion it asked for. A hint is one row in both shapes, and the
// target that produced it is the default - the head of the list - so a bare
// query the checks refuse stops there instead of repeating itself once per
// candidate.
function tryAll(query) {
  var q = parseQuery(query);
  if (q === null) return null;
  if (q.ok === false) return [q];
  if (q.bare === false) return [renderTarget(q, q.toSpec)];
  var targets = pickTargets(q.value, q.from);
  var out = [];
  for (var i = 0; i < targets.length; i++) {
    var r = renderTarget(q, symLookup(targets[i]));
    if (r.ok !== true) {
      if (i === 0) return [r];
      continue;
    }
    out.push(r);
  }
  return out;
}
