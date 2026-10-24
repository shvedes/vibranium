# App launcher

A native [Quickshell](https://quickshell.org) application launcher. Access it with ++super++ + ++a++.
It launches installed applications and doubles as a command surface:

- Application search with instant fuzzy matching
- Clipboard-aware opener: paths, locations and links from the newest copy
- Inline calculator, unit converter, currency rates, world clock and color
  conversions
- Web search fallback when no local application matches
- Per-plugin enable/disable settings

## Search

Type to filter across every installed desktop entry - names, generic
names, descriptions and categories all match. A query with no exact
match falls back to a typo rescue before anything else, so
`sotify` still offers Spotify. One edit is tolerated on short queries,
two on longer ones, keeping short matches precise. ++enter++ launches the
selected entry; descriptions of the highlighted app are available via
++ctrl+i++ as a dropdown under the row.

!!! tip
    Enable **Show app descriptions** in the settings to render each app's
    description directly as the entry subtitle instead of behind Ctrl-I.

## Web search

When nothing local matches your query, a **Search in \<engine\>** entry
appears - selecting it searches the configured engine in your browser.

Type the query directly; no prefix is required:

```text
Burnout Paradise Remastered
```

The engine follows the **Search engine** setting (Google / DuckDuckGo /
Bing / Brave).

## Unit converter

Type a measurement to convert it inline - no prefix needed:

```text
250mph in km
5m in cm
20cm
100C in F
```

Use `in`, `to`, `as`, `->` or `=` between the units (`5m in cm`,
`1kg to lb`). A bare value answers with a row per reading - the default
first, then the other units worth seeing, up to six - and ++enter++ copies
the one you are on. Naming a target is how you ask for exactly one answer
(`5 mb in gb` is a single row whatever the bare query would have shown).

```text
5 mb           ->  5 MB = 5000 KB
                  5 MB = 5000000 B
                  5 MB = 0.005 GB
                  5 MB = 4882.81 KiB
                  5 MB = 4.76837 MiB
                  5 MB = 0.00465661 GiB
```

Each row answers twice: the title is the compact form to scan, and the line
under it is the same conversion spelled out - `5 megabytes is 4882.81
kibibytes`. Both engines do this, so a currency row reads `100 US Dollars is
87.84 Euros`.

Every row is the same dimension as the one you typed - a watt never answers
with a kilowatt-hour - and a reading too large to be said out loud is left out.
A fraction of a **greater** unit is kept only while it still means something:
`5 MB = 0.005 GB` is there (that is half a percent of a drive), but
`20 cm = 0.0002 km` is not, because no one asks how much of a kilometre 20
centimetres is.

The head of the list is the cross-system default (`20cm` -> inches, `10lb` ->
kilograms, `100C` -> Fahrenheit), and it is always the first row. Speed accepts
a length shorthand (`250mph in km` reads as km/h).
Unqualified `pt`/`qt`/`gal`/`floz` are US; prefix `uk` for imperial
(`1ukgal in l`). Data steps are decimal (`1 MB = 1000 KB`); the IEC
`KiB`/`MiB`/`GiB` symbols are the binary ones and convert to each other by
1024. Impossible values (below absolute zero, out-of-range results) show a
hint instead of a number.

Full English names and plurals work too (`5 miles in kilometers`,
`2 fluid ounces in ml`), case does not matter. `"` and `'` are
accepted as inch and foot (`72" in cm`).

### Supported units

**Length:** nm, um, mm, cm, m, km, in, ft, yd, mi, nmi, plus the light ladder
(ls, lmin, lh, ld, lw, ly) and au, pc
**Mass:** mg, g, kg, t (tonne), oz, lb, st, ton (short ton)
**Volume:** ml, l, tsp, tbsp, floz, cup, pt, qt, gal, in3, ft3, m3,
plus `uk` variants (ukfloz, ukpt, ukqt, ukgal)
**Speed:** m/s, km/h, mph, ft/s, kn
**Temperature:** C, F, K
**Area:** cm2, m2, ha, km2, in2, ft2, yd2, ac, mi2
**Time:** ms, s, min, h, d, wk, yr
**Energy:** J, kJ, cal, kcal, Wh, kWh, eV, BTU
**Power:** W, kW, hp
**Pressure:** Pa, kPa, bar, psi, atm, mmHg
**Data:** B, KB, MB, GB, TB, bit, KiB, MiB, GiB
**Angle:** deg, rad

The head of a bare query is its cross-system counterpart: `20cm` ->
inches, `1m` -> feet, `1km` -> miles, `5lb` -> kilograms, `1l` ->
gallons, `1ha` -> acres, `100C` -> Fahrenheit. Time is the exception:
it picks the largest unit reading between 1 and 1000, so `7d` ->
weeks but `1d` -> hours and `1500ms` -> seconds.

The rows behind it are the neighbours you would actually ask for, not
every unit of the dimension: no petabytes behind a megabyte, no decimetres
behind a metre. Every unit in the list above is still reachable - by naming
it on the other side (`5 m in hand`), which is the query shape that asks for
a specific unit.

!!! note "Accuracy"
    Results show at most 6 significant digits - the last digit is
    rounded, so a copied value is not the full-precision result.
    Units with competing definitions use one documented choice: the
    calorie is thermochemical (4.184 J), the BTU is the International
    Table BTU, `ton` is the short ton (907 kg, metric tonne is `t`),
    and `yr` is exactly 365 days. `torr` currently converts as mmHg
    (relative difference 1.4e-7).

## Currency

Type an amount and a currency pair to convert it against **today's** rate -
no prefix needed:

```text
100 usd in eur
100 usd to eur
100 usd
$100 in eur
1,234.56 usd in jpy
100 zloty in usd
```

Use `in`, `to`, `as`, `->` or `=` between the currencies, exactly as the unit
converter does. Naming a pair gives exactly one row. A bare amount answers
with a list of up to ten currencies - the default list below - and ++enter++
copies the one you are on:

```text
100 usd         ->  100 USD = 87.84 EUR        100 US Dollars is 87.84 Euros
                  100 USD = 75.56 GBP          100 US Dollars is 75.56 British Pounds
                  100 USD = 82.93 CHF          100 US Dollars is 82.93 Swiss Francs
                  100 USD = 403.01 PLN         100 US Dollars is 403.01 Zlotys
                  100 USD = 15,748.94 JPY      100 US Dollars is 15,748.94 Yen
                  100 USD = 129,050.00 KRW     100 US Dollars is 129,050.00 Won
                  100 USD = 544.00 BRL         100 US Dollars is 544.00 Brazilian Reais
                  100 USD = 1,033.05 SEK       100 US Dollars is 1,033.05 Swedish Kronor
                  100 USD = 4,120.00 TRY       100 US Dollars is 4,120.00 Turkish Lira
```

The title of a row is the compact form to scan; the line under it is the same
conversion spelled out, for reading.

The list is ordered by `USD CAD EUR GBP CHF PLN UAH RUB JPY CNY AUD INR KRW
BRL MXN SEK NOK ZAR TRY`, minus the currency you typed, and it does not depend
on the amount: `100 usd` and `0.1 usd` show the same currencies in the same
order. A currency the rate provider does not quote has no row.

**The currencies you use move up.** Every conversion you copy with ++enter++
counts, and the next bare query offers the most-counted currencies first - so
the list settles into the currencies you actually convert to. The counts live
in `fx-usage` in `$VIBRANIUM_CACHE/shell.json`; deleting that file (or that
section) puts the default order back. A currency you never pick is never
dropped, it just keeps its place behind the ones you do.

Currencies are named by ISO code (`usd`, `eur`, `jpy`, `kwd`), by the words
you would actually type (`dollars`, `euros`, `yen`, `zloty`, `francs`) or by
symbol, in front of the amount, glued to it, or as the target (`$100 in eur`,
`100$ in eur`, `100 usd in €`). Ambiguous symbols resolve to the currency
they most often stand for - `$` is USD and `¥` is JPY - so use the code when
you mean a different one. Any three-letter code the rate provider quotes
works, so the set of currencies is the provider's rather than a fixed list.

Amounts may carry thousands separators (`,`), a leading decimal point (`.5`)
and a sign. Results are formatted as money - two decimals with grouped
thousands above 1, six significant digits below it - so a rate is never
rounded away to `0.00`. ++ctrl+i++ shows the exact cross rate and the date
the rate document was published. While today's rate is still being fetched,
and if the fetch fails, you get a single row that says so rather than ten
copies of the same message.

!!! note "This plugin uses the network"
    `fx` is the only launcher plugin that does. It fetches one rate document
    from a free, key-less endpoint and caches it for ten minutes, so a whole
    session of conversions costs one request. If the fetch fails the row says
    so rather than showing a stale or invented number. Disable it in
    Menu -> Settings -> App launcher -> Enabled plugins.

## Color

Type a color code and it answers with the same color in the other formats the
**Color Picker** bar module can copy - one row each, and ++enter++ copies the
one you are on:

```text
#ff8800
rgb(255, 136, 0)
hsl(32, 100%, 50%)
```

```text
#ff8800      ->  rgb(255, 136, 0)
                rgba(255, 136, 0, 1.000)
                hsl(32, 100%, 50%)
                hsla(32, 100%, 50%, 1.000)
                hsv(32, 100%, 100%)
                hsva(32, 100%, 100%, 1.000)
```

Six rows because there are seven formats and one of them is already on screen:
the hex you typed is still in the input field. The rows follow the picker's own
order, so the two surfaces never spell the same color differently.

Each row is led by a dot of that exact color rather than a palette icon - six
rows of one icon would say *color* six times and never say which color. The dot
is painted opaque: give a code an alpha (`#ff880080`, `rgba(255, 136, 0, 0.5)`)
and the three alpha forms carry it, while the dot stays the solid color so it
reads on any theme.

A hex code needs its `#`. `face`, `cafe` and `facade` are all valid colors and
all plausible app names, so a bare hex word stays an app search. The `rgb()`,
`hsl()` and `hsv()` forms need no such guard.

## Open from the clipboard

When the launcher opens, the newest clipboard entry is checked. If it
names something openable, a suggestion appears **above the app list**:

- **Local paths and locations** - `/home/user/Downloads`,
  `file:///home/user/reports/q3.pdf`, `ftp://nas/media`, `smb://...` -
  show as **Open file from the clipboard** or **Open folder from the clipboard** with the file or folder name as the
  subtitle and an icon reflecting the file type (image, archive, PDF,
  folder, ...). Local paths are
  existence-checked first; remote locations open directly.
- **Web links** - `https://...` - show as **Open URL from the
  clipboard** with the literal URL as the subtitle and open in the
  default browser.

A separator divides the suggestion from the app list. Disable the
whole thing with **Clipboard suggestion** in
Menu -> Settings -> App launcher.

!!! tip
    Typing filters from the first key and ++ctrl+v++ pastes the clipboard
    straight into the query. Only real text flavors are pasted; image
    and binary payloads are ignored. Typing or pasting a path as the
    query also offers it as a single **Open \<name\>** entry when
    nothing else matches.

## Plugins

Launcher capabilities are plugins:

| Plugin | Type | Provides |
|---|---|---|
| `calc` | engine | Inline calculator (`2+2`) |
| `color` | engine | A color code in six other formats (`#ff8800`) |
| `fx` | engine | Live currency conversion (`100 usd in eur`) |
| `time` | engine | `time in <city>`, on the city's own 12- or 24-hour dial; `<time> <tz>` in your local zone |
| `unit` | engine | Unit conversion (`5m in cm`) |
| `websearch` | websearch | Automatic no-match web-search fallback |

A city's clock reads the way that place reads it, whatever this machine is
set to: `time in Chicago` shows `01:00 PM` and `time in Madrid` shows
`13:00`, on a system configured either way. There is no setting for it.

A typed time with a zone reads back in your local zone, so `7:55pm cst`
(case-insensitive, with an optional date like `Oct 15 7:55pm CST` or
`2026-10-15 19:55 CST`) answers with the same instant on your own clock
- `7:55 PM CST -> 3:55 AM local`. Abbreviations are fixed offsets (`CST`
is US Central `-0600`, `IST` is India `+0530`); a bare time means today
in the source zone, and ++enter++ copies the local time.

Each plugin can be toggled independently, from Menu -> Settings -> App
launcher -> Enabled plugins or from the CLI:

```bash
vb-shell appLauncher plugins             # list plugin configs
vb-shell appLauncher pluginSet websearch false
```

Enable/disable state persists in `~/.config/vibranium/settings.json`
under `shell.appLauncher.plugins`. Disabled plugins register no prefix,
contribute no rows and are never loaded.

### Writing a plugin

Create a directory either in
`$VIBRANIUM/shell/widgets/AppLauncher/plugins` (built-in) or
`~/.config/vibranium/shell/AppLauncher/plugins` (user). The directory
name is the plugin id and must contain:

**plugin.json** - manifest:

```json
{
  "name": "My plugin",
  "description": "What it does",
  "keyword": "?",
  "type": "websearch"
}
```

**main.js** - implementation assigning a `VibraniumPlugin` object:

```javascript
(function() {
  let api = null

  VibraniumPlugin = {
    init(context) {
      api = context
      // api.setting(key)   read a setting value
      // api.readFile(path) read a file (null when missing)
      // api.execDetached(script) run a bash script detached
      // api.configDir      ~/.config/vibranium
    },
    items(query) {
      return [{ label: "Row", sub: "", desc: "", icon: "", data: {} }]
    },
    activate(item, query) {
      // runs when the row is selected; `query` is the typed text
    }
  }
})()
```

Reload plugins with `vb-shell appLauncher reload`. A broken plugin is
skipped with a warning and never blocks the launcher.

## Settings

Configure in **Vibranium Menu** -> **Settings** -> **App Launcher**:
show icons, show PWA/TUI badges, show web apps, search engine, sort
order, auto-select, app description display and focus-first behavior.

**Focus first** focuses an existing window of the app instead of
spawning a new instance. Window identity is derived from the desktop
entry (`StartupWMClass`, the `.desktop` filename, the `Exec` basename)
and matched against live Hyprland windows by **exact window class**, so
a wrong window is never grabbed. PWA windows - `PWA - <name>` entries -
are matched through their `chrome-<host>` class. Terminal apps
(`Terminal=true`) launch inside a terminal via `vb-launch-tui`, which
also engages focus-first. The same engine backs the `vb-launch-cmd`,
`vb-launch-tui` and `vb-launch-webapp` helpers.

## Tips

- Category filtering happens through normal search rather than dedicated flags.
- You can un/install TUIs and PWAs in **Vibranium Menu** -> **Install** /
  **Remove**
