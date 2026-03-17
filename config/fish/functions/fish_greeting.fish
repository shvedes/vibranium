function fish_greeting
  if not test -f $XDG_CONFIG_HOME/fish/states/silent
    echo "Apply changes in "(set_color yellow)"~/.config/fish/config.fish"(set_color normal)
    echo "Toggle this message: "(set_color green)"toggle-startup-message"(set_color normal)
    echo "List additional shell functions: "(set_color green)"flist"(set_color normal)
    echo "Fish shell documentation: "(set_color green)"help"(set_color normal)

    if test -f $VIBRANIUM_STATE/update.available
      echo "New update available! To run "(set_color green)update-vibranium(set_color normal)" to update"
    end
  end
end
