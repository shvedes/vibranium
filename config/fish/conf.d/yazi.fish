if command -q yazi
    function yazi
        set -l tmp_base (set -q XDG_RUNTIME_DIR; and echo $XDG_RUNTIME_DIR; or echo /tmp)
        set -l tmp "$tmp_base/yazi-cwd.$fish_pid"

        command yazi $argv --cwd-file="$tmp"

        if test -s "$tmp"
            read -l cwd <"$tmp"
            if test -n "$cwd"; and test "$cwd" != "$PWD"
                builtin cd -- "$cwd"
            end
        end

        command rm -f -- "$tmp" >/dev/null 2>&1
    end
end
