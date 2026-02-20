# systemd-units.awk

# Reads 'pacman -Ql <pkg>' output from stdin.
# Categorizes .service/.socket files found in systemd directories,
# then prints them in priority order: user socket, user service, sys socket, sys service.
#
# Output format (one unit per line):
#   <type> <scope> <path>
#   e.g.: socket user /usr/lib/systemd/user/pipewire.socket

/\/systemd\/.*\.(service|socket)$/ && $2 !~ /@/ {
    path = $2

    if      (path ~ /\/systemd\/user\/[^\/]+\.socket$/)   user_sockets[++us]  = path
    else if (path ~ /\/systemd\/user\/[^\/]+\.service$/)  user_services[++uv] = path
    else if (path ~ /\/systemd\/system\/[^\/]+\.socket$/) sys_sockets[++ss]   = path
    else if (path ~ /\/systemd\/system\/[^\/]+\.service$/)sys_services[++sv]  = path
}

END {
    for (i = 1; i <= us; i++) print "socket  user   " user_sockets[i]
    for (i = 1; i <= uv; i++) print "service user   " user_services[i]
    for (i = 1; i <= ss; i++) print "socket  system " sys_sockets[i]
    for (i = 1; i <= sv; i++) print "service system " sys_services[i]
}
