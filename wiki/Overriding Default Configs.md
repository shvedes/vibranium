Vibranium comes with many apps preconfigured. This doesn’t mean you can’t reconfigure them to your liking. Each application’s config directory is copied from the Vibranium repository during installation. You can inspect it [here](https://github.com/shvedes/vibranium/tree/master/config).

All apps you’ll find in `~/.config/` are fully under your control. You can modify, move, or even delete them. This includes `dunst`, `zathura`, `gtk-*`, `qt*ct`, `nvim`, `waybar`, and more.

If you’re not familiar with a program’s config syntax, you can use `man` to learn about it. For example, to view the configuration reference for the notification daemon:

```bash
man dunstrc
````

To learn how to configure the document reader:

```bash
man zathurarc
```

App launcher and menus:

```bash
man rofi
```

And so on. You can also find the same information online.