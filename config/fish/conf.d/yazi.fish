if command -q yazi
  function yazi
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    command yazi $argv --cwd-file="$tmp"

    if read -z cwd < "$tmp"; and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
      builtin cd -- "$cwd"
    end

    command rm -f -- "$tmp" &> /dev/null
  end
end
