# Wraps yazi (https://github.com/sxyazi/yazi): cd to wherever you
# exited yazi from.
if command -v yazi > /dev/null
    function yazi --description 'open yazi, cd to its exit dir on quit'
        set -l tmp (mktemp -t yazi-cwd.XXXXXX)

        command yazi $argv --cwd-file=$tmp
        set -l cwd (cat $tmp)

        if test "$cwd" != "$PWD"; and test -d "$cwd"
            builtin cd -- $cwd
        end

        rm -f -- $tmp
    end
end
