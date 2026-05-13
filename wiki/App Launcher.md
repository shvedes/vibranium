The app launcher (`SUPER A`) is essentially a rofi wrapper, extended with additional features that you can customize in Vibranium Settings.

To configure it, go to *Vibranium Menu* -> *Settings* -> *App Launcher*.

## Web Search

The app launcher is multi-purpose. In addition to launching applications and PWAs, it can also perform basic web searches using your preferred search engine.

To use it, start typing your query. Once finished, a browser window or tab will open with the results. Note that auto-select must be disabled, and the launcher should not have any matching local results (apps or PWAs), otherwise it will prioritize those instead.

## PWA / AI / TUI / Category Sorting

When enabled, PWAs appear alongside regular applications and TUI apps and behave like any other entry from rofi’s perspective.

You can filter them by category using keywords. For example:
- Typing `AI` will show only AI-related PWAs (if enabled)
- Typing `PWA` will show all PWAs, including AI, built-in web apps, and your custom ones
- Typing `TUI` will show only installed TUI applications  

You can also try other categories such as `System`, `Network`, and more.