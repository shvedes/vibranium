if not status is-interactive
    return 0
end

set -l plugins jorgebucaran/autopair.fish meaningful-ooo/sponge
set -l installed_any 0

if not functions -q fisher
    if curl -s -o /dev/null --connect-timeout 2 --max-time 5 https://github.com
        echo "Installing" $YEL"fisher"$RST
        curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
        fisher install jorgebucaran/fisher < /dev/null > /dev/null 2>&1
        set installed_any 1
    else
        echo $YEL"Warning:"$RST "no internet, skipping plugin install" >&2
    end
end

if functions -q fisher
    set -l installed (fisher list 2>/dev/null)
    for plugin in $plugins
        if not contains -- $plugin $installed
            echo "Installing $YEL"(string split / $plugin)[-1]$RST
            fisher install $plugin < /dev/null > /dev/null 2>&1
            set installed_any 1
        end
    end
end

if test "$installed_any" -eq 1
    clear
end

set -e plugins
