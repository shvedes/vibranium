For screenshots, Vibranium uses [`grim`](https://sr.ht/~emersion/grim/) for capturing, [`slurp`](https://github.com/emersion/slurp) for regional selection and [`vb-core-screenshot`](https://github.com/shvedes/vibranium/blob/master/bin/vb-core-screenshot) for backend logic. These two are basically the standard across Wayland setups, so Vibranium is not an exclusion.

You have three pre-defined keyboard shortcuts for making screenshots:
- `SUPER + SHIFT + Z` to capture an entire screen
- `SUPER + SHIFT + A` to capture an active window
- `SUPER + SHIFT + S` to capture a region

The choice and logic behind these keys is that all three are accessible by your left palm (well, except for region capture; it requires mouse, but still). If you're not satisfied with these - you can easily unbind or re-bind them as described in [Customize Keybindings](Customize%20Keybindings.md).

You can configure how `vb-core-screenshot` behaves by going to: *Vibranium Menu* (`CTRL ALT V`) -> *Settings* -> *Screenshots*.

## Annotations

*Vibranium Menu* (`CTRL ALT V`) -> *Settings* -> *Screenshots* -> *Annotate automatically*.

If you want to annotate your screenshots, you can do it easily by toggling the *Annotate automatically* option. After capturing a screenshot, a simple image annotator ([satty](https://github.com/Satty-org/Satty)) with beautiful UI will pop up where you will find anything that an image annotator could have.