function fish_prompt
    if command -v starship > /dev/null
        starship init fish | source
        fish_prompt
        return 0
    end

    # The greeting prints first, so the first prompt render lands right
    # below it; warn only once instead of on every render.
    if not set -q _starship_warned
        set -g _starship_warned 1
        echo $YEL"Warning"$RST": "$GRN"starship"$RST" not found"
        echo "Using the default fish prompt"
        echo
    end

    set -l code $status
    set -l last_cmd (history search --max 1)

    if test $code -ne 0
        set_color red
        printf '%s %s\n' $code (string escape --no-quoted -- $last_cmd)
        set_color normal
    end

    set_color $fish_color_cwd
    printf '%s' (prompt_pwd)
    set_color normal

    set -l branch (command git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test -n "$branch"
        set_color yellow
        printf ' (%s)' $branch
        set_color normal
    end

    set_color magenta
    printf ' > '
    set_color normal
end
