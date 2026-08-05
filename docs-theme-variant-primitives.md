# Making a template theme-mode-aware

Four primitives, for when a template needs to behave differently in a light
theme than a dark one. Full details, including the ops tables and the bug
these fix, live in [`wiki/Themes Architecture.md`](wiki/Themes%20Architecture.md#theme-mode-aware-operations).

1. **`is_light`** — a plain key, `true` or `false`. Use it like any other
   substitution: `{{ is_light }}`.

2. **`dim=`/`pop=`** — direction-relative lightness shifts, for HEX/RGB/HSL
   keys. `dim` always moves toward the background, `pop` always moves toward
   the foreground, regardless of theme mode. Unsigned operand only.
   ```
   --color-base-25: {{ background_2|dim=0.05 }};
   ```

3. **`light=<value>` / `dark=<value>`** — unconditional override. Fires only
   when the active theme matches; the other is a no-op. `<value>` is used
   literally, not re-expanded.
   ```
   border-color: {{ accent|light=#00000022|dark=#ffffff22 }};
   ```

4. **`{{ #light }}` / `{{ #else }}` / `{{ #end }}`** — block directives for
   dropping or keeping whole lines by theme mode. Must be the entire line.
   No nesting.
   ```
   {{ #light }}
   .app-container { box-shadow: none; }
   {{ #else }}
   .app-container { box-shadow: 0 0 12px {{ background_0|alpha=0.45 }}; }
   {{ #end }}
   ```

Use `dim`/`pop`/`light`/`dark` when only a *value* needs to differ by theme.
Use `{{ #light }}`/`{{ #else }}` when a whole *rule* needs to differ.
