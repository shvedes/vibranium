# Making your own theme

Vibranium themes are generated from a shared color palette.
A complete theme can be created by defining `colors.list`, adding metadata, and providing wallpapers.
The theme engine then generates application configurations from templates.

This page covers two approaches:

- **Template-only themes** — fast creation using generated configs.
- **Traditional themes** — manual application-specific customization.

## Template-only method

A template-based theme requires three components:

- `colors.list`
- `theme.info`
- At least one image in `backgrounds/`

## Step 1: create the theme directory

Create a new theme directory:

```bash
ccd ~/.config/vibranium/themes/solar
```

`ccd` is a Vibranium shell helper that creates a directory and enters it immediately.

## Step 2: create theme metadata

Create `theme.info` in the theme root:

```bash
# Theme family name.
# Used as a submenu entry in the theme picker.
# Leave empty for standalone themes.
FAMILY=

# Theme variant name.
# Required. For standalone themes this is the theme name.
VARIANT=Solar

# Whether this is a light theme.
# Required.
LIGHT=false
```

## Step 3: define the color palette

The main theme file is:

```text
colors.list
```

Every color value must be defined.

Useful tools:

* [HTML Color Picker](https://htmlcolorcodes.com/color-picker/)
* [Tint & Shade Generator](https://tintsshades.web-toolbox.dev/)
* Color picker (++ctrl+alt+c++)

??? note "Click here to copy the empty tempalte"

    ```toml
    black   = ""
    red     = ""
    pink    = ""
    green   = ""
    yellow  = ""
    orange  = ""
    blue    = ""
    purple  = ""
    cyan    = ""
    white   = ""
    gray    = ""
    accent  = ""

    background_h = ""
    background_0 = ""
    background_1 = ""
    background_2 = ""
    background_3 = ""
    background_4 = ""
    background_5 = ""

    foreground_h = ""
    foreground_0 = ""
    foreground_1 = ""
    foreground_2 = ""
    foreground_3 = ""
    foreground_4 = ""
    foreground_5 = ""
    ```

Our example:

??? note "Click to expand"

    ```toml
    black   = "#2C2418"
    red     = "#C44030"
    pink    = "#B84068"
    green   = "#6E9040"
    yellow  = "#E8B800"
    orange  = "#E88020"
    blue    = "#2E60AE"
    purple  = "#7040B0"
    cyan    = "#2894B0"
    white   = "#D8C8A8"
    gray    = "#6A5C4C"
    accent  = "#E8A800"

    background_h = "#090704"
    background_0 = "#100C06"
    background_1 = "#1A150D"
    background_2 = "#261E13"
    background_3 = "#352A1A"
    background_4 = "#4C3C24"
    background_5 = "#634F30"

    foreground_h = "#F5EAD0"
    foreground_0 = "#EAD9B8"
    foreground_1 = "#D4C098"
    foreground_2 = "#B8A478"
    foreground_3 = "#9A8858"
    foreground_4 = "#7A6C42"
    foreground_5 = "#5A502C"
    ```

The palette contains:

* 11 color families.
* 6 background shades.
* 6 foreground shades.
* Accent colors.

Dimmed and brighter shades are not part of the palette. Templates compute them on the fly with `|dim=` and `|pop=` operations, which shift a color toward the background or the foreground relative to the current theme mode.

These values are consumed by the theme templates to generate application configurations.
For a complete example, see the default [Nightfox theme](https://github.com/shvedes/vibranium/tree/master/themes/nightfox).

## Step 4: add wallpapers

Add wallpapers inside:

```text
backgrounds/
```

It's recommended to keep filenames orderd like so:

```bash
backgrounds/01-<theme>-bg.jpg
backgrounds/02-<theme>-bg.jpg
backgrounds/03-<theme>-bg.jpg
```

Example:

```bash
cp ~/Downloads/wallpaper.jpg backgrounds/01-solar.jpg
```

The filename is not important.

The final structure:

```text
solar/
├── backgrounds/
│   └── 01-solar-jpg.jpg
├── colors.list
└── theme.info
```

??? tip "The result"

    ![Solar preview 1](../assets/images/solar_theme_showcase.jpeg)

    ---

    ![Solar preview 2](../assets/images/solar_theme_showcase_2.jpeg)

## Step 5: apply the theme

Open the theme picker and select the new theme.
The theme engine generates the required application configurations and applies the wallpaper.

Generated configurations can include:

* GTK
* Qt
* terminal themes
* Waybar
* Rofi
* notifications
* lock screen
* editor integrations

!!! tip "Palette quality matters"
    The generated result depends heavily on the quality of the color palette.
    Carefully tuned colors produce significantly better results.

## Traditional method

The traditional method allows per-application customization.

`colors.list` is still required because Vibranium generates base configurations regardless.

Additional files can be included in the theme directory to override generated configurations:

```text
theme/
├── colors.list
├── theme.info
├── backgrounds/
└── application overrides
```

Examples of manual overrides:

```text
waybar.css
rofi.rasi
dunstrc
```

This method provides more control when a generated template does not match the desired result.

The default Nightfox theme is an example of a theme using additional manual configuration.

## Publishing themes

Community themes use the same directory structure.

Repositories should follow the naming convention:

```text
vibranium-theme-<name>
```

Themes can then be installed through:

**Vibranium Menu** -> **Install** -> **Theme**

See [Themes](themes.md) for installation details.
