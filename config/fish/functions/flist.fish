function flist
  set -l dir $XDG_CONFIG_HOME/fish/functions
  set -l funcs

  for file in $dir/*.fish
    if test -f $file
      if string match -rq '^\s*#\s*@vibranium' < $file
        set line (head -n 20 $file | string match -r '^\s*function\s+.*' | head -n1)
        set name (string replace -r '^\s*function\s+([^\s]+).*' '$1' -- $line)

        set desc (string match -r -- '--description\s+["'\''].*["'\'']' -- $line \
            | string replace -r -- '^--description\s+["'\''](.+)["'\'']$' '$1')

        if test -n "$desc"
          set funcs $funcs "$name|$desc"
        else
          set funcs $funcs "$name|"
        end
      end
    end
  end

  set -l max_len 0
  for f in $funcs
    set -l n (string split "|" $f)[1]
    if test (string length $n) -gt $max_len
      set max_len (string length $n)
    end
  end

  set -l name_col_width (math $max_len + 3)

  set_color --bold white
  printf "%-*s  | %s\n" $name_col_width "Function" "Description"
  set_color normal
  printf "%s\n" (string repeat -n (math $name_col_width + 25) "-")

  for f in $funcs
    set -l parts (string split "|" $f)

    set_color green
    printf "%-*s" $name_col_width $parts[1]
    set_color normal
    printf "  | "
    set_color yellow
    printf "%s\n" $parts[2]
    set_color normal
  end
end
