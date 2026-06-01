![preview](https://raw.githubusercontent.com/shvedes/vibranium/master/.github/media/themes.gif)

Vibranium comes with many different themes.
You can switch between them using the theme picker (`CTRL ALT + T`).
The currently active theme is highlighted in bold italic text.

Most themes are forks of Neovim themes, but not all of them.
There are also ports of official and community Omarchy themes, adapted for Vibranium.

At the time of writing, there are 26 pre-installed themes available, and many more available via *Vibranium Menu* -> *Install* -> *Theme*. Use [this](https://github.com/search?q=vibranium-theme-&type=repositories) link to get all additional, officially supported Vibranium themes.

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

To install an Omarchy theme, go to *Vibranium Menu* (`CTRL ALT V`) -> *Install* -> *Theme*.  
A terminal window with several prompts will appear.

> [!TIP]
> You can copy-paste a theme installation command from theme README.md like so:
> ```
> omarchy-theme-install  <url>
> ```
> It still will work for you!

Before installation, the installer verifies that the theme is supported and will fail if it is not.

Once installed, the theme is applied immediately and becomes available in the theme picker (`CTRL ALT + T`).

### Removing a community theme

To remove a theme, follow the reverse process.  
Open *Vibranium Menu* (`CTRL ALT V`) -> *Remove* -> *Theme*. A rofi window will appear with a list of all installed community themes.

Select the theme you want and press *Enter*.  
If the theme is currently active, it will be replaced with the default one.

## Theme hooks

If you want to extend your theme capabilities, you can create custom bash scripts, that is to say, "hooks", that will execute every time you change the active theme. You may have as many hooks as you want.

Go to `~/.config/vibranium/hooks/theme` and check out `example.sh` which will guide you through.

Also don't forget that you have an option to modify and/or create your own templates in `~/.config/vibranium/themed`. Read [Themes Architecture](Themes%20Architecture.md) for more information.

## Additional apps

Some apps require manual theme set in order to make it work.

#### Obsidian

Go to **Settings** -> **Appearance** and select the *Vibranium* theme from the theme dropdown.

If you don't see the Vibranium theme, try changing the system theme, reopening the settings window, and checking again. Most likely, this is the first time you've launched Obsidian, so Vibranium needed to generate the theme first.

#### VS Code / VS Code Insiders / VSCodium / VSCodium Insiders

The theme will not be applied automatically. You need to select it manually from the Extensions view.

The Vibranium extension should already be installed by default. Simply enable it and you're done.

---

Related pages:
- [Making Your Own Theme](Making%20Your%20Own%20Theme.md)
- [Themes Architecture](Themes%20Architecture.md)