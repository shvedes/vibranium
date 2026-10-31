// Currency engine for AppLauncher: natural-language
// "<value><currency> [in|to|as|-> = <currency>]" plus bare
// "<value><currency>" with a per-currency default target. Pure-JS, no Qt
// imports, and no network either: the rate table is an argument, so every
// function here is drivable offline against a fixture.
//
// Usage: FxLib.isPotentialFx(query) -> bool (cheap gate)
//        FxLib.tryConvert(query, snapshot) -> null | result
//        FxLib.tryAll(query, snapshot, history) -> null | result[]
//   snapshot: { base, rates, updated } from parseRates(), or null/undefined
//             while the fetch has not landed. Absent is a pending row, not
//             a failure - the two states are not the same and must not read
//             the same.
//   history:  { CODE: count } of currencies the user has picked before, or
//             null/undefined when there is none. It reorders the bare list
//             and never filters it; absent is the documented default order.
//   ok:   { ok: true, pending: false, value, from, to, out, rate,
//           formatted, copy, phrase, desc, label, inputText, updated }
//   wait: { ok: true, pending: true, value, from, to, label, inputText,
//           sub }
//   hint: { ok: false, error: "incomplete"|"unknown-target"|"same-target"|
//           "unsupported"|"unavailable"|"out-of-range", expr, label, sub }
// null means "not a currency query" - caller falls through to apps.
//
// A bare amount has no target of its own, so it answers with a LIST: the
// default first, then the rest of SUGGEST, permuted by what the user has
// picked before (see rankTargets). tryConvert is the single-answer half - what
// an explicit pair asks for, and the head of a bare list - and both run the
// same parse.
//
// An answer carries the pair three ways: `copy` is what lands on the clipboard,
// `label` is the compact form the row is titled with, and `phrase` is the same
// conversion as a sentence - "100 US Dollars is 87.84 Euros" - which is what
// the row's sub line says.
//
// THE PROVIDER
//
// One GET, no key, no signup, no header, no quota to negotiate:
// open.er-api.com's open endpoint. It answers with every rate it quotes,
// all against one base, so a single cached response serves every pair -
// cross-rates come from dividing two entries of the same table rather than
// from a second request per source currency.
//
// The code list is NOT spelled out here. A currency the table below does not
// name is still reachable by its three-letter ISO code, and the rate table
// decides whether it is real. So the set of currencies this engine answers
// is the provider's set, and cannot drift from it the way a hand-kept list
// would. The table below is only what adds a name, a symbol and a
// deliberate presence in the bare-query path.

// The base every cached table is quoted against, and therefore the answer a
// bare query defaults to. Changing it changes the fetch URL and the
// cross-rate base together; the arithmetic in tryConvert is base-agnostic.
var RATE_BASE = "USD"
var RATE_URL = "https://open.er-api.com/v6/latest/" + RATE_BASE

// Symbols the table answers to, longest spelling first so "R$" is read
// before "$". Every one of them is ambiguous in the wild - "$" is a dozen
// currencies and the yen sign belongs to two - so each resolves to the
// currency it most often stands for, and the ISO code is always there for
// the rest.
var SYMBOLS = [
  { sym: "R$", code: "BRL" },
  { sym: "US$", code: "USD" },
  { sym: "$", code: "USD" },
  { sym: "\u20ac", code: "EUR" },
  { sym: "\u00a3", code: "GBP" },
  { sym: "\u00a5", code: "JPY" },
  { sym: "\u20b9", code: "INR" },
  { sym: "\u20bd", code: "RUB" },
  { sym: "\u20a9", code: "KRW" },
  { sym: "\u20ba", code: "TRY" }
];

// Codes worth naming, with the words a person actually types. A bare
// "<value><currency>" is only claimed from THIS table (see parseQuery), so
// membership here is also what makes an unadorned amount a currency query
// at all - which is what keeps "5 m" and "100 abc" falling through to the
// app list. Codes that are merely three letters reach the engine through
// resolveCode, and only behind a named source.
var CURRENCIES = [
  { code: "USD", names: ["usd", "dollar", "dollars", "usdollars"] },
  { code: "EUR", names: ["eur", "euro", "euros"] },
  { code: "GBP", names: ["gbp", "pound", "pounds", "sterling"] },
  { code: "JPY", names: ["jpy", "yen"] },
  { code: "CHF", names: ["chf", "franc", "francs", "swissfranc"] },
  { code: "CAD", names: ["cad", "canadiandollar", "canadiandollars"] },
  { code: "AUD", names: ["aud", "australiandollar", "australiandollars"] },
  { code: "NZD", names: ["nzd", "kiwi"] },
  { code: "CNY", names: ["cny", "renminbi", "yuan"] },
  { code: "CNH", names: ["cnh"] },
  { code: "HKD", names: ["hkd", "hongkongdollar"] },
  { code: "SGD", names: ["sgd", "singaporedollar"] },
  { code: "INR", names: ["inr", "rupee", "rupees", "indianrupee"] },
  { code: "KRW", names: ["krw", "won"] },
  { code: "RUB", names: ["rub", "ruble", "rubles", "rouble"] },
  { code: "BRL", names: ["brl", "real", "reais", "r$"] },
  { code: "TRY", names: ["try", "lira", "liras"] },
  { code: "MXN", names: ["mxn", "peso", "pesos", "mexicanpeso"] },
  { code: "ZAR", names: ["zar", "rand"] },
  { code: "SEK", names: ["sek", "swedishkrona"] },
  { code: "NOK", names: ["nok", "norwegiankrone"] },
  { code: "DKK", names: ["dkk", "danishkrone"] },
  { code: "PLN", names: ["pln", "zloty", "zlotys", "zl"] },
  { code: "CZK", names: ["czk", "koruna"] },
  { code: "HUF", names: ["huf", "forint"] },
  { code: "RON", names: ["ron", "leu"] },
  { code: "MDL", names: ["mdl"] },
  { code: "ILS", names: ["ils", "shekel"] },
  { code: "AED", names: ["aed", "dirham", "dirhams"] },
  { code: "SAR", names: ["sar", "riyal"] },
  { code: "QAR", names: ["qar"] },
  { code: "KWD", names: ["kwd"] },
  { code: "BHD", names: ["bhd"] },
  { code: "OMR", names: ["omr"] },
  { code: "JOD", names: ["jod"] },
  { code: "THB", names: ["thb", "baht"] },
  { code: "IDR", names: ["idr", "rupiah"] },
  { code: "MYR", names: ["myr", "ringgit"] },
  { code: "PHP", names: ["php", "piso", "pisoes", "philippinepeso"] },
  { code: "VND", names: ["vnd", "dong"] },
  { code: "PKR", names: ["pkr"] },
  { code: "BDT", names: ["bdt", "taka"] },
  { code: "LKR", names: ["lkr"] },
  { code: "NPR", names: ["npr", "nepaleserupee"] },
  { code: "UAH", names: ["uah", "hryvnia"] },
  { code: "EGP", names: ["egp", "egyptianpound"] },
  { code: "NGN", names: ["ngn", "naira"] },
  { code: "KES", names: ["kes", "shilling"] },
  { code: "GHS", names: ["ghs", "cedi"] },
  { code: "MAD", names: ["mad"] },
  { code: "TND", names: ["tnd"] },
  { code: "LYD", names: ["lyd"] },
  { code: "DZD", names: ["dzd"] },
  { code: "ETB", names: ["etb", "birr"] },
  { code: "TZS", names: ["tzs"] },
  { code: "UGX", names: ["ugx"] },
  { code: "ZMW", names: ["zmw", "kwacha"] },
  { code: "MZN", names: ["mzn"] },
  { code: "AOA", names: ["aoa", "kwanza"] },
  { code: "MUR", names: ["mur"] },
  { code: "BWP", names: ["bwp", "pula"] },
  { code: "NAD", names: ["nad"] },
  { code: "ZWL", names: ["zwl"] },
  { code: "ARS", names: ["ars"] },
  { code: "CLP", names: ["clp"] },
  { code: "COP", names: ["cop"] },
  { code: "UYU", names: ["uyu"] },
  // No "sol": it is the Martian day in the unit table, and a bare "1 sol" was
  // answered by both engines. The ISO code still reaches PEN.
  { code: "PEN", names: ["pen"] },
  { code: "BOB", names: ["bob", "boliviano"] },
  { code: "PYG", names: ["pyg", "guarani"] },
  { code: "VES", names: ["ves"] },
  { code: "CRC", names: ["crc", "colon"] },
  // CUP (Cuban peso) is deliberately not named: "2 cup" is a measuring cup
  // far more often, and a named entry is what lets a bare amount claim the
  // keystroke. "100 usd in cup" still works through the ISO fallback.
  { code: "DOP", names: ["dop", "dominicanpeso"] },
  { code: "GTQ", names: ["gtq", "quetzal"] },
  { code: "HNL", names: ["hnl", "lempira"] },
  { code: "NIO", names: ["nio", "cordoba"] },
  { code: "AWG", names: ["awg", "arubanflorin"] },
  { code: "ANG", names: ["ang"] },
  { code: "SRD", names: ["srd"] },
  { code: "GYD", names: ["gyd"] },
  { code: "BSD", names: ["bsd"] },
  { code: "BBD", names: ["bbd"] },
  { code: "BMD", names: ["bmd"] },
  { code: "KYD", names: ["kyd"] },
  { code: "JMD", names: ["jmd"] },
  { code: "TTD", names: ["ttd"] },
  { code: "XCD", names: ["xcd", "eastcaribbeandollar"] },
  { code: "HTG", names: ["htg", "gourde"] },
  { code: "JEP", names: ["jep"] },
  { code: "GGP", names: ["ggp", "guernseypound"] },
  { code: "IMP", names: ["imp"] },
  { code: "FKP", names: ["fkp"] },
  { code: "SHP", names: ["shp"] },
  { code: "ISK", names: ["isk"] },
  { code: "RSD", names: ["rsd", "dinar"] },
  { code: "BAM", names: ["bam", "mark"] },
  { code: "MKD", names: ["mkd"] },
  { code: "BGN", names: ["bgn", "lev"] },
  { code: "HRK", names: ["hrk", "kuna"] },
  { code: "ALL", names: ["all", "lek"] },
  { code: "AZN", names: ["azn", "manat"] },
  { code: "GEL", names: ["gel", "lari"] },
  { code: "KZT", names: ["kzt", "tenge"] },
  { code: "UZS", names: ["uzs", "sum"] },
  { code: "KGS", names: ["kgs"] },
  { code: "MNT", names: ["mnt"] },
  { code: "TJS", names: ["tjs"] },
  { code: "TMT", names: ["tmt"] },
  { code: "AFN", names: ["afn", "afghani"] },
  { code: "IRR", names: ["irr", "rial"] },
  { code: "IQD", names: ["iqd"] },
  { code: "LBP", names: ["lbp"] },
  { code: "YER", names: ["yer"] },
  { code: "SYP", names: ["syp"] },
  { code: "BND", names: ["bnd"] },
  { code: "BTN", names: ["btn", "ngultrum"] },
  { code: "MOP", names: ["mop", "pataca"] },
  { code: "TWD", names: ["twd"] },
  { code: "MVR", names: ["mvr", "rufiyaa"] },
  { code: "KHR", names: ["khr", "riel"] },
  { code: "LAK", names: ["lak", "kip"] },
  { code: "MMK", names: ["mmk", "kyat"] },
  { code: "FJD", names: ["fjd"] },
  { code: "PGK", names: ["pgk"] },
  { code: "SBD", names: ["sbd"] },
  { code: "TOP", names: ["top"] },
  { code: "WST", names: ["wst"] },
  { code: "VUV", names: ["vuv"] },
  { code: "XPF", names: ["xpf"] },
  { code: "KID", names: ["kid"] },
  { code: "TVD", names: ["tvd"] },
  { code: "ERN", names: ["ern", "nakfa"] },
  { code: "SSP", names: ["ssp"] },
  { code: "SDG", names: ["sdg"] },
  { code: "SOS", names: ["sos"] },
  { code: "SLE", names: ["sle"] },
  { code: "ZWG", names: ["zwg"] },
  { code: "BZD", names: ["bzd"] },
  { code: "GMD", names: ["gmd", "dalasi"] },
  { code: "GIP", names: ["gip"] },
  { code: "STN", names: ["stn", "dobra"] },
  { code: "SZL", names: ["szl", "lilangeni"] },
  { code: "LSL", names: ["lsl", "loti"] },
  { code: "LRD", names: ["lrd"] },
  { code: "CVE", names: ["cve"] },
  { code: "MWK", names: ["mwk"] },
  { code: "BIF", names: ["bif"] },
  { code: "DJF", names: ["djf"] },
  { code: "GNF", names: ["gnf"] },
  { code: "KMF", names: ["kmf"] },
  { code: "MGA", names: ["mga", "ariary"] },
  { code: "MRU", names: ["mru", "ouguiya"] },
  { code: "XAF", names: ["xaf"] },
  { code: "XOF", names: ["xof"] },
  { code: "XCG", names: ["xcg"] }
];

// A leading amount, with optional thousands grouping and an optional
// leading decimal point ("0.5" and ".5" are the same number and both are
// typed). No exponent: a money amount is not scientific notation, and
// allowing one would let "1e3m" reach the currency parser.
var RE_AMOUNT = /^[+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)/;

var RE_ARROW = /\s*-+\s*>\s*/g;

var _namedMap = null;

function namedMap() {
  if (_namedMap !== null) return _namedMap;
  var m = {};
  for (var i = 0; i < CURRENCIES.length; i++) {
    var c = CURRENCIES[i];
    // `named` is what the bare-query path gates on, so it is set here once
    // rather than repeated as a field on every entry.
    m[c.code.toLowerCase()] = { code: c.code, named: true };
    for (var j = 0; j < c.names.length; j++) {
      m[normalizeCurrency(c.names[j])] = { code: c.code, named: true };
    }
  }
  _namedMap = m;
  return m;
}

// Lowercase, drop spaces/underscores/dashes, so "us dollars" and
// "US-Dollars" reach the same entry.
function normalizeCurrency(s) {
  var t = String(s === undefined || s === null ? "" : s).toLowerCase().trim();
  t = t.replace(/[_-]+/g, "");
  t = t.replace(/\s+/g, "");
  t = t.replace(/\.+$/g, "");
  return t;
}

function num(v) {
  return typeof v === "number" && isFinite(v) ? v : null;
}

// One table entry as a usable rate: finite, and not zero. Zero is refused
// because it is a provider fault rather than a rate, and the two directions it
// fails in are different - as a target it prints a conversion to nothing, as
// a source it divides to infinity - so both have to be caught before the
// product, not after it.
function rateOf(rates, code) {
  if (rates === null || rates === undefined || code === null || code === undefined) return null;
  var v = num(rates[code]);
  return v === null || v === 0 ? null : v;
}

// A code the engine will accept. Anything the provider quotes reaches here
// as a bare three-letter code; whether it is real is decided later, against
// the rate table, in tryConvert. Named entries are the ones a bare query
// may stand on.
function resolveCode(spec) {
  var k = normalizeCurrency(spec);
  if (k === "") return null;
  var m = namedMap();
  if (Object.prototype.hasOwnProperty.call(m, k)) return m[k];
  if (k.length === 3 && /^[a-z]+$/.test(k)) return { code: k.toUpperCase(), named: false };
  return null;
}

// A currency symbol at the very front ("$100 in eur"), longest spelling
// first. Returns "" when the text does not open with one.
function leadingSymbol(s) {
  var t = String(s === undefined || s === null ? "" : s).trim();
  for (var i = 0; i < SYMBOLS.length; i++) {
    if (t.indexOf(SYMBOLS[i].sym) === 0) return SYMBOLS[i].sym;
  }
  return "";
}

function symbolCode(sym) {
  for (var i = 0; i < SYMBOLS.length; i++) {
    if (sym === SYMBOLS[i].sym) return SYMBOLS[i].code;
  }
  return "";
}

// Cheap gate for the per-keystroke path. A currency query opens with an
// amount or with a symbol, and carries at least one letter-ish character.
// Plain app names ("firefox"), pure math ("2+2") and "time in X" all fail
// here before any table is touched.
function isPotentialFx(query) {
  var t = String(query === undefined || query === null ? "" : query).trim();
  if (t === "" || t.length > 128) return false;
  if (t.indexOf("\n") >= 0 || t.indexOf("\r") >= 0) return false;
  if (!RE_AMOUNT.test(t) && leadingSymbol(t) === "") return false;
  if (!/[a-zA-Z$\u20ac\u00a3\u00a5\u20b9\u20bd\u20a9\u20ba]/.test(t)) return false;
  return true;
}

// Split "100 usd in eur" into head/target on the LAST keyword, so a
// currency whose own name contains one ("100 try in usd", where the Turkish
// lira is TRY) still splits at the separator and not inside the code.
function splitExplicit(body) {
  var m = String(body).match(/^(.*)\s+(in|to|as|->|=)\s+(.+?)\s*$/i);
  if (m) return { head: m[1], key: m[2], tail: m[3] };
  var m2 = String(body).match(/^(.*)\s+(in|to|as|->|=)\s*$/i);
  if (m2) return { head: m2[1], key: m2[2], tail: "" };
  return null;
}

// Where a bare "<value><currency>" goes. The table's base is the answer for
// everything else, because "how much is this worth" is asked in dollars far
// more often than in any other single unit; the base itself has to name
// something else or "100 usd" would convert one dollar into one dollar.
function defaultTarget(code) {
  return code === RATE_BASE ? "EUR" : RATE_BASE;
}

// How many rows a bare amount may answer with. Ten rather than the unit
// engine's six: a currency list is a set of comparisons between equals, so
// there is no dimension noise to spend rows on, and the majors are the
// destinations an amount is actually weighed against.
var MAX_TARGETS = 10;

// The currencies a bare amount is offered, in the order the rows are shown
// when the user has no history to say otherwise. This is the DEFAULT order,
// not a seed that is always reshuffled: with an empty cache every count is
// zero and the rows come out exactly as written here.
//
// The head of the list is the fetch base and the fetch base is the second
// entry, so the documented default of a bare query ("100 usd" reads as euros)
// is the first row until a history moves it, and the base's own list leads
// with the base's default as well.
var SUGGEST = ["USD", "CAD", "EUR", "GBP", "CHF", "PLN", "UAH", "RUB",
  "JPY", "CNY", "AUD", "INR", "KRW", "BRL", "MXN", "SEK", "NOK", "ZAR", "TRY"];

// The order the rows are shown in for one source. Two inputs and nothing else:
// the base list above, and how often the user has picked each currency.
//
// The merge is a permutation and never a filter, which is the property that
// makes the base list the default rather than a starting guess - with no
// history every count is zero and this returns SUGGEST verbatim. Counts are
// compared as numbers and the base POSITION breaks every tie, so two
// currencies picked equally often stay in the order they were chosen to be in
// and the result never depends on a sort being stable.
//
// The counts are per currency and not per pair: "which currencies do I convert
// to" is the question a row order can answer, and one number per currency keeps
// the document a flat map instead of a matrix of source-targets that grows
// with the pair somebody typed once.
//
// A count is a NUMBER, and a strict check rather than a coercion is what keeps
// a hand-edited cache from ranking the list: Number(true) is 1, and a currency
// promoted because a cache file says `true` is a silence nobody asked for.
function rankTargets(from, def, history) {
  // The default is the head of the base order whether or not SUGGEST lists
  // it, and wherever SUGGEST lists it. Starting from SUGGEST as written put
  // CAD ahead of EUR for "100 usd", because USD is skipped as the source and
  // CAD is what was left at the front - against the header's own promise.
  var base = [def];
  for (var b = 0; b < SUGGEST.length; b++) {
    if (SUGGEST[b] !== def) base.push(SUGGEST[b]);
  }
  var counts = history !== null && typeof history === "object" ? history : {};
  var ranked = [];
  for (var i = 0; i < base.length; i++) {
    var code = base[i];
    if (code === from) continue;
    var raw = counts[code];
    ranked.push({
      code: code,
      count: typeof raw === "number" && isFinite(raw) && raw > 0 ? raw : 0,
      base: i
    });
  }
  ranked.sort(function(a, b) {
    if (a.count !== b.count) return b.count - a.count;
    return a.base - b.base;
  });
  var out = [];
  for (var j = 0; j < ranked.length; j++) out.push(ranked[j].code);
  return out;
}

// Whether an unnamed source (a bare ISO-shaped run) may claim the query. See
// parseQuery. toSpec is the raw target text, or null/"" when there is none.
function unnamedClaimable(from, toSpec, snapshot) {
  if (tableState(snapshot) === "ok") return rateOf(snapshot.rates, from.code) !== null;
  if (toSpec === null || toSpec === "") return false;
  var tSym = leadingSymbol(toSpec);
  var to = tSym !== "" ? resolveCode(symbolCode(tSym)) : resolveCode(toSpec);
  return to !== null && to.named === true;
}

// "none" while no table has landed, "empty" for a settled fetch that produced
// nothing, "ok" otherwise. One answer per call site instead of a key count per
// candidate.
function tableState(snapshot) {
  if (snapshot === null || snapshot === undefined || !snapshot.rates) return "none";
  for (var k in snapshot.rates) {
    if (Object.prototype.hasOwnProperty.call(snapshot.rates, k)) return "ok";
  }
  return "empty";
}

// The query, resolved as far as syntax alone allows. null means "not a
// currency query". A bare query resolves its source only from the named
// table, so an unadorned three-letter run ("100 abc") falls through to the
// app list instead of claiming the keystroke and then failing.
function parseQuery(query, snapshot) {
  var raw = String(query === undefined || query === null ? "" : query).trim();
  if (raw === "") return null;
  if (!isPotentialFx(raw)) return null;
  // An unpadded arrow gets its spaces, as the unit engine does it: "$->eur"
  // and "100 usd->eur" otherwise have no separator for the split to find. The
  // pattern needs a ">", so a leading minus on an amount is untouched.
  raw = raw.replace(RE_ARROW, " -> ");
  var body = raw;
  var lead = leadingSymbol(body);
  if (lead !== "") body = body.substring(lead.length).trim();
  var am = body.match(RE_AMOUNT);
  var synthetic = false;
  // A symbol with no amount is one unit of it: "$" is "1 USD" and "$ in eur"
  // is "1 USD in eur". Only a symbol earns that, and only when nothing or a
  // separator follows it, so "$HOME" and "$foo" are still not money.
  if (!am && lead !== "") {
    var bareSplit = body === "" ? null : splitExplicit(" " + body);
    if (body === "" || (bareSplit !== null && bareSplit.head.trim() === "")) {
      am = ["1"];
      synthetic = true;
    }
  }
  if (!am) return null;
  var value = Number(am[0].replace(/,/g, ""));
  if (isNaN(value) || !isFinite(value)) return null;
  // A synthesized "1" consumed no text, so the whole body is still to read.
  var rest = body.substring(synthetic ? 0 : am[0].length).trim();
  // A leading symbol makes an empty rest a bare amount ("$100"); without one
  // there is no currency named at all.
  if ((rest === "" && lead === "") || /^[0-9]/.test(rest.charAt(0))) return null;
  // A symbol glued to the right of the amount names the source just as one
  // in front of it does: "100$ in eur" and "100 in $" are both real typing.
  // It is read off the REST, not off the whole remainder, so it cannot eat
  // the target ("100$ in eur" takes the "$" and leaves "in eur" alone).
  var glued = leadingSymbol(rest);
  if (glued !== "") rest = rest.substring(glued.length).trim();
  // The rest is split with a space in front of it: a symbol-led query leaves
  // "in eur" with nothing before the keyword, and the separator pattern wants
  // whitespace on its left, so "$100 in eur" would read as a bare amount and
  // answer with the whole list instead of the one pair that was asked for.
  var split = splitExplicit(" " + rest);
  var fromSpec;
  var toSpec;
  var bare;
  if (split !== null) {
    fromSpec = split.head.trim();
    toSpec = split.tail.trim();
    bare = false;
    if (fromSpec === "" && lead === "" && glued === "") return null;
  } else {
    fromSpec = rest;
    toSpec = null;
    bare = true;
  }
  // Source precedence: a symbol beats a word, and the word that survives a
  // keyword split ("in eur" leaves nothing on the head) cannot stand in for
  // one. "R$100" is the reason the longest symbol is tried first, so the "R"
  // is not stripped as a stray letter and "$" is not left to mean USD.
  var sym = lead !== "" ? lead : glued;
  var from = sym !== "" ? resolveCode(symbolCode(sym)) : resolveCode(fromSpec);
  if (from === null) return null;
  if (bare && from.named !== true) return null;
  // An unnamed source is any three letters, so "100 mph in kph" and
  // "5 psi in bar" reach here. Only the rate table can say whether such a
  // code is a currency: a table that does not quote it releases the query to
  // the other engines. With no table yet, only a named target keeps the claim
  // (the pending row is what starts the fetch); two unnamed sides wait for a
  // table that something else has to request.
  var sourceUnclaimed = from.named !== true && !unnamedClaimable(from, toSpec, snapshot);
  var inputText = am[0] + " " + from.code;
  // `written` is the amount as typed, grouping commas and all. The label
  // echoes it and the row's sub line does too, and keeping it beside `value`
  // is what lets the sentence say "1,234.56 US dollars" rather than running
  // the money formatter over a number the user had already written down.
  var written = am[0];
  if (sourceUnclaimed) return null;
  if (toSpec === null) {
    return { value: value, written: written, from: from, to: null, bare: true,
      incomplete: false, inputText: inputText };
  }
  if (toSpec === "") {
    return { value: value, written: written, from: from, to: null, bare: false,
      incomplete: true, inputText: inputText };
  }
  // The target may be a symbol too, and the same longest-first scan decides
  // it, so "100 usd in R$" reads as BRL rather than as an unknown currency
  // ending in a dollar sign.
  var toSym = leadingSymbol(toSpec);
  var to = toSym !== "" ? resolveCode(symbolCode(toSym)) : resolveCode(toSpec);
  if (to === null) {
    return { value: value, written: written, from: from, to: null, bare: false,
      incomplete: false, inputText: inputText, toSpec: toSpec };
  }
  return { value: value, written: written, from: from, to: to, bare: false,
    incomplete: false, inputText: inputText };
}

// Thousands grouping on the integer part alone, and only on a plain decimal
// string: a value rendered in exponential form has no integer part to group
// and must not be mangled into one.
function groupThousands(s) {
  var t = String(s);
  if (t.indexOf("e") >= 0 || t.indexOf("E") >= 0) return t;
  var dot = t.indexOf(".");
  var head = dot < 0 ? t : t.substring(0, dot);
  var tail = dot < 0 ? "" : t.substring(dot);
  var neg = head.charAt(0) === "-";
  if (neg) head = head.substring(1);
  if (head.length <= 3) return (neg ? "-" : "") + head + tail;
  var out = "";
  for (var i = 0; i < head.length; i++) {
    if (i > 0 && (head.length - i) % 3 === 0) out += ",";
    out += head.charAt(i);
  }
  return (neg ? "-" : "") + out + tail;
}

// An amount, not a ratio. Two decimals once the number is at least one -
// a converted currency is money and reads as money - and six significant
// digits below it, where a second decimal is noise. The extremes fall back
// to the same exponential form UnitLib uses, because "0.00" is a wrong
// answer rather than a rounded one.
function formatAmount(v) {
  if (typeof v !== "number") return "NaN";
  if (isNaN(v)) return "NaN";
  // Checked before num() on purpose: num() admits a finite number only, so
  // testing it first would report an infinity as NaN and lose the sign.
  if (!isFinite(v)) return v > 0 ? "Infinity" : "-Infinity";
  var abs = Math.abs(v);
  if (abs !== 0 && (abs >= 1e12 || abs < 1e-4)) {
    var exp = v.toExponential(6);
    exp = exp.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
    return exp;
  }
  if (v === 0) return "0.00";
  if (abs >= 1) return groupThousands(v.toFixed(2));
  var s = v.toPrecision(6);
  if (s.indexOf("e") >= 0 || s.indexOf("E") >= 0) {
    return s.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
  }
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "");
  if (s === "-0") s = "0";
  return s;
}

// A rate for the detail line: six significant digits, never the 16 a raw float
// prints ("0.8784210526315789"), and exponential form at the extremes.
function formatRate(v) {
  if (typeof v !== "number" || !isFinite(v)) return "NaN";
  var abs = Math.abs(v);
  if (abs !== 0 && (abs >= 1e9 || abs < 1e-4)) {
    return v.toExponential(5).replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e");
  }
  var s = v.toPrecision(6);
  if (s.indexOf("e") >= 0) return String(Number(s));
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
}

// What a currency is called in a sentence, for every currency that can appear
// in an answer - the bare list's majors, the fetch base and its default - plus
// the ones a named query is most likely to reach for. A currency outside this
// table is named by its ISO code, which is honest: the label already says it,
// and a guessed name for a currency nobody here has checked is worse than the
// code.
//
// [singular, plural] for the same reason the unit table is pairs: "yen", "won"
// and "rand" are invariant in English, and a currency whose plural is not the
// singular plus an s is a rule this table spells out rather than infers.
//
// The name carries the country adjective where that is what a person says -
// US dollars, Swiss francs, Czech korunas - and the bare noun where the
// adjective is not used: euros, pounds, yen, zlotys, hryvnias.
var CURRENCY_NOUN = {
  USD: ["US dollar", "US dollars"],
  EUR: ["euro", "euros"],
  GBP: ["British pound", "British pounds"],
  JPY: ["yen", "yen"],
  CHF: ["Swiss franc", "Swiss francs"],
  CAD: ["Canadian dollar", "Canadian dollars"],
  AUD: ["Australian dollar", "Australian dollars"],
  NZD: ["New Zealand dollar", "New Zealand dollars"],
  CNY: ["Chinese yuan", "Chinese yuan"],
  CNH: ["offshore Chinese yuan", "offshore Chinese yuan"],
  HKD: ["Hong Kong dollar", "Hong Kong dollars"],
  SGD: ["Singapore dollar", "Singapore dollars"],
  INR: ["Indian rupee", "Indian rupees"],
  KRW: ["won", "won"],
  RUB: ["ruble", "rubles"],
  BRL: ["Brazilian real", "Brazilian reais"],
  TRY: ["Turkish lira", "Turkish lira"],
  MXN: ["Mexican peso", "Mexican pesos"],
  ZAR: ["rand", "rand"],
  PLN: ["zloty", "zlotys"],
  CZK: ["Czech koruna", "Czech korunas"],
  HUF: ["Hungarian forint", "Hungarian forints"],
  SEK: ["Swedish krona", "Swedish kronor"],
  NOK: ["Norwegian krone", "Norwegian kroner"],
  DKK: ["Danish krone", "Danish kroner"],
  UAH: ["hryvnia", "hryvnias"],
  ILS: ["Israeli shekel", "Israeli shekels"],
  AED: ["UAE dirham", "UAE dirhams"],
  SAR: ["Saudi riyal", "Saudi riyals"],
  THB: ["Thai baht", "Thai baht"],
  IDR: ["Indonesian rupiah", "Indonesian rupiahs"],
  MYR: ["Malaysian ringgit", "Malaysian ringgits"],
  PHP: ["Philippine peso", "Philippine pesos"],
  VND: ["Vietnamese dong", "Vietnamese dong"],
  PKR: ["Pakistani rupee", "Pakistani rupees"],
  BDT: ["Bangladeshi taka", "Bangladeshi takas"],
  LKR: ["Sri Lankan rupee", "Sri Lankan rupees"],
  NGN: ["Nigerian naira", "Nigerian nairas"],
  KES: ["Kenyan shilling", "Kenyan shillings"],
  GHS: ["Ghanaian cedi", "Ghanaian cedis"],
  EGP: ["Egyptian pound", "Egyptian pounds"],
  MAD: ["Moroccan dirham", "Moroccan dirhams"],
  ARS: ["Argentine peso", "Argentine pesos"],
  CLP: ["Chilean peso", "Chilean pesos"],
  COP: ["Colombian peso", "Colombian pesos"],
  PEN: ["Peruvian sol", "Peruvian soles"],
  UYU: ["Uruguayan peso", "Uruguayan pesos"]
};

// The words that stay down wherever they appear in a name. "per" and "of" are
// the only two that ever occur inside one in this table, and they are the only
// two that would read wrong capitalised: "Metre per Second", not "Metre Per
// Second".
var MINOR_WORDS = { "per": true, "of": true };

// A name as the head of a row reads in title case: "US Dollar", "New Zealand
// Dollar", "Millimetre of Mercury". Only the prepositions stay down, and only
// the first letter of a word moves.
//
// UnitLib has this same function with the same two entries, and it is a copy
// rather than a shared primitive on purpose: this file's text is concatenated
// into plugins/fx/main.js so that folder is droppable on its own, and a
// library that imported a helper could not be. The suite pins the two against
// each other on the same inputs, so the copy cannot drift unnoticed.
function sentenceCase(name) {
  var words = String(name).split(" ");
  for (var i = 0; i < words.length; i++) {
    var w = words[i];
    if (i > 0 && MINOR_WORDS[w.toLowerCase()] === true) continue;
    words[i] = w.charAt(0).toUpperCase() + w.substring(1);
  }
  return words.join(" ");
}

// A currency as a sentence wants it: the right number form, in title case. A
// value of exactly one takes the singular and everything else the plural,
// which is the English rule and the reason the table above has both.
function currencyWord(code, value) {
  var pair = CURRENCY_NOUN[code];
  if (pair === undefined) return String(code);
  return sentenceCase(Math.abs(value) === 1 ? pair[0] : pair[1]);
}

// One conversion as a sentence, which is what the row's sub line says:
// "100 US Dollars is 87.84 Euros". The label stays the compact
// "100 USD = 87.84 EUR" - the same fact at two reading speeds, and the sub is
// the one meant to be read rather than scanned.
//
// `written` is the amount AS TYPED, commas and all, because the money
// formatter is for the converted figure: it exists so a rate reads as money
// rather than as a rounded float, and running it over an amount the user
// already typed would give "100.00 US dollars is 87.84 Euros" - two decimals
// on a whole number that was never a decimal. The target keeps formatAmount,
// because that number nobody wrote down.
function phrase(written, fromCode, out, toCode, value) {
  return String(written) + " " + currencyWord(fromCode, value)
    + " is " + formatAmount(out) + " " + currencyWord(toCode, out);
}

// The provider's answer, or null when it is not one. A body that does not
// quote the base it claims is refused rather than half-accepted, so a
// captcha page, an error document or a truncated reply reads as "no rates"
// instead of as a table of undefined.
function parseRates(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim();
  if (raw === "") return null;
  var parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  if (parsed.result !== undefined && parsed.result !== "success") return null;
  if (!parsed.rates || typeof parsed.rates !== "object") return null;
  var base = String(parsed.base_code || RATE_BASE).toUpperCase();
  if (num(parsed.rates[base]) === null) return null;
  return {
    base: base,
    rates: parsed.rates,
    updated: String(parsed.time_last_update_utc || "")
  };
}

// One parsed query against one target currency, with every verdict a
// conversion can be refused for. The single answer and the list both reach it,
// so a bare amount and an explicit pair cannot disagree about whether a rate
// exists. `to` is the resolved target, or null when the query named none the
// engine could read.
function convertParsed(q, snapshot, to, state) {
  if (state === undefined) state = tableState(snapshot);
  if (q.incomplete === true) {
    return { ok: false, error: "incomplete", expr: q.inputText,
      label: q.inputText, sub: "Continue typing..." };
  }
  var from = q.from;
  if (to === null) {
    return { ok: false, error: "unknown-target", expr: q.inputText,
      label: "Unknown currency '" + String(q.toSpec) + "'",
      sub: "e.g. 100 usd in eur" };
  }
  if (from.code === to.code) {
    return { ok: false, error: "same-target", expr: q.inputText,
      label: "Already " + from.code, sub: "e.g. 100 usd in eur" };
  }
  // No table yet is not a failure and must not read like one: the row is
  // pending, and the row that says the fetch failed is a different label.
  // Nothing on either row names a key - the row is non-activatable, and the
  // fetch is the controller's to resolve: it lands, recomputes and repaints.
  if (state === "none") {
    return { ok: true, pending: true, value: q.value, from: from.code,
      to: to.code, label: q.inputText + " in " + to.code, inputText: q.inputText,
      sub: "Fetching today's rate" };
  }
  // An EMPTY table is a settled fetch that produced nothing usable, and it
  // is a different failure from a table that simply lacks this pair: saying
  // "no rate for USD" when the document is empty names the wrong thing and
  // sends the user looking for a currency problem they do not have.
  //
  // "Type to retry" is the mechanism, not a guess: a failed body ages out of
  // the controller's cache in seconds, and items() re-asks on the next
  // recompute. Nothing re-asks on its own, so the nudge has to be named.
  if (state === "empty") {
    return { ok: false, error: "unavailable", expr: q.inputText,
      label: q.inputText + " in " + to.code,
      sub: "Rate table unavailable - type to retry" };
  }
  // A rate of zero is a provider fault, not a rate. Taking it at face value
  // prints "100 USD = 0.00 EUR" and a zero source divides to infinity, so
  // both read as a missing rate instead - which is what they are.
  var rFrom = rateOf(snapshot.rates, from.code);
  var rTo = rateOf(snapshot.rates, to.code);
  if (rFrom === null || rTo === null) {
    var missing = rFrom === null ? from.code : to.code;
    return { ok: false, error: "unsupported", expr: q.inputText,
      label: "No rate for " + missing,
      sub: "The rate table does not quote it" };
  }
  var rate = rTo / rFrom;
  var out = q.value * rate;
  if (isNaN(out) || !isFinite(out)) {
    return { ok: false, error: "out-of-range", expr: q.inputText,
      label: "Result out of range", sub: "e.g. 100 usd in eur" };
  }
  var formatted = formatAmount(out);
  var copy = formatted + " " + to.code;
  // Coerced once: a caller that assembled its own snapshot object can leave
  // this absent, and "Rates updated undefined" is worse than no second line.
  var updated = String(snapshot.updated === undefined || snapshot.updated === null
    ? "" : snapshot.updated);
  return { ok: true, pending: false, value: q.value, from: from.code,
    to: to.code, out: out, rate: rate, formatted: formatted, copy: copy,
    phrase: phrase(q.written, from.code, out, to.code, q.value),
    desc: "1 " + from.code + " = " + formatRate(rate) + " " + to.code
      + (updated === "" ? "" : "\nRates updated " + updated),
    label: q.inputText + " = " + copy, inputText: q.inputText,
    updated: updated };
}

// Main entry, see header for the return contract. Never throws: an
// unparseable query is null (the caller falls through to app search) and a
// missing rate table is a pending row (the caller has a fetch in flight).
function tryConvert(query, snapshot) {
  var q = parseQuery(query, snapshot);
  if (q === null) return null;
  return convertParsed(q, snapshot, q.bare ? resolveCode(defaultTarget(q.from.code)) : q.to);
}

// The multi-answer half: a bare amount answers with the default and then the
// rest of SUGGEST, ordered by what the user has picked before; an explicit
// pair still answers with exactly the one conversion it asked for, and is not
// reordered by anything.
//
// Only a failure about the DOCUMENT collapses the list. No table yet and an
// empty one mean every row would say the same thing, so those are one row.
// A missing PAIR is about one currency, so that row drops out like any other
// candidate and the rest of the list still stands - which is the whole reason
// the two cases are separated: the order can move.
//
// Nothing after the gate filters on the AMOUNT. A currency is not noise
// because it divides to a small number: "1 KRW = 0.000774893 USD" is the
// answer, and a list that dropped the currencies a won happens to be small in
// would be a different list per keystroke. So the only things that remove a
// candidate are the rate document refusing to quote it - which is not a
// preference but the absence of the number itself - and a tie on the formatted
// amount, since two currencies printing the same figure are one reading. A
// list that ends up with nothing in it falls back to the default's own
// verdict, which is the honest message when no currency can be quoted.
//
// `history` may also be a function returning the map: it is called only when
// the query is a bare amount, because that is the one shape that ranks, and a
// caller whose history lives behind a cache read should not pay it per keystroke.
function tryAll(query, snapshot, history) {
  var q = parseQuery(query, snapshot);
  if (q === null) return null;
  var state = tableState(snapshot);
  if (q.bare !== true) return [convertParsed(q, snapshot, q.to, state)];
  var def = resolveCode(defaultTarget(q.from.code));
  var gate = convertParsed(q, snapshot, def, state);
  if (gate.ok !== true && (gate.pending === true || gate.error === "unavailable")) return [gate];
  var codes = rankTargets(q.from.code, def.code, typeof history === "function" ? history() : history);
  var out = [];
  var numbers = [];
  for (var i = 0; i < codes.length && out.length < MAX_TARGETS; i++) {
    var code = resolveCode(codes[i]);
    if (code === null) continue;
    var r = convertParsed(q, snapshot, code, state);
    if (r.ok !== true || r.pending === true) continue;
    if (numbers.indexOf(r.formatted) >= 0) continue;
    numbers.push(r.formatted);
    out.push(r);
  }
  return out.length > 0 ? out : [gate];
}

// Currency engine plugin: natural-language conversion, one row per target.
// FxLib source (pure JS, no imports, no network - the rate table is an
// argument) is concatenated above this contract; the IIFE below only adapts
// it to VibraniumPlugin and owns the two things a pure library cannot: the
// api it is handed, and the one fetch that fills the rate table's argument.
(function() {
  let api = null
  // Last body this engine's own eval parsed, and the URL it came from. Both
  // are module state rather than QML properties on purpose: a PluginInstance
  // is destroyed with its controller, so neither can outlive the tree that
  // produced it, and there is nothing to unload by hand.
  let memoBody = null
  let memoUrl = ""
  let memoRates = null

  // The rate table is one singleton document, so a body is parsed once per
  // distinct text rather than once per keystroke. The memo is keyed on the
  // BODY, not on the URL: a TTL refresh that returns identical bytes is the
  // common case and must not re-parse, while a refresh that returns different
  // bytes must. An unusable body memoizes as a settled failure (an empty
  // table) rather than as "no answer", so a truncated reply is not mistaken
  // for a fetch still in flight - which is the difference between a row that
  // says the rate is unavailable and one that waits forever.
  function ratesFor(url) {
    const body = api.cachedNet(url)
    if (body === null) return null
    if (body === memoBody && url === memoUrl) return memoRates
    memoUrl = url
    memoBody = body
    memoRates = body === "" ? { base: "", rates: {}, updated: "" } : parseRates(body)
    if (memoRates === null) memoRates = { base: "", rates: {}, updated: "" }
    return memoRates
  }

  // The shell-cache section the pick counts live in. The name has to begin
  // with this plugin's id - that is the launcher's rule, not a convention, and
  // it is what keeps this count out of the audio level and the update mirror
  // sharing the same document.
  const USAGE_SECTION = "fx-usage"

  // What the user has picked, or an empty map. Anything that is not a plain
  // object reads as no history at all, so a hand-edited or half-written cache
  // degrades to the documented default order rather than to a broken list.
  function usageCounts() {
    const cur = api.cachedSection(USAGE_SECTION)
    return cur !== null && typeof cur === "object" && !Array.isArray(cur) ? cur : {}
  }

  // One pick, one increment.
  //
  // Recorded on ACTIVATION and not on render: items() runs on every keystroke,
  // so counting there would rank a list the user merely scrolled past, and a
  // currency would climb for having been looked at. The copy goes first,
  // because it is what the key press asked for and the count is bookkeeping -
  // a failed copy is not evidence of a preference.
  function recordUse(code) {
    const target = String(code === undefined || code === null ? "" : code)
    if (target === "" || typeof api.setCacheSection !== "function") return
    const counts = usageCounts()
    const next = {}
    for (const key in counts) {
      if (Object.prototype.hasOwnProperty.call(counts, key)) next[key] = counts[key]
    }
    const seen = Number(next[target])
    next[target] = (isFinite(seen) ? seen : 0) + 1
    api.setCacheSection(USAGE_SECTION, next)
  }

  // True unless the host affirmatively reports no internet: a host
  // without the cached read, or one whose read is unbound, keeps the row on
  // its ordinary wording rather than failing it.
  function onlineNow() {
    if (typeof api.cachedOnline !== "function") return true
    try {
      return api.cachedOnline() !== false
    } catch (e) {
      return true
    }
  }

  VibraniumPlugin = {
    init: function(context) {
      api = context
    },
    items: function(query) {
      if (String(query || "").trim() === "") return []
      if (!isPotentialFx(query)) return []
      // ONE pass. The gate above is cheap and deliberately over-accepts: it
      // cannot tell a currency from a unit, only the parse can. tryAll
      // answers null for "not a currency query", so one call is both the
      // verdict and the result: a separate tryConvert for the verdict would
      // parse the query twice, build a full conversion it threw away, and
      // read the cache twice.
      //
      // The URL is requested only after that verdict, so "100 abc", "5m" and
      // "100 mph in kph" never open a socket for what is really an app search
      // or a unit query. The snapshot is the one read before the request: the
      // request is asynchronous, and the controller recomputes when it lands.
      const results = tryAll(query, ratesFor(RATE_URL), usageCounts)
      if (!results || results.length === 0) return []
      // A word the engine cannot read as a currency is a miss, not an answer,
      // for the reason the unit plugin gives: this list replaces every
      // application match, and "5 cup in ml" is not a question about money.
      if (results[0].error === "unknown-target") return []
      // A query the cache already answers is not blocked on this request, and
      // the controller owns the TTL, so asking on every recompute is cheap.
      api.requestNet(RATE_URL, 8000)
      // The same icon name calc and unit use, and gated by the same setting,
      // so the three "compute something" rows are one family at a glance.
      //
      // It resolves through the ROW's path (Menu.resolveAppIcon), which falls
      // back to Quickshell.iconPath() when Icons.url() has no shipped asset -
      // so "accessories-calculator" comes from the system theme. That is the
      // status quo for calc and unit, and it is why the same name works here.
      // It would NOT work in the search field's chip, which calls Icons.url
      // with no system fallback.
      const icon = api.setting("shell.launcher.showIcons") !== false ? "accessories-calculator" : ""
      const rows = []
      for (let i = 0; i < results.length; i++) {
        const r = results[i]
        // The uid names the TARGET, not the engine: rowsEqual keys on it and a
        // launcher card renders several of these at once, so one uid for the
        // whole set would collapse them into one identity.
        const uid = r.to === undefined ? "fx:hint" : "fx:" + r.to
        const offline = r.error === "unavailable" && !onlineNow()
        if (r.ok && r.pending) {
          rows.push({
            kind: "fx",
            uid: uid,
            label: r.label,
            sub: r.sub,
            desc: "",
            icon: icon,
            fxValue: "",
            fxExpr: r.inputText,
            incomplete: true,
            pending: true,
            item: { copyValue: "" }
          })
          continue
        }
        if (r.ok) {
          rows.push({
            kind: "fx",
            uid: uid,
            label: r.label,
            // The conversion again, as a sentence: the label is the compact
            // form to scan and this is the one to read. What it replaced -
            // "Copy X to clipboard" - was the only thing on the row that named
            // the key press, so the affordance is now implicit (Enter still
            // copies, and ctrl-I still opens the cross rate).
            sub: r.phrase,
            desc: r.desc,
            icon: icon,
            fxValue: r.copy,
            fxExpr: r.inputText,
            incomplete: false,
            // The target rides the payload as well as the uid: the uid is what
            // the card keys a row on, and activate() is what learns what the
            // user picked. One field, one fact, and neither reader has to
            // parse the other one's string.
            item: { copyValue: r.copy, target: r.to }
          })
          continue
        }
        rows.push({
          kind: "fx",
          uid: uid,
          label: r.label,
          // An empty table while offline names the link, not the rates.
          // Anything else keeps the library's own wording: an unsupported
          // pair is about the currency, and an old table is about the
          // provider rather than the wire. The offline row also raises
          // the entry's alert flag, which paints the sub red.
          sub: offline ? "No internet connection" : r.sub,
          desc: "",
          icon: icon,
          fxValue: "",
          fxExpr: r.expr,
          incomplete: true,
          item: { copyValue: "" }
        })
        // Alert is assigned, not spread: this engine does not parse
        // object spread in literals, and a spread here fails the whole
        // plugin file at load.
        if (offline) rows[rows.length - 1].alert = true
      }
      return rows
    },
    activate: function(item) {
      const v = String(item && item.copyValue || "")
      if (v === "") return
      api.execDetached("printf %s " + api.shellQuote(v) + " | wl-copy")
      // After the copy, and only for a row that had a real number to copy: a
      // hint and a pending row carry no target and never reach here.
      recordUse(item && item.target)
    }
  }
})()
