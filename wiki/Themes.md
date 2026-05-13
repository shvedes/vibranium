![preview](https://raw.githubusercontent.com/shvedes/vibranium/master/.github/media/themes.gif)

Vibranium comes with many different themes.
You can switch between them using the theme picker (`CTRL ALT + T`).
The currently active theme is highlighted in bold italic text.

Most themes are forks of Neovim themes, but not all of them.
There are also ports of official and community Omarchy themes, adapted for Vibranium.

At the time of writing, there are 34 pre-installed themes available.

## Types

There are two types of themes: **families** and **standalone**.

A family, for example *MyCoolFamily*, may contain multiple flavors such as *Flavor1*, *Flavor2*, and so on.  
Each *family* has its own submenu with its flavors.

A *standalone* theme, on the other hand, is both the family and the flavor.  
These themes do not have submenus and are displayed alongside *Families*.

**Families examples:**
- Nightfox
- Catppuccin
- Everforest
- Tokyonight

**Standalone examples:**
- Deep Forest
- Evergarden
- Ristretto
- Dracula
- Aamis

## Omarchy themes

Vibranium supports Omarchy themes made for Omarchy `v3.3.0+`, specifically those that include the `colors.toml` file. See [Themes Architecture](Themes%20Architecture.md) for more details.

Where you can find community themes:
- [omarchythemes.com](https://omarchythemes.com/)
- [omarchy.deepaknes.com](https://omarchy.deepakness.com/themes)
- [awesome-omarchy.com](https://awesome-omarchy.com/)
- [aorumbayev/awesome-omarchy](https://github.com/aorumbayev/awesome-omarchy)
- [omarchy-theme Github topic](https://github.com/topics/omarchy-theme?o=desc&s=stars)

### Installing an Omarchy theme

To install an Omarchy theme, go to *Vibranium Menu* → *Install* → *Theme*.  
A terminal window with several prompts will appear.

Before installation, the installer verifies that the theme is supported and will fail if it is not.

Once installed, the theme is applied immediately and becomes available in the theme picker (`CTRL ALT + T`).

### Removing an Omarchy theme

To remove a theme, follow the reverse process.  
Open *Vibranium Menu* → *Remove* -> *Theme*. A rofi window will appear with a list of all installed community themes.

Select the theme you want and press *Enter*.  
If the theme is currently active, it will be replaced with the default one.

---

Related pages:
- [Making Your Own Theme](Making%20Your%20Own%20Theme.md)
- [Themes Architecture](Themes%20Architecture.md)