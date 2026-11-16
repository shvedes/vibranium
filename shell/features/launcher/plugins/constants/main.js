// Named-constants engine for AppLauncher: "how tall is X" answers, in the
// units X is actually said in.
//
// This is deliberately NOT the unit converter. UnitLib converts a quantity the
// user already wrote; this answers with a quantity out of a table of real
// things - rockets, engines, buildings, explosions, planets. The two are
// separate plugins because the two tables age differently: a metre is a metre
// forever, while a rocket's height changes between versions and a booster's
// thrust is a figure with a date on it. Keeping the volatile rows in their own
// plugin means `unit` can stay a converter of definitions, and turning this one
// off costs nothing but these rows.
//
// A row is a real-world value in one base unit per dimension plus the readings
// it is said in (`spread`). That shape is not new: UnitLib already answers a
// pinned snapshot (the Voyagers) that way, and this table is that idea with a
// table behind it.
//
// The factor table below is small ON PURPOSE - it only carries the units these
// rows are quoted in - and it is not a second source of truth: the suite
// compares every entry against UnitLib's own table and fails on a drift. A
// missing unit here is a row that cannot be read in it, never a wrong number.
//
// Query shapes, all case- and space-insensitive:
//
//   "<name>"                    every reading of it, in `spread` order
//   "the <name>"                the article is optional
//   "<number> <name>"           that many of it
//   "<name> in <unit>"          exactly one row, in the unit asked for
//   "<number> <name> to <unit>" likewise
//   "<engine> sl|vac"        an engine's sea level or vacuum rating (where both exist)
//   "<engine> ratio"         sea level / vacuum thrust, also "sl/vac ratio"
//
// A trailing "height", "thrust", "mass", "speed" or "length" is dropped, so
// "starship height" reads as "starship". A name is matched whole, so "saturn"
// names nothing: an abbreviation that could mean two things is not one.
//
// A bare name also answers with its neighbours, appended after its own
// readings: "starship" pairs with the booster and the tower, "raptor 3" with
// its vacuum variant and the older ratings. A relation is one row, in that
// row's own default unit, and it never displaces the reading the query asked
// for.
//
// Nothing here is a prefix of another row's meaning: "starship" is V3 and
// "starship v1" is V1, and the longest match wins. Every value is the source's
// own figure as of the date in its comment - a table that reads no clock, so a
// changing number is a new row or a new commit, never a live reading.

// Base units: length m, energy J, speed m/s, area m2, data B, force N.
//
// [factor to the base, singular, plural]. Three entries per unit rather than an
// object because the file is a table and a table should read as one.
var CON_FACTORS = {
  length: {
    m: [1, "metre", "metres"],
    mm: [0.001, "millimetre", "millimetres"],
    cm: [0.01, "centimetre", "centimetres"],
    km: [1000, "kilometre", "kilometres"],
    in: [0.0254, "inch", "inches"],
    ft: [0.3048, "foot", "feet"],
    yd: [0.9144, "yard", "yards"],
    mi: [1609.344, "mile", "miles"],
    nmi: [1852, "nautical mile", "nautical miles"],
    au: [1.495978707e11, "astronomical unit", "astronomical units"],
    ls: [299792458, "light-second", "light-seconds"],
    lmin: [17987547480, "light-minute", "light-minutes"],
    lh: [1079252848800, "light-hour", "light-hours"],
    ld: [25902068371200, "light-day", "light-days"],
    ly: [9.4607304725808e15, "light-year", "light-years"],
    nm: [1e-9, "nanometre", "nanometres"],
    um: [1e-6, "micrometre", "micrometres"]
  },
  energy: {
    J: [1, "joule", "joules"],
    kJ: [1000, "kilojoule", "kilojoules"],
    MJ: [1e6, "megajoule", "megajoules"],
    GJ: [1e9, "gigajoule", "gigajoules"],
    TJ: [1e12, "terajoule", "terajoules"],
    PJ: [1e15, "petajoule", "petajoules"],
    Wh: [3600, "watt-hour", "watt-hours"],
    kWh: [3.6e6, "kilowatt-hour", "kilowatt-hours"],
    cal: [4.184, "calorie", "calories"],
    kcal: [4184, "kilocalorie", "kilocalories"],
    "kt TNT": [4.184e12, "kiloton of TNT", "kilotons of TNT"],
    "Mt TNT": [4.184e15, "megaton of TNT", "megatons of TNT"]
  },
  speed: {
    "m/s": [1, "metre per second", "metres per second"],
    "km/h": [1 / 3.6, "kilometre per hour", "kilometres per hour"],
    "km/s": [1000, "kilometre per second", "kilometres per second"],
    mph: [0.44704, "mile per hour", "miles per hour"],
    kn: [1852 / 3600, "knot", "knots"],
    "ft/s": [0.3048, "foot per second", "feet per second"],
    c: [299792458, "speed of light", "speeds of light"]
  },
  area: {
    m2: [1, "square metre", "square metres"],
    km2: [1e6, "square kilometre", "square kilometres"],
    ha: [1e4, "hectare", "hectares"],
    ac: [4046.8564224, "acre", "acres"],
    ft2: [0.09290304, "square foot", "square feet"],
    mi2: [2589988.110336, "square mile", "square miles"]
  },
  data: {
    B: [1, "byte", "bytes"],
    KB: [1e3, "kilobyte", "kilobytes"],
    MB: [1e6, "megabyte", "megabytes"],
    GB: [1e9, "gigabyte", "gigabytes"],
    TB: [1e12, "terabyte", "terabytes"],
    KiB: [1024, "kibibyte", "kibibytes"],
    MiB: [1048576, "mebibyte", "mebibytes"],
    GiB: [1073741824, "gibibyte", "gibibytes"]
  },
  // Tonne-force is not in UnitLib - it is a thrust unit, and a row here is the
  // only thing that speaks it. Everything else is checked against the converter.
  force: {
    N: [1, "newton", "newtons"],
    kN: [1000, "kilonewton", "kilonewtons"],
    MN: [1e6, "meganewton", "meganewtons"],
    tf: [9806.65, "tonne-force", "tonne-force"],
    lbf: [4.4482216152605, "pound-force", "pound-force"],
    kgf: [9.80665, "kilogram-force", "kilogram-force"]
  }
};

// --- the rows ---------------------------------------------------------------
//
// sym is the row's identity AND its name for a constant-to-constant reading
// ("football field in tennis courts"), `value` is in the dimension's base unit, `def`
// is the reading a bare query leads with, and `spread` is the rest of the list
// in the order it is shown. `one`/`many` are what a sentence calls it.
//
// Aliases are matched on letters and digits only, so "F-1", "f1" and "F 1" are
// one key. A name that is a prefix of another row's name is fine (the whole
// key has to match), but two rows may never claim the same key -
// duplicateKeys() below is what the suite asks.

var CON_ROWS = [
  // --- a familiar length, migrated from UnitLib -----------------------------
  // The banana was the converter's one "silly" unit, and it is a named thing,
  // so it belongs here.
  { sym: "banana", dim: "length", value: 0.178, def: "cm", spread: ["cm", "in"],
    names: ["banana", "bananas"], one: "banana", many: "bananas" },                 // 7 in, for scale
  { sym: "equator", dim: "length", value: 40075017, def: "mi", spread: ["mi", "km"],
    names: ["equator", "equators", "earthcircumference", "earthcircumferences"],
    one: "Earth circumference", many: "Earth circumferences" },

  { sym: "hiroshima", dim: "energy", value: 15 * 4.184e12, def: "kt TNT", spread: ["kt TNT", "TJ", "kWh"],
    names: ["hiroshima", "hiroshimas", "littleboy"], one: "Hiroshima bomb", many: "Hiroshima bombs" },
  { sym: "tsar bomba", dim: "energy", value: 50 * 4.184e15, def: "Mt TNT", spread: ["Mt TNT", "PJ", "kWh"],
    names: ["tsarbomba", "tsarbombas"], one: "Tsar Bomba", many: "Tsar Bombas" },   // 50 Mt
  { sym: "lightning bolt", dim: "energy", value: 1e9, def: "kWh", spread: ["kWh", "MJ"],
    names: ["lightningbolt", "lightningbolts"], one: "lightning bolt", many: "lightning bolts" },
  { sym: "football field", dim: "area", value: 57600 * 0.09290304, def: "ac", spread: ["ac", "ha", "m2"],
    names: ["footballfield", "footballfields", "americanfootballfield", "americanfootballfields"],
    one: "football field", many: "football fields" },                              // 360 x 160 ft
  { sym: "tennis court", dim: "area", value: 2808 * 0.09290304, def: "ft2", spread: ["ft2", "m2"],
    names: ["tenniscourt", "tenniscourts"], one: "tennis court", many: "tennis courts" },
  { sym: "floppy", dim: "data", value: 1474560, def: "KB", spread: ["KB", "MB", "KiB"],
    names: ["floppy", "floppies", "floppydisk", "floppydisks"], one: "floppy disk", many: "floppy disks" },
  { sym: "cdrom", dim: "data", value: 737280000, def: "MB", spread: ["MB", "MiB", "GB"],
    names: ["cdrom", "cdroms"], one: "CD-ROM", many: "CD-ROMs" },                  // 80 min, mode 1
  { sym: "dvd", dim: "data", value: 4707319808, def: "GB", spread: ["GB", "GiB", "MB"],
    names: ["dvd", "dvds"], one: "DVD", many: "DVDs" },                            // single layer
  { sym: "bluray", dim: "data", value: 25025314816, def: "GB", spread: ["GB", "GiB"],
    names: ["bluray", "blurays"], one: "Blu-ray disc", many: "Blu-ray discs" },

  // Snapshot: Voyager 1 at one light-day, 2026-11-18 (NASA/JPL, 25.902e9 km);
  // Voyager 2 is the same-date estimate. Both drift ~1.3e6 km per day.
  { sym: "Voyager 1", dim: "length", value: 2.5902e13, def: "au",
    spread: ["km", "au", "lmin", "lh", "ld", "ly"],
    names: ["voyager1", "voyager1distance", "voyager1distances"],
    one: "distance from Earth to Voyager 1", many: "distances from Earth to Voyager 1" },
  { sym: "Voyager 2", dim: "length", value: 2.1658e13, def: "au",
    spread: ["km", "au", "lmin", "lh", "ld", "ly"],
    names: ["voyager2", "voyager2distance", "voyager2distances"],
    one: "distance from Earth to Voyager 2", many: "distances from Earth to Voyager 2" },

  // --- rockets --------------------------------------------------------------
  // Heights are the vehicle in its launched configuration, which is what a
  // comparison means: Saturn V with its Apollo stack, the Shuttle with its
  // external tank and boosters, SLS Block 1 with Orion.
  //
  // Starship is the one vehicle whose height is ambiguous, so the table says
  // which one it means: a bare version ("starship", "starship v2") is the SHIP
  // - the upper stage that flies - and the whole vehicle is only the stack when
  // the word is there ("starship stack", "starship v2 stack"). A version is a
  // row of its own either way: "v2" is not a rounding of "v3", it is a
  // different vehicle.
  //
  // A ship row is its stack less its booster, which is the arithmetic the
  // published figures already agree on: 121.3-71 is the V1 ship and 124.4-72.3
  // the V3 one, so V2 is 123.1-71 on the same 71 m booster.
  //
  // Sources, read 2026-11-16: SpaceX's Starship technical page (ship 52 m,
  // booster 72 m, stack 124 m) and the Block 1/2/3 table on Wikipedia's SpaceX
  // Starship (121.3 / 123.1 / 124.4 m); NASA for SLS and Saturn V; ULA's Vulcan
  // data sheet (61.6 m); Blue Origin for New Glenn (98 m); Rocket Lab for
  // Electron (18 m) and Neutron (43 m).
  { sym: "Starship V3", dim: "length", value: 124.4, def: "m", spread: ["m", "ft"],
    names: ["starshipv3stack", "starshipv3stacks", "starshipv3stacked", "starshipblock3stack", "starshipblock3stacks",
      "starshipstack", "starshipstacks", "starshipstacked"],
    one: "Starship V3", many: "Starship V3s" },
  { sym: "Starship V2", dim: "length", value: 123.1, def: "m", spread: ["m", "ft"],
    names: ["starshipv2stack", "starshipv2stacks", "starshipv2stacked", "starshipblock2stack", "starshipblock2stacks"],
    one: "Starship V2", many: "Starship V2s" },
  { sym: "Starship V1", dim: "length", value: 121.3, def: "m", spread: ["m", "ft"],
    names: ["starshipv1stack", "starshipv1stacks", "starshipv1stacked", "starshipblock1stack", "starshipblock1stacks"],
    one: "Starship V1", many: "Starship V1s" },
  { sym: "Starship ship V3", dim: "length", value: 52.1, def: "m", spread: ["m", "ft"],
    names: ["starship", "starships", "starshipv3", "starshipblock3", "starshipshipv3", "starshipship",
      "starshipv3ship", "starshipupperstage"],
    one: "Starship upper stage", many: "Starship upper stages" },
  { sym: "Starship ship V2", dim: "length", value: 52.1, def: "m", spread: ["m", "ft"],
    names: ["starshipv2", "starshipblock2", "starshipshipv2", "starshipv2ship"],
    one: "Starship V2 upper stage", many: "Starship V2 upper stages" },
  { sym: "Starship ship V1", dim: "length", value: 50.3, def: "m", spread: ["m", "ft"],
    names: ["starshipv1", "starshipblock1", "starshipshipv1", "starshipv1ship"],
    one: "Starship V1 upper stage", many: "Starship V1 upper stages" },
  { sym: "Super Heavy V3", dim: "length", value: 72.3, def: "m", spread: ["m", "ft"],
    names: ["superheavyv3", "superheavyblock3", "superheavy"], one: "Super Heavy V3", many: "Super Heavy V3s" },
  // Block 2 kept the Block 1 booster's tank length, so 71 m is both.
  { sym: "Super Heavy V2", dim: "length", value: 71, def: "m", spread: ["m", "ft"],
    names: ["superheavyv2", "superheavyblock2"], one: "Super Heavy V2", many: "Super Heavy V2s" },
  { sym: "Super Heavy V1", dim: "length", value: 71, def: "m", spread: ["m", "ft"],
    names: ["superheavyv1", "superheavyblock1"], one: "Super Heavy V1", many: "Super Heavy V1s" },
  { sym: "SLS Block 1", dim: "length", value: 98.1, def: "m", spread: ["m", "ft"],
    names: ["sls", "slsblock1", "spacelaunchsystem"], one: "SLS Block 1", many: "SLS Block 1s" },
  { sym: "SLS Block 1B", dim: "length", value: 111, def: "m", spread: ["m", "ft"],
    names: ["slsblock1b"], one: "SLS Block 1B", many: "SLS Block 1Bs" },           // CANCELLED 2026-02-26 with the EUS, never flew
  { sym: "Saturn V", dim: "length", value: 110.6, def: "m", spread: ["m", "ft"],
    names: ["saturnv", "saturn5"], one: "Saturn V", many: "Saturn Vs" },
  { sym: "Space Shuttle", dim: "length", value: 56.1, def: "m", spread: ["m", "ft"],
    names: ["spaceshuttle", "shuttle", "shuttlestack"], one: "Space Shuttle stack", many: "Space Shuttle stacks" },
  { sym: "Falcon 9", dim: "length", value: 70, def: "m", spread: ["m", "ft"],
    names: ["falcon9", "f9"], one: "Falcon 9", many: "Falcon 9s" },
  { sym: "Falcon Heavy", dim: "length", value: 70, def: "m", spread: ["m", "ft"],
    names: ["falconheavy", "fh"], one: "Falcon Heavy", many: "Falcon Heavies" },
  { sym: "New Glenn", dim: "length", value: 98, def: "m", spread: ["m", "ft"],
    names: ["newglenn"], one: "New Glenn", many: "New Glenns" },
  { sym: "Vulcan Centaur", dim: "length", value: 61.6, def: "m", spread: ["m", "ft"],
    names: ["vulcan", "vulcancentaur"], one: "Vulcan Centaur", many: "Vulcan Centaurs" },
  { sym: "Atlas V", dim: "length", value: 58.3, def: "m", spread: ["m", "ft"],
    names: ["atlasv", "atlas5"], one: "Atlas V", many: "Atlas Vs" },               // 551, the tallest standard config
  { sym: "Delta IV Heavy", dim: "length", value: 72, def: "m", spread: ["m", "ft"],
    names: ["deltaivheavy", "delta4heavy"], one: "Delta IV Heavy", many: "Delta IV Heavies" },
  { sym: "Ariane 6", dim: "length", value: 63, def: "m", spread: ["m", "ft"],
    names: ["ariane6"], one: "Ariane 6", many: "Ariane 6s" },
  { sym: "Long March 5", dim: "length", value: 57, def: "m", spread: ["m", "ft"],
    names: ["longmarch5", "changzheng5"], one: "Long March 5", many: "Long March 5s" },
  { sym: "Soyuz 2", dim: "length", value: 46.3, def: "m", spread: ["m", "ft"],
    names: ["soyuz", "soyuz2"], one: "Soyuz 2", many: "Soyuz 2s" },
  { sym: "N1", dim: "length", value: 105, def: "m", spread: ["m", "ft"],
    names: ["n1", "n1rocket"], one: "N1", many: "N1s" },                           // the Soviet Moon rocket
  { sym: "Electron", dim: "length", value: 18, def: "m", spread: ["m", "ft"],
    names: ["electron"], one: "Electron", many: "Electrons" },
  { sym: "Neutron", dim: "length", value: 43, def: "m", spread: ["m", "ft"],
    names: ["neutron"], one: "Neutron", many: "Neutrons" },

  // --- launch towers --------------------------------------------------------
  // The service structure each rocket rides beside, so "falcon 9 tower" is a
  // height like any other. The figure is the tower TO ITS TOP - the same
  // measure as Mechazilla's 146 m - not the crane or lightning mast above it,
  // and each is the operator's or the agency's own number:
  //
  //   Saturn V  380 ft Launch Umbilical Tower (398 ft to the top of its
  //             hammerhead crane), NASA's Saturn V flight manual and KSC facts
  //   Shuttle   347 ft Fixed Service Structure to the tip of its mast, NASA
  //             Launch Complex 39 facts
  //   SLS       355 ft Mobile Launcher tower, NASA's Mobile Launcher fact sheet
  //   Falcon    212 ft transporter-erector at LC-39A, NASA Commercial Crew
  //   Ariane 6  90 m mobile gantry, CNES and ESA
  //   SLC-41    286 ft Vertical Integration Facility, ULA's Atlas V user guide
  //   Delta IV  330 ft Mobile Service Tower, Boeing's topping-out release
  //
  // Read 2026-11-16. A rocket with no published tower height gets no row
  // rather than an estimate: Electron, Neutron, New Glenn, Soyuz and the N1
  // keep their rocket row and nothing beside it.
  { sym: "Saturn V launch tower", dim: "length", value: 115.8, def: "m", spread: ["m", "ft"],
    names: ["saturnvlaunchtower", "saturnvtower", "launchumbilicaltower", "luttower", "apollotower"],
    one: "Saturn V launch tower", many: "Saturn V launch towers" },
  { sym: "Shuttle launch tower", dim: "length", value: 105.8, def: "m", spread: ["m", "ft"],
    names: ["shuttlelaunchtower", "shuttletower", "fixedservicestructure", "fsstower"],
    one: "Shuttle launch tower", many: "Shuttle launch towers" },
  { sym: "SLS launch tower", dim: "length", value: 108.2, def: "m", spread: ["m", "ft"],
    names: ["slslaunchtower", "slstower", "mobilelaunchertower", "mltower"],
    one: "SLS launch tower", many: "SLS launch towers" },
  { sym: "Falcon launch tower", dim: "length", value: 64.6, def: "m", spread: ["m", "ft"],
    names: ["falconlaunchtower", "falcontower", "falcon9launchtower", "falcon9tower", "strongback", "transportererector"],
    one: "Falcon transporter-erector", many: "Falcon transporter-erectors" },
  { sym: "Ariane 6 launch tower", dim: "length", value: 90, def: "m", spread: ["m", "ft"],
    names: ["ariane6launchtower", "ariane6tower", "arianetower", "ariane6gantry", "mobilegantry"],
    one: "Ariane 6 mobile gantry", many: "Ariane 6 mobile gantries" },
  // SLC-41's VIF stacks both Atlas V and Vulcan Centaur, so it is one row that
  // both rockets name instead of two copies of one height.
  { sym: "SLC-41 tower", dim: "length", value: 87.2, def: "m", spread: ["m", "ft"],
    names: ["slc41tower", "atlasvlaunchtower", "atlasvtower", "atlastower", "vulcantower",
      "verticalintegrationfacility", "vif"],
    one: "SLC-41 integration tower", many: "SLC-41 integration towers" },
  { sym: "Delta IV launch tower", dim: "length", value: 100.6, def: "m", spread: ["m", "ft"],
    names: ["deltaivlaunchtower", "deltaivtower", "mobileservicetower"],
    one: "Delta IV mobile service tower", many: "Delta IV mobile service towers" },
  // The catch tower is a structure, not a vehicle: 143 m of truss plus a 3 m
  // lightning rod is the 146 m SpaceX and the FAA filings both quote.
  { sym: "Mechazilla", dim: "length", value: 146, def: "m", spread: ["m", "ft"],
    names: ["mechazilla", "launchtower", "catchtower"], one: "Mechazilla", many: "Mechazillas" },

  // --- buildings ------------------------------------------------------------
  // Heights to the architectural top, CTBUH's rule: spires count, antennas do
  // not - EXCEPT the Empire State Building and the Eiffel Tower, which are
  // quoted to the antenna tip because that is the figure they are said in (CTBUH
  // architectural: 381 m and 300 m). The Twin Towers are the original World Trade Center, 417 m to the
  // roof - the 526 m figure was their antenna, which the rule excludes.
  { sym: "Burj Khalifa", dim: "length", value: 828, def: "ft", spread: ["m", "ft"],
    names: ["burjkhalifa", "burjkhalifas", "burj", "burjkhalifatower"], one: "Burj Khalifa", many: "Burj Khalifas" },
  { sym: "Merdeka 118", dim: "length", value: 678.9, def: "ft", spread: ["m", "ft"],
    names: ["merdeka118", "merdeka"], one: "Merdeka 118", many: "Merdeka 118s" },
  { sym: "Shanghai Tower", dim: "length", value: 632, def: "ft", spread: ["m", "ft"],
    names: ["shanghaitower"], one: "Shanghai Tower", many: "Shanghai Towers" },
  { sym: "Makkah Royal Clock Tower", dim: "length", value: 601, def: "ft", spread: ["m", "ft"],
    names: ["makkahclocktower", "abrajalbait"], one: "Makkah Royal Clock Tower", many: "Makkah Royal Clock Towers" },
  { sym: "Ping An Finance Center", dim: "length", value: 599.1, def: "ft", spread: ["m", "ft"],
    names: ["pinganfinancecenter", "pingan"], one: "Ping An Finance Center", many: "Ping An Finance Centers" },
  { sym: "Lotte World Tower", dim: "length", value: 554.5, def: "ft", spread: ["m", "ft"],
    names: ["lotteworldtower", "lotteworld"], one: "Lotte World Tower", many: "Lotte World Towers" },
  { sym: "One World Trade Center", dim: "length", value: 541.3, def: "ft", spread: ["m", "ft"],
    names: ["oneworldtradecenter", "onewtc", "freedomtower"],
    one: "One World Trade Center", many: "One World Trade Centers" },
  { sym: "Taipei 101", dim: "length", value: 508, def: "ft", spread: ["m", "ft"],
    names: ["taipei101"], one: "Taipei 101", many: "Taipei 101s" },
  { sym: "Petronas Towers", dim: "length", value: 451.9, def: "ft", spread: ["m", "ft"],
    names: ["petronastowers", "petronas"], one: "Petronas Towers", many: "Petronas Towers" },
  { sym: "Twin Towers", dim: "length", value: 417, def: "ft", spread: ["m", "ft"],
    names: ["twintowers", "worldtradecenter", "wtc", "originalwtc"], one: "Twin Towers", many: "Twin Towers" }, // roof, 1973-2001
  { sym: "Empire State Building", dim: "length", value: 443.2, def: "ft", spread: ["m", "ft"],
    names: ["empirestatebuilding", "empirestate", "esb"], one: "Empire State Building", many: "Empire State Buildings" }, // to the antenna tip
  { sym: "Eiffel Tower", dim: "length", value: 330, def: "ft", spread: ["m", "ft"],
    names: ["eiffeltower", "eiffeltowers", "toureiffel"], one: "Eiffel Tower", many: "Eiffel Towers" },          // with antennas
  { sym: "Statue of Liberty", dim: "length", value: 93, def: "ft", spread: ["m", "ft"],
    names: ["statueofliberty", "libertystatue"], one: "Statue of Liberty", many: "Statues of Liberty" },
  { sym: "Mount Everest", dim: "length", value: 8848.86, def: "ft", spread: ["m", "ft"],
    names: ["everest", "everests", "mounteverest", "mounteverests", "sagarmatha", "chomolungma"], one: "Mount Everest", many: "Mount Everests" },

  // --- speeds and orbital mechanics -----------------------------------------
  // Escape velocity from the SURFACE: 11.186 km/s on Earth, 2.376 on the Moon,
  // 59.5 at Jupiter's 1-bar level, 617.7 at the Sun's mean radius (NASA's
  // planetary fact sheet and JPL's physical parameters, read 2026-11-16).
  // Circular orbital speed is escape / sqrt(2).
  { sym: "escape velocity", dim: "speed", value: 11186, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["escapevelocity", "escapevelocities", "earthescapevelocity", "earthescapevelocities",
      "escape", "escapes", "earthescape"],
    one: "Earth escape velocity", many: "Earth escape velocities" },
  { sym: "Moon escape velocity", dim: "speed", value: 2376, def: "km/h", spread: ["km/h", "m/s", "km/s"],
    names: ["moonescapevelocity", "lunarescapevelocity", "moonescape", "lunarescape"],
    one: "Moon escape velocity", many: "Moon escape velocities" },
  { sym: "Mars escape velocity", dim: "speed", value: 5027, def: "km/h", spread: ["km/h", "m/s", "km/s"],
    names: ["marsescapevelocity", "marsescape"], one: "Mars escape velocity", many: "Mars escape velocities" },
  { sym: "Jupiter escape velocity", dim: "speed", value: 59500, def: "km/s", spread: ["km/s", "km/h", "mph"],
    names: ["jupiterescapevelocity", "jupiterescape"], one: "Jupiter escape velocity", many: "Jupiter escape velocities" },
  { sym: "Sun escape velocity", dim: "speed", value: 617700, def: "km/s", spread: ["km/s", "km/h", "c"],
    names: ["sunescapevelocity", "solarescapevelocity", "sunescape"], one: "Sun escape velocity", many: "Sun escape velocities" },
  { sym: "Mercury escape velocity", dim: "speed", value: 4250, def: "km/s", spread: ["km/s", "km/h"],
    names: ["mercuryescapevelocity", "mercuryescape"], one: "Mercury escape velocity", many: "Mercury escape velocities" },
  { sym: "Venus escape velocity", dim: "speed", value: 10360, def: "km/s", spread: ["km/s", "km/h"],
    names: ["venusescapevelocity", "venusescape"], one: "Venus escape velocity", many: "Venus escape velocities" },
  { sym: "Saturn escape velocity", dim: "speed", value: 35500, def: "km/s", spread: ["km/s", "km/h"],
    names: ["saturnescapevelocity", "saturnescape"], one: "Saturn escape velocity", many: "Saturn escape velocities" },
  { sym: "Uranus escape velocity", dim: "speed", value: 21300, def: "km/s", spread: ["km/s", "km/h"],
    names: ["uranusescapevelocity", "uranusescape"], one: "Uranus escape velocity", many: "Uranus escape velocities" },
  { sym: "Neptune escape velocity", dim: "speed", value: 23500, def: "km/s", spread: ["km/s", "km/h"],
    names: ["neptuneescapevelocity", "neptuneescape"], one: "Neptune escape velocity", many: "Neptune escape velocities" },
  // The same relation one body at a time, because an orbit is the figure a
  // mission actually has to reach: circular speed at the surface is escape
  // divided by sqrt(2), applied to the escape rows above (1.68 km/s at the
  // Moon, 3.55 at Mars, 42.1 at Jupiter). Io and Titan are here because they
  // are the two moons landers ask about, and their escape velocities are JPL's
  // 2.558 and 2.639 km/s - the moons' own, not the planets' they orbit.
  { sym: "Moon orbital velocity", dim: "speed", value: 1680, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["moonorbitalvelocity", "lunarorbitalvelocity", "moonorbit", "lunarorbit", "moonorbital", "lunarorbital"],
    one: "Moon orbital velocity", many: "Moon orbital velocities" },
  { sym: "Mars orbital velocity", dim: "speed", value: 3555, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["marsorbitalvelocity", "marsorbit", "marsorbital"], one: "Mars orbital velocity", many: "Mars orbital velocities" },
  { sym: "Io orbital velocity", dim: "speed", value: 1809, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["ioorbitalvelocity", "ioorbit", "ioorbital"], one: "Io orbital velocity", many: "Io orbital velocities" },
  { sym: "Titan orbital velocity", dim: "speed", value: 1866, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["titanorbitalvelocity", "titanorbit", "titanorbital"], one: "Titan orbital velocity", many: "Titan orbital velocities" },
  { sym: "Mercury orbital velocity", dim: "speed", value: 3005, def: "km/s", spread: ["km/s", "km/h"],
    names: ["mercuryorbitalvelocity", "mercuryorbit", "mercuryorbital"], one: "Mercury orbital velocity", many: "Mercury orbital velocities" },
  { sym: "Venus orbital velocity", dim: "speed", value: 7326, def: "km/s", spread: ["km/s", "km/h"],
    names: ["venusorbitalvelocity", "venusorbit", "venusorbital"], one: "Venus orbital velocity", many: "Venus orbital velocities" },
  { sym: "Jupiter orbital velocity", dim: "speed", value: 42070, def: "km/s", spread: ["km/s", "km/h"],
    names: ["jupiterorbitalvelocity", "jupiterorbit", "jupiterorbital"], one: "Jupiter orbital velocity", many: "Jupiter orbital velocities" },
  { sym: "Saturn orbital velocity", dim: "speed", value: 25100, def: "km/s", spread: ["km/s", "km/h"],
    names: ["saturnorbitalvelocity", "saturnorbit", "saturnorbital"], one: "Saturn orbital velocity", many: "Saturn orbital velocities" },
  { sym: "Uranus orbital velocity", dim: "speed", value: 15060, def: "km/s", spread: ["km/s", "km/h"],
    names: ["uranusorbitalvelocity", "uranusorbit", "uranusorbital"], one: "Uranus orbital velocity", many: "Uranus orbital velocities" },
  { sym: "Neptune orbital velocity", dim: "speed", value: 16620, def: "km/s", spread: ["km/s", "km/h"],
    names: ["neptuneorbitalvelocity", "neptuneorbit", "neptuneorbital"], one: "Neptune orbital velocity", many: "Neptune orbital velocities" },
  { sym: "Sun orbital velocity", dim: "speed", value: 436800, def: "km/s", spread: ["km/s", "km/h"],
    names: ["sunorbitalvelocity", "solarorbitalvelocity", "sunorbit", "sunorbital", "solarorbital"], one: "Sun orbital velocity", many: "Sun orbital velocities" },
  // A circular orbit at 400 km, which is where the station is: 7.67 km/s, one
  // revolution in 92 minutes - the 27,600 km/h a launch has to reach to stay
  // up. Geostationary is the other one everybody quotes.
  { sym: "low Earth orbit speed", dim: "speed", value: 7669, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["leo", "leospeed", "leoorbit", "leoorbitalvelocity", "lowearthorbit",
      "lowearthorbitspeed", "lowearthorbitvelocity", "orbitalspeed", "orbitalvelocity",
      "orbitvelocity", "orbitspeed", "orbit", "leoinsertion", "leoinjection", "issspeed", "iss",
      "issorbit", "issorbitalspeed", "internationalspacestation", "spacestation"],
    one: "low Earth orbit speed", many: "low Earth orbit speeds" },
  { sym: "geostationary speed", dim: "speed", value: 3070, def: "km/h",
    spread: ["km/h", "mph", "m/s", "km/s"],
    names: ["geostationary", "geostationaryspeed", "geostationaryorbit", "geostationaryorbitspeed",
      "geostationaryvelocity", "geospeed", "geoorbitspeed", "geoorbit", "geosynchronous", "geosync"],
    one: "geostationary orbital speed", many: "geostationary orbital speeds" },
  { sym: "speed of sound", dim: "speed", value: 343, def: "km/h",
    spread: ["km/h", "mph", "m/s", "kn", "ft/s"],
    names: ["speedofsound", "speedsofsound", "soundspeed", "soundspeeds"],
    one: "speed of sound", many: "speeds of sound" },                              // dry air, 20 C

  // --- engines --------------------------------------------------------------
  // Thrust at sea level unless the name says vacuum. The tonne-force is the
  // unit these are published in ("250 tf"), so it leads, and the newton figure
  // is that rating times 9806.65 N rather than a second quote.
  //
  // SpaceX's own specification page (read 2026-11-16) rates a flight Raptor 3
  // at 250 tf while the engine has demonstrated 280 tf on the test stand; the
  // 280 tf row is the demonstrated figure and the 250 tf row is what flies.
  // Raptor 1 and 2 are SpaceX's data-card ratings (185 tf, 230 tf).
  { sym: "Raptor 3", dim: "force", value: 250 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor3", "raptorv3", "raptor"], one: "Raptor 3", many: "Raptor 3s" },
  { sym: "Raptor 3 max", dim: "force", value: 280 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor3max", "raptorv3max"], one: "Raptor 3 at full thrust", many: "Raptor 3s at full thrust" },
  // The vacuum variant ("RVAC") is the same chamber and a bigger nozzle: 275 tf
  // on Raptor 3 and 258 tf on Raptor 2 (SpaceX engine data, read 2026-11-16).
  // A ship flies three of these and three sea-level engines, so the two name
  // each other.
  { sym: "Raptor 3 vacuum", dim: "force", value: 275 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor3vacuum", "raptorv3vac", "rvac", "rvac3"], one: "Raptor 3 vacuum", many: "Raptor 3 vacuums" },
  { sym: "Raptor 2 vacuum", dim: "force", value: 258 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor2vacuum", "raptorv2vac", "rvac2"], one: "Raptor 2 vacuum", many: "Raptor 2 vacuums" },
  { sym: "Raptor 2", dim: "force", value: 230 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor2", "raptorv2"], one: "Raptor 2", many: "Raptor 2s" },
  { sym: "Raptor 1", dim: "force", value: 185 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor1", "raptorv1"], one: "Raptor 1", many: "Raptor 1s" },
  // Vacuum ratings for the engines that publish one (same sources as the sea-level
  // rows): Raptor 1 200 tf, F-1 1,746,000 lbf, Merlin 1D 914 kN, RD-180 4,152 kN.
  // BE-4 and Northstar have no published vacuum figure, so they get no row and
  // no ratio rather than an estimate.
  { sym: "Raptor 1 vacuum", dim: "force", value: 200 * 9806.65, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["raptor1vacuum", "raptorv1vac", "rvac1"], one: "Raptor 1 vacuum", many: "Raptor 1 vacuums" },
  { sym: "F-1 vacuum", dim: "force", value: 7770 * 1000, def: "kN", spread: ["kN", "tf", "MN", "lbf"],
    names: ["f1vacuum", "f-1vacuum"], one: "F-1 vacuum", many: "F-1 vacuums" },
  { sym: "Merlin 1D vacuum", dim: "force", value: 914 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["merlin1dvacuum", "merlinvacuum"], one: "Merlin 1D vacuum", many: "Merlin 1D vacuums" },
  { sym: "RD-180 vacuum", dim: "force", value: 4152 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["rd180vacuum", "rd-180vacuum"], one: "RD-180 vacuum", many: "RD-180 vacuums" },
  // RS-25 at 109% power: 418,000 lbf at sea level, 512,300 in vacuum.
  { sym: "RS-25", dim: "force", value: 1860 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["rs25", "rs25e", "ssme"], one: "RS-25", many: "RS-25s" },
  { sym: "RS-25 vacuum", dim: "force", value: 2279 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["rs25vacuum"], one: "RS-25 in vacuum", many: "RS-25s in vacuum" },
  // BE-4: 640,000 lbf. Northstar, announced 2026-11-05, is 715,000 lbf - 12%
  // more thrust at 30% less mass, and it has not flown.
  { sym: "BE-4", dim: "force", value: 640000 * 4.4482216152605, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["be4", "be-4"], one: "BE-4", many: "BE-4s" },
  { sym: "Northstar", dim: "force", value: 715000 * 4.4482216152605, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["northstar"], one: "Northstar", many: "Northstars" },
  // F-1: 1,522,000 lbf (6,770 kN) at sea level; the 1,746,000 lbf (7,770 kN)
  // figure is its vacuum rating. Most powerful single-chamber liquid engine
  // flown. Merlin 1D: 845 kN. RD-180: 3,830 kN.
  { sym: "F-1", dim: "force", value: 6770 * 1000, def: "tf", spread: ["tf", "kN", "MN", "lbf"],
    names: ["f1", "f-1"], one: "F-1", many: "F-1s" },
  { sym: "Merlin 1D", dim: "force", value: 845 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["merlin1d", "merlin"], one: "Merlin 1D", many: "Merlin 1Ds" },
  { sym: "RD-180", dim: "force", value: 3830 * 1000, def: "kN", spread: ["kN", "tf", "lbf"],
    names: ["rd180", "rd-180"], one: "RD-180", many: "RD-180s" },
  // Whole-stack liftoff thrust, which is the number a comparison actually asks
  // for: 33 Raptor 3s on Super Heavy (SpaceX's 8,240 tf), Saturn V's five F-1s
  // (34,020 kN, NASA's Apollo 11 liftoff figure, so not exactly 5 x the F-1 row)
  // and SLS's four RS-25s plus two solid boosters (39,144 kN).
  { sym: "Super Heavy thrust", dim: "force", value: 8240 * 9806.65, def: "MN", spread: ["MN", "tf", "lbf"],
    names: ["superheavythrust", "starshipthrust", "starshipliftoffthrust"],
    one: "Super Heavy liftoff thrust", many: "Super Heavy liftoff thrusts" },
  { sym: "Saturn V thrust", dim: "force", value: 34020 * 1000, def: "MN", spread: ["MN", "tf", "lbf"],
    names: ["saturnvthrust"], one: "Saturn V liftoff thrust", many: "Saturn V liftoff thrusts" },
  { sym: "SLS thrust", dim: "force", value: 39144 * 1000, def: "MN", spread: ["MN", "tf", "lbf"],
    names: ["slsthrust"], one: "SLS liftoff thrust", many: "SLS liftoff thrusts" }
];

// The trailing word a query may carry and not mean: "starship height" is
// "starship", and "raptor 3 thrust" is "raptor 3". It is dropped from the END
// of the head only, and only after the whole key has been tried, because
// "Super Heavy thrust" is a row of its own.
var RE_TRAILING_KIND = /\s+(?:height|tall|thrust|mass|weight|speed|length|long|distance|diameter)$/i;

// The question a reader may put IN FRONT of the name and still mean the name:
// "how tall is the eiffel tower", "height of the burj khalifa", "what is the
// speed of sound". Stripped one phrase at a time and retried after each, so the
// forms stack - and never before the whole head has been looked up, because
// "speed of sound" is a row that begins with one of these phrases.
var RE_LEADING_ASK = /^(?:(?:how\s+(?:tall|high|long|fast|heavy|big)\s+(?:is|was|are|does)|what(?:'s|\s+is)\s+the|(?:the\s+)?(?:height|length|thrust|speed|mass|weight|size|diameter)\s+of)(?:\s+the)?\s+)/i;

// A leading number, the same shape the unit engine accepts: thousands
// grouping, a leading decimal point, an exponent.
var RE_CON_NUM = /^[+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?/i;

var RE_CON_SPLIT = /^(.*)\s+(?:in|into|to|as|->|=)\s+(.+?)\s*$/i;

// Letters and digits only. "F-1" and "f1" are one key, "Lightning Bolt" and
// "lightningbolt" are another, and a trailing "." is gone before either.
function conKeyRaw(s) {
  let t = String(s === undefined || s === null ? "" : s).toLowerCase().trim();
  return t.replace(/[^a-z0-9]+/g, "");
}

function conKey(s) {
  let t = String(s === undefined || s === null ? "" : s).toLowerCase().trim();
  return conKeyRaw(t.replace(RE_TRAILING_KIND, ""));
}

// Same rounding as the converter: integers plain, six significant digits,
// exponential only at the extremes, so a row that says "124.4 m" does not read
// back as "124.40000000000001".
function conNumber(v) {
  if (typeof v !== "number" || isNaN(v)) return "NaN";
  if (!isFinite(v)) return v > 0 ? "Infinity" : "-Infinity";
  if (v % 1 === 0) {
    if (v === 0) return "0";
    if (Math.abs(v) < 1e15) return String(v);
    return conTrim(v.toExponential(6));
  }
  let abs = Math.abs(v);
  if (abs !== 0 && (abs >= 1e12 || abs < 1e-6)) return conTrim(v.toExponential(6));
  if (abs >= 999999.5) return String(Math.round(v));
  let s = v.toPrecision(6);
  if (s.indexOf("e") >= 0) return conTrim(s);
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s === "-0" || s === "" ? "0" : s;
}

function conTrim(e) {
  return e.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
}

// The name table: every alias of every row, longest key first is not needed
// because a key is matched whole. A duplicate is a bug in the table, and
// duplicateKeys() is what the suite reads to name it.
var _conNames = null;

function conNames() {
  if (_conNames !== null) return _conNames;
  let m = {};
  for (let i = 0; i < CON_ROWS.length; i++) {
    let row = CON_ROWS[i];
    for (let j = 0; j < row.names.length; j++) {
      let k = conKey(row.names[j]);
      if (k !== "") m[k] = row;
    }
  }
  _conNames = m;
  return m;
}

// Keys claimed by more than one row, so a new row cannot silently take a name
// away from an old one. Sorted, because it is read as a failure list.
function duplicateKeys() {
  let seen = {};
  let dup = {};
  for (let i = 0; i < CON_ROWS.length; i++) {
    let row = CON_ROWS[i];
    for (let j = 0; j < row.names.length; j++) {
      let k = conKey(row.names[j]);
      if (k === "") continue;
      if (seen[k] !== undefined && seen[k] !== row) dup[k] = true;
      seen[k] = row;
    }
  }
  return Object.keys(dup).sort();
}

// A name lookup that prefers the WHOLE head. "super heavy thrust" names the
// force row, not the length row with a kind word behind it, so the exact key is
// asked first and only then the kind-stripped one.
function conNamed(text) {
  let m = conNames();
  let exact = conKeyRaw(text);
  if (exact !== "" && m[exact] !== undefined) return m[exact];
  let loose = conKey(text);
  return loose === "" ? undefined : m[loose];
}

// The row the last conLookup() answer was a TYPO rescue of, or null. A guess is
// still an answer, but the row has to say so, or a misspelling reads back as the
// name the reader wrote.
var _conTypoRow = null;

// Damerau optimal-string-alignment distance capped at two, the same measure the
// application search uses: a substitution, insertion, deletion or adjacent swap
// is one edit, and anything further is out of budget. A single rolling row
// cannot serve the transposition cell, which reads two rows back, so the whole
// table is kept - and reused, because the rescue runs on a keystroke.
var _conDistTable = new Int32Array(64);

function conDistance(a, b) {
  let la = a.length;
  let lb = b.length;
  if (Math.abs(la - lb) > 2) return 3;
  let w = lb + 1;
  let need = (la + 1) * w;
  if (need > _conDistTable.length) _conDistTable = new Int32Array(need * 2);
  let d = _conDistTable;
  for (let i = 0; i <= la; i++) d[i * w] = i;
  for (let j = 0; j <= lb; j++) d[j] = j;
  for (let i = 1; i <= la; i++) {
    let row = i * w;
    let prev = row - w;
    let xi = a.charCodeAt(i - 1);
    for (let j = 1; j <= lb; j++) {
      let v = d[prev + j] + 1;
      let left = d[row + j - 1] + 1;
      if (left < v) v = left;
      let diag = d[prev + j - 1] + (xi === b.charCodeAt(j - 1) ? 0 : 1);
      if (diag < v) v = diag;
      if (i > 1 && j > 1 && xi === b.charCodeAt(j - 2)
        && a.charCodeAt(i - 2) === b.charCodeAt(j - 1)) {
        let swap = d[prev - w + j - 2] + 1;
        if (swap < v) v = swap;
      }
      d[row + j] = v;
    }
  }
  let dist = d[la * w + lb];
  return dist <= 2 ? dist : 3;
}

// The typo rescue: the one row a misspelling still names, or null. The budget is
// a length gate rather than the application search's token gate, because a key
// here is a whole name rather than one word of one: one edit under eight
// characters, two at eight and above. Two edits on a short key reaches
// unrelated words - "chrome" is two from "cdrom" - while a long span of text
// ("eifeltower", "burjkhalifa") absorbs two without coming near anything else
// in the table. A key shorter than three is never guessed, because "km" and
// "c" are one edit from half the alphabet and stealing a conversion is worse
// than missing. A tie is a miss: two rows equally close is a guess, and this
// table has "Starship V1" and "Starship V2" one character apart.
function conGuess(text) {
  let key = conKey(text);
  if (key.length < 3) return null;
  let budget = key.length < 8 ? 1 : 2;
  let m = conNames();
  let best = null;
  let bestDist = 9;
  let tie = false;
  for (let k in m) {
    if (Math.abs(k.length - key.length) > budget) continue;
    let dist = conDistance(key, k);
    if (dist < 1 || dist > budget) continue;
    if (dist < bestDist) {
      bestDist = dist;
      best = m[k];
      tie = false;
    } else if (dist === bestDist && m[k] !== best) {
      tie = true;
    }
  }
  return tie ? null : best;
}

// The name a query asks about, in the order the reader means it: the whole
// head, the same head with a leading question stripped, and then a typo rescue
// of what is left. _conTypoRow says whether the answer was a guess.
function conLookup(text) {
  let t = String(text === undefined || text === null ? "" : text).trim();
  for (let i = 0; i < 3; i++) {
    let row = conNamed(t);
    if (row !== undefined) {
      _conTypoRow = null;
      return row;
    }
    if (!RE_LEADING_ASK.test(t)) break;
    t = t.replace(RE_LEADING_ASK, "").trim();
    if (t === "") break;
  }
  let guess = conGuess(t);
  _conTypoRow = guess;
  return guess === null ? undefined : guess;
}

function conRow(sym) {
  for (let i = 0; i < CON_ROWS.length; i++) if (CON_ROWS[i].sym === sym) return CON_ROWS[i];
  return null;
}

// A factor entry for a symbol in one dimension, or null. A constant of the same
// dimension is a factor too - "150 tonnes is 25 elephants" is a ratio of two
// rows, which is why a spread may name a row as its target.
function conFactor(dim, sym) {
  let table = CON_FACTORS[dim];
  if (table !== undefined && Object.prototype.hasOwnProperty.call(table, sym)) {
    let u = table[sym];
    return { sym: sym, factor: u[0], one: u[1], many: u[2] };
  }
  let row = conRow(sym);
  // `row: true` is what makes a reading read as English: a unit target keeps
  // its symbol ("408.136 ft"), while a target that is another ROW is a noun and
  // inflects ("25 elephants", never "25 elephant").
  if (row !== null && row.dim === dim) return { sym: sym, factor: row.value, one: row.one, many: row.many, row: true };
  return null;
}

var _conFactorKeys = null;

// Every unit symbol of a dimension, keyed the way a typed target is keyed.
// Cached, because the table does not change and the target path runs on a
// keystroke.
function conFactorKeys(dim) {
  if (_conFactorKeys === null) _conFactorKeys = {};
  if (_conFactorKeys[dim] === undefined) {
    let m = {};
    let table = CON_FACTORS[dim];
    for (let s in table) {
      if (Object.prototype.hasOwnProperty.call(table, s)) m[conKey(s)] = s;
    }
    _conFactorKeys[dim] = m;
  }
  return _conFactorKeys[dim];
}

// The canonical symbol a typed target names: a row of the same dimension first
// ("elephants"), then a unit of the dimension ("kt tnt", "rs25"). Null when
// neither, which is a target this row cannot be read in.
function conTargetSym(dim, text) {
  let k = conKey(text);
  if (k === "") return null;
  let row = conNames()[k];
  if (row !== undefined && row.dim === dim) return row.sym;
  let keys = conFactorKeys(dim);
  return keys[k] === undefined ? null : keys[k];
}

// One reading of a row: value (in the row's base unit) into the target.
// `qty` is how many of the thing the query asked for.
function conReading(row, qty, target) {
  let t = conFactor(row.dim, target);
  if (t === null) return null;
  let out = row.value * qty / t.factor;
  if (!isFinite(out)) return null;
  let subject = qty === 1 ? row.one : conNumber(qty) + " " + row.many;
  let noun = Math.abs(out) === 1 ? t.one : t.many;
  let unitText = t.row === true ? noun : t.sym;
  return {
    ok: true,
    value: row.value * qty,
    from: row.sym,
    to: t.sym,
    out: out,
    formatted: conNumber(out),
    copy: conNumber(out) + " " + unitText,
    label: subject + " = " + conNumber(out) + " " + unitText,
    phrase: subject + " is " + conNumber(out) + " " + noun,
    uid: "constants:" + conKey(row.sym) + ":" + t.sym,
    subject: subject
  };
}

// The list a bare query answers with: the row's own default, then its spread.
// The dimension is NOT fanned out - a constant is a fact, not a quantity, so
// the readings it is said in are the list. Ten is the launcher's own card
// ceiling (LauncherPanel's slotLimit), and it is also the most rows a reading
// and its neighbours get between them: past ten the card scrolls.
var CON_MAX = 10;

function conTargets(row) {
  let list = [row.def];
  for (let i = 0; i < row.spread.length; i++) {
    if (row.spread[i] !== row.def) list.push(row.spread[i]);
  }
  return list;
}

// The relation graph: the neighbours a reader asks about next, by row symbol.
// It is kept out of the rows because it describes the table's shape rather than
// a measurement - a row with no entry simply has no relations - and a pair is
// stored once per direction because the order is the reading order.
var CON_RELATIONS = {
  // A bare version names the SHIP that flies; the stack is that name plus
  // "stack". So each row names the other end of the vehicle, its booster, the
  // tower that catches the booster, and the neighbouring versions - which is
  // what lets "starship" show the ship with the stack beside it.
  "Starship V3": ["Starship ship V3", "Super Heavy V3", "Mechazilla", "Starship V2", "Starship V1"],
  "Starship V2": ["Starship ship V2", "Starship V3", "Starship V1", "Super Heavy V2"],
  "Starship V1": ["Starship ship V1", "Starship V2", "Starship V3", "Super Heavy V1"],
  "Starship ship V3": ["Starship V3", "Super Heavy V3", "Mechazilla", "Starship ship V2", "Starship ship V1"],
  "Starship ship V2": ["Starship V2", "Super Heavy V2", "Starship ship V3"],
  "Starship ship V1": ["Starship V1", "Super Heavy V1", "Starship ship V3"],
  "Super Heavy V3": ["Starship V3", "Super Heavy thrust", "Mechazilla"],
  "Super Heavy V2": ["Super Heavy V3", "Starship V2"],
  "Super Heavy V1": ["Super Heavy V2", "Starship V1"],
  "Mechazilla": ["Starship V3", "Super Heavy V3"],
  // A stack is also a thrust figure, and a thrust figure is an engine count.
  "Super Heavy thrust": ["Super Heavy V3", "Raptor 3"],
  "SLS Block 1": ["SLS Block 1B", "SLS thrust", "SLS launch tower"],
  "SLS thrust": ["SLS Block 1", "RS-25"],
  "Saturn V": ["Saturn V launch tower", "Saturn V thrust", "F-1", "SLS Block 1"],
  "Saturn V thrust": ["Saturn V", "F-1"],
  "RS-25": ["RS-25 vacuum", "SLS Block 1", "SLS thrust"],
  "RS-25 vacuum": ["RS-25", "SLS Block 1"],
  "SLS Block 1B": ["SLS Block 1", "SLS thrust"],
  "F-1": ["F-1 vacuum", "Saturn V", "Saturn V thrust"],
  "F-1 vacuum": ["F-1", "Saturn V"],
  // Every rocket names the structure it rides beside, and every tower names its
  // rocket back - one row of the vehicle and one of the tower, the same pairing
  // Mechazilla has with the Starship stack.
  "Falcon 9": ["Falcon launch tower", "Falcon Heavy", "Merlin 1D"],
  "Merlin 1D": ["Merlin 1D vacuum", "Falcon 9", "Falcon Heavy"],
  "Merlin 1D vacuum": ["Merlin 1D", "Falcon 9"],
  "RD-180": ["RD-180 vacuum", "Atlas V"],
  "RD-180 vacuum": ["RD-180", "Atlas V"],
  "Falcon Heavy": ["Falcon launch tower", "Falcon 9"],
  "Ariane 6": ["Ariane 6 launch tower"],
  "Atlas V": ["SLC-41 tower", "Vulcan Centaur", "RD-180"],
  "Vulcan Centaur": ["SLC-41 tower", "Atlas V", "BE-4"],
  "Delta IV Heavy": ["Delta IV launch tower"],
  "Space Shuttle": ["Shuttle launch tower"],
  "Saturn V launch tower": ["Saturn V", "SLS launch tower"],
  "Shuttle launch tower": ["Space Shuttle", "SLS launch tower"],
  "SLS launch tower": ["SLS Block 1", "Saturn V launch tower", "Shuttle launch tower"],
  "Falcon launch tower": ["Falcon 9", "Falcon Heavy"],
  "Ariane 6 launch tower": ["Ariane 6"],
  "SLC-41 tower": ["Atlas V", "Vulcan Centaur"],
  "Delta IV launch tower": ["Delta IV Heavy"],
  "BE-4": ["Northstar", "New Glenn", "Vulcan Centaur"],
  "Northstar": ["BE-4", "New Glenn"],
  "New Glenn": ["BE-4", "Northstar"],
  // A Raptor is a family: the vacuum variant is the one the ship burns in
  // space, and the older sea-level ratings are the same lineage.
  "Raptor 3": ["Raptor 3 vacuum", "Raptor 3 max", "Raptor 2", "Raptor 1"],
  "Raptor 3 max": ["Raptor 3", "Raptor 3 vacuum", "Raptor 2"],
  "Raptor 3 vacuum": ["Raptor 3", "Raptor 2 vacuum", "Raptor 2"],
  "Raptor 2": ["Raptor 3", "Raptor 2 vacuum", "Raptor 1"],
  "Raptor 2 vacuum": ["Raptor 2", "Raptor 3 vacuum"],
  "Raptor 1": ["Raptor 1 vacuum", "Raptor 2", "Raptor 3"],
  "Raptor 1 vacuum": ["Raptor 1", "Raptor 2 vacuum"],
  "Burj Khalifa": ["Merdeka 118", "Shanghai Tower"],
  "Merdeka 118": ["Burj Khalifa", "Shanghai Tower"],
  "Voyager 1": ["Voyager 2"],
  "Voyager 2": ["Voyager 1"],
  "escape velocity": ["low Earth orbit speed", "geostationary speed", "Moon escape velocity"],
  "low Earth orbit speed": ["escape velocity", "geostationary speed"],
  "geostationary speed": ["low Earth orbit speed", "escape velocity"],
  "Jupiter escape velocity": ["Jupiter orbital velocity", "escape velocity"],
  // An orbit is quoted per body, and each speed pairs with the escape velocity
  // it is derived from, plus the next body a reader would compare against.
  "Moon escape velocity": ["Moon orbital velocity", "escape velocity", "Mars escape velocity"],
  "Moon orbital velocity": ["Moon escape velocity", "low Earth orbit speed"],
  "Mars escape velocity": ["Mars orbital velocity", "escape velocity"],
  "Mars orbital velocity": ["Mars escape velocity", "Moon orbital velocity"],
  "Io orbital velocity": ["Titan orbital velocity", "Jupiter orbital velocity"],
  "Titan orbital velocity": ["Io orbital velocity", "Moon orbital velocity"],
  "Jupiter orbital velocity": ["Jupiter escape velocity", "Io orbital velocity"]
};

// The neighbours to append, in graph order, each once and never the row itself.
// No ceiling of its own: a relation is another row of the same answer, so it
// shares CON_MAX with the readings and is trimmed there - never by a number of
// its own, which would silently drop a row the graph names. A name the table
// does not know is dropped: that is a stale entry in the graph, never an answer.
function conRelated(row, seen) {
  let list = CON_RELATIONS[row.sym];
  let out = [];
  if (list === undefined) return out;
  for (let i = 0; i < list.length; i++) {
    // A relation names a row by its SYMBOL first, then as a name: "Starship V3"
    // is the stack, while the bare name starshipv3 belongs to the ship - so the
    // symbol lookup has to win, or a relation can resolve to the row asking it.
    let rel = conRow(list[i]);
    if (rel === null) rel = conNames()[conKey(list[i])];
    if (rel === undefined || rel === null || rel === row || seen[rel.sym] === true) continue;
    seen[rel.sym] = true;
    out.push(rel);
  }
  return out;
}

// Engines that publish both ratings: [sea level row, vacuum row]. Any engine not
// listed here has no vacuum figure in the table, so the keywords below do not
// apply to it and the query falls through to the normal lookup.
var CON_ENGINE_PAIRS = [
  ["Raptor 3", "Raptor 3 vacuum"], ["Raptor 2", "Raptor 2 vacuum"],
  ["Raptor 1", "Raptor 1 vacuum"], ["RS-25", "RS-25 vacuum"],
  ["F-1", "F-1 vacuum"], ["Merlin 1D", "Merlin 1D vacuum"],
  ["RD-180", "RD-180 vacuum"]
];

// Optional trailing keywords: "sea level" / "sl", "vacuum" / "vac", and "ratio"
// (also "sl/vac ratio", "sea level vacuum ratio"). Tried only after the whole
// text failed as a name, so "raptor 3 vacuum" stays its own row and "raptor 3 sl"
// is never rescued as a typo of "raptor 3".
var RE_CON_ENGINE_KW = /^(.+?)\s+(?:(sea[\s-]*level|sl)|(vacuum|vac)|((?:(?:sea[\s-]*level|sl)\s*\/?\s*(?:vacuum|vac)\s*)?ratio))(?:\s+thrust)?$/i;

function conEnginePair(row) {
  for (let i = 0; i < CON_ENGINE_PAIRS.length; i++) {
    if (CON_ENGINE_PAIRS[i][0] === row.sym || CON_ENGINE_PAIRS[i][1] === row.sym) {
      return { sl: conRow(CON_ENGINE_PAIRS[i][0]), vac: conRow(CON_ENGINE_PAIRS[i][1]) };
    }
  }
  return null;
}

// Returns { row, ratio, pair } for an engine keyword query, or null.
function conEngineKeyword(text) {
  let t = String(text).trim();
  if (conNamed(t) !== undefined) return null;
  let m = t.match(RE_CON_ENGINE_KW);
  if (m === null) return null;
  let base = conLookup(m[1]);
  if (base === undefined || base.dim !== "force") return null;
  let pair = conEnginePair(base);
  if (pair === null || pair.sl === null || pair.vac === null) return null;
  if (m[4] !== undefined) return { row: pair.sl, ratio: true, pair: pair };
  return { row: m[2] !== undefined ? pair.sl : pair.vac, ratio: false, pair: pair };
}

// The ratio as one reading: sea level thrust over vacuum thrust, unitless.
function conRatioReading(pair) {
  let r = pair.sl.value / pair.vac.value;
  let pct = conNumber(r * 100);
  let subject = pair.sl.one + " sea level / vacuum thrust";
  return {
    ok: true,
    value: r,
    from: pair.sl.sym,
    to: "ratio",
    out: r,
    formatted: conNumber(r),
    copy: conNumber(r),
    label: subject + " = " + conNumber(r) + " (" + pct + "%)",
    phrase: pair.sl.one + " makes " + pct + "% of its vacuum thrust at sea level",
    uid: "constants:" + conKey(pair.sl.sym) + ":ratio",
    subject: subject
  };
}

// The query, split into a quantity, a row and an optional target. Returns null
// for anything that is not this plugin's shape - which is the normal case, since
// this plugin is asked on every keystroke - and a hint record for a query that
// names a row but asks for something it cannot answer.
function parseConstant(query) {
  let raw = String(query === undefined || query === null ? "" : query).trim();
  if (raw === "" || raw.length > 128) return null;
  if (raw.indexOf("\n") >= 0 || raw.indexOf("\r") >= 0) return null;
  // A trailing politeness or question mark is noise, as it is in the converter.
  raw = raw.replace(/\s+(?:please|pls)\b[\s?!]*$/i, "").replace(/[?!]+$/, "").trim();
  if (raw.substring(0, 4).toLowerCase() === "the ") raw = raw.substring(4).trim();

  let target = null;
  let head = raw;
  let m = raw.match(RE_CON_SPLIT);
  if (m !== null) {
    head = m[1].trim();
    target = m[2].trim();
  }
  if (head.substring(0, 4).toLowerCase() === "the ") head = head.substring(4).trim();

  let qty = 1;
  let nameText = head;
  let num = head.match(RE_CON_NUM);
  if (num !== null) {
    qty = Number(num[0].replace(/,/g, ""));
    if (!isFinite(qty)) return null;
    nameText = head.substring(num[0].length).trim();
    if (nameText === "") return null;
  }
  let kw = conEngineKeyword(nameText);
  if (kw !== null && kw.ratio === true) {
    // A ratio is unitless: a target or a quantity has nothing to act on.
    if (target !== null || qty !== 1) return null;
    return { ok: true, row: kw.row, qty: 1, target: null, bare: false, ratio: true, pair: kw.pair,
      typo: _conTypoRow !== null, inputText: raw };
  }
  let row = kw !== null ? kw.row : conLookup(nameText);
  if (row === undefined) return null;
  // A typo rescue answers, but the rows it produces carry the guess: the name as
  // typed is not in the table, and the card has to be able to say so.
  let guessed = _conTypoRow !== null;

  if (target === null) {
    return { ok: true, row: row, qty: qty, target: null, bare: true, typo: guessed, inputText: raw };
  }
  let t = conTargetSym(row.dim, target);
  if (t === null) {
    // A target that resolves in the CONVERTER but not here is a unit this
    // table does not quote rows in; a word that resolves nowhere is a typo.
    // Both are the same answer: name a reading this row has.
    return { ok: false, error: "unknown-target", row: row, qty: qty, typo: guessed,
      label: "Unknown unit '" + target + "'", sub: "try: " + conTargets(row).slice(0, 4).join(", "),
      expr: raw, subjectLabel: row.one };
  }
  return { ok: true, row: row, qty: qty, target: t, bare: false, typo: guessed, inputText: raw };
}

// A dimension mismatch cannot happen through a named target (conFactor is
// per-dimension), but a reading that overflows or underflows can, and it is a
// statement about the row rather than about the request.
function conOutOfRange(row) {
  return row.value === 0 || !isFinite(row.value);
}

// The entries. rows() is the whole list for a query - one row for an explicit
// target, up to CON_MAX for a bare name - and it is never null: a query this
// plugin does not claim is an empty array, so the launcher falls through to the
// engines below it.
function tryConstants(query) {
  let q = parseConstant(query);
  if (q === null) return [];
  if (q.ok === false) return [q];
  if (conOutOfRange(q.row)) {
    return [{ ok: false, error: "out-of-range", expr: String(query).trim(),
      label: "Result out of range", sub: "the table has no number for it" }];
  }
  if (q.ratio === true) {
    let out = [conRatioReading(q.pair)];
    let seen2 = {};
    seen2[q.pair.sl.sym] = true;
    // The two ratings the ratio is made of, in their own default units.
    let both = [q.pair.sl, q.pair.vac];
    for (let i = 0; i < both.length; i++) {
      let r = conReading(both[i], 1, both[i].def);
      if (r === null) continue;
      r.related = true;
      out.push(r);
    }
    if (q.typo === true) out[0].typo = true;
    return out;
  }
  if (q.bare === false) {
    let one = conReading(q.row, q.qty, q.target);
    if (one === null) return [];
    if (q.typo === true) one.typo = true;
    return [one];
  }
  let targets = conTargets(q.row);
  let out = [];
  let seen = {};
  seen[q.row.sym] = true;
  for (let i = 0; i < targets.length && out.length < CON_MAX; i++) {
    let r = conReading(q.row, q.qty, targets[i]);
    if (r === null) continue;
    // The reading is a record of its own, so the guess has to be copied onto
    // every reading of the answer. Relations are not guesses and stay clean.
    if (q.typo === true) r.typo = true;
    out.push(r)
  }
  // Relations after the readings, one of each thing whatever the quantity was:
  // "3 starships" is still one Super Heavy next to them. They share CON_MAX
  // with the readings, so a row with many neighbours fills what is left of the
  // card rather than growing past it.
  let rels = conRelated(q.row, seen);
  for (let i = 0; i < rels.length && out.length < CON_MAX; i++) {
    let r = conReading(rels[i], 1, rels[i].def);
    if (r === null) continue;
    r.related = true;
    out.push(r);
  }
  return out;
}

// The per-keystroke gate. A query is this plugin's when its head names a row;
// every app name, every arithmetic expression and every plain unit query is
// not, and the check is one hash lookup rather than a scan of the table.
function isPotentialConstant(query) {
  return parseConstant(query) !== null;
}

// Named-constants engine plugin: one row per reading. ConstantsLib source
// (pure JS, no imports) is concatenated above this contract; the IIFE below
// only adapts it to VibraniumPlugin.
(function() {
  let api = null
  VibraniumPlugin = {
    init: function(context) {
      api = context
    },
    items: function(query) {
      const trimmed = String(query || "").trim()
      if (trimmed === "") return []
      if (!isPotentialConstant(query)) return []
      const results = tryConstants(query)
      if (!results || results.length === 0) return []
      // A word this table does not know is a miss, not an answer: the card
      // replaces the whole result list, so a hint here would hide every
      // application match. The other failures are statements about what was
      // asked and stay as one hint row.
      if (results[0].error === "unknown-target") return []
      // A shipped asset name (shell/assets/icons), not an XDG spelling: the
      // chip renders through ui/Icon, which resolves names from that set only.
      const icon = api.setting("shell.launcher.showIcons") !== false ? "calculator" : ""
      const rows = []
      for (let i = 0; i < results.length; i++) {
        const r = results[i]
        // The uid names the TARGET, not the plugin: a bare name answers with
        // several readings at once, and one uid for the set would collapse
        // them into one identity.
        if (!r.ok) {
          rows.push({
            kind: "constants",
            uid: "constants:hint",
            label: r.label,
            sub: r.sub,
            desc: "",
            icon: icon,
            incomplete: true,
            item: { copyValue: "" }
          })
          continue
        }
        rows.push({
          kind: "constants",
          uid: r.uid,
          label: r.label,
          // The reading again as a sentence: the title is the compact form to
          // scan, and this is the one to read.
          sub: r.phrase,
          // A typo rescue is an answer, but not the name that was typed: the
          // flag says so, and the description names the row it was read as.
          desc: r.typo === true ? "Read as " + r.from + ": the name as typed is not in the table" : "",
          icon: icon,
          incomplete: false,
          typo: r.typo === true,
          item: { copyValue: r.copy }
        })
      }
      return rows
    },
    activate: function(item) {
      const v = String(item && item.copyValue || "")
      if (v === "") return
      api.execDetached("printf %s " + api.shellQuote(v) + " | wl-copy")
    }
  }
})()
