#!/usr/bin/env bash

# $CHASSIS_TYPE is available externaly.

P_YELLOW='#e0af68'
P_ACCENT='#7aa2f7'
P_RED='#f7768e'

if [[ "$CHASSIS_TYPE" == vm ]]; then
    msg="\n<span foreground='${P_YELLOW}'><b><i>You need to be aware of certain things</i></b></span>:\n\n"
    msg+="<span foreground='${P_ACCENT}'><b>•</b></span> "
    msg+="<span foreground='${P_RED}'><b>Screen recording is not available</b></span>\n"
    msg+="<span foreground='${P_ACCENT}'><b>•</b></span> "
    msg+="<span foreground='${P_RED}'><b>Do not expect power profiles to work as expected</b></span>\n"
    msg+="<span foreground='${P_ACCENT}'><b>•</b></span> "
    msg+="<span foreground='${P_RED}'><b>Some effects will not work due to the nature of the virtual GPU</b></span>\n"
    msg+="<span foreground='${P_ACCENT}'><b>•</b></span> "
    msg+="<span foreground='${P_RED}'><b>Overall performance will be worse than on real hardware</b></span>\n\n"
    msg+="Use <span foreground='${P_YELLOW}'><b>Vibranium</b></span> on a virtual machine for informational purposes only.\n"
    msg+="Many things have not been tested, so there may be unexpected surprises.\n"
    msg+="Only <span foreground='${P_YELLOW}'><b>QEMU</b></span> has been tested; "
    msg+="<span foreground='${P_YELLOW}'><b>Virtualbox</b></span> & "
    msg+="<span foreground='${P_YELLOW}'><b>VMware</b></span> are not supported.\n\n"
    msg+="<b>Right-click</b> to dismiss this notification"

    notify-send -r $RANDOM -t 1800000 "Vibranium Is Running In a Virtual Machine" "$msg"
fi
