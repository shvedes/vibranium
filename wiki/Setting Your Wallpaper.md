To add a custom wallpaper to a theme, you have two options: *GUI* and *CLI*. Let’s start with the GUI.

To set your wallpaper, open your file manager (`SUPER E`), locate the image, and right-click it. Then select "*Set as wallpaper*". That’s it. Vibranium will apply it immediately and remember your choice. The next time you switch wallpapers (`CTRL ALT W`), your custom one will be included alongside the defaults.

To set a wallpaper via CLI, use the `vb-core-wallpaper` command. To see all available options, use the `--help` flag. For this case, the syntax is straightforward:

```bash
vb-core-wallpaper /path/to/your/beautiful_wallpaper.png
```

Vibranium stores wallpapers **per theme**, meaning that if you want to use the same wallpaper with a different theme, you’ll need to set it again.

You can manage your wallpapers via: *Vibranium Menu* (`CTRL ALT V`) -> *Settings* -> *Misc* -> *User wallpapers*. From there, you can open the folder, view, or delete wallpapers.
