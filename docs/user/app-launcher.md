# App launcher

The App Launcher is basically a [rofi](https://github.com/davatorium/rofi) wrapper with a bunch of goodies. Access it with ++super++ + ++a++.  
It's multi-purpose by desing, allowing you not just open apps, but also:

  - Launch Chrome PWAs (Progresive Web Apps)
  - Launch TUIs
  - Perform web queries
  - Handle custom keywords

## Web Apps and TUIs

When webapps and TUI apps are enabled (see below), they appear right alongside regular applications, and you can filter by typing category keywords:

- `PWA` — all PWAs: AI, built-in webapps, your custom ones
- `TUI` — only installed TUI applications
- `System`, `Network`, and other categories work similarly

## Settings

Configure in **Vibranium Menu** -> **Settings** -> **App Launcher**:

| Setting | What it does |
|---|---|
| **Show icons** | App icons in the list |
| **Show webapps** | Whether to show PWAs in the launcher |
| **Auto Select** | When only one entry matches your search, rofi selects it automatically |
| **Focus first** | Prefer focusing an already-open window over launching a new instance of the same app |
| **Show on start** | Pop the launcher open right after login |
| **Search engine** | Google / DuckDuckGo / Bing / Brave |

## Web search

When no local matches found, a (preffered) browser window will open with your query in selected search engine.
Type "Never Gonna Give You Up" and hit ++Enter++ to see in action.

!!! note
    When **Auto-select** is *enabled*, web search is unavailable.

## Custom keywords

You can define special keywords that will fire a specific action when matched.
A keyword is basically a word that is being parsed when entered.

Keywords defined in `~/.config/vibranium/settings.advanced` in the `vb_launcher_keywords=()` bash array.
While this is a basic bash array, each entry has a special syntax in a form of `keyword:action`,
where `keyword` is the text you type in the search bar, and `action` is the action it will trigger.

An `action` may be:

  - A binary, available in `$PATH`, e.g. `firefox`
  - A local function defined in `settings.advanced`
  - A local function defined in `settings.functions`

While you can define special function in `settings.advanced` alongside the keywords array,
it's highly recommended to keep them in `settings.functions` to keep things clean and fragmented.

Open the App Launcher and type "updates" to see pre-defined keyword in action.
Open `~/.config/vibranium/settings.advanced` to see live examples of this feature.

For full picture, see [`settings.advanced`](./advanced-settings.md) documentation.

!!! warning
    This feature is disabled when **Auto Select** option is active.

## Tips

- You can un/install TUIs and PWAs in **Vibranium Menu** -> **Install** / **Remove**
- Pre-installed TUIs and PWAs are removable. Use the menu above to do so
