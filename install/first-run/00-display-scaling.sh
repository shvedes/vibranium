#!/bin/bash

# Reference DPI that UI toolkits treat as "1x" (the CSS/Windows standard).
# Scale = physical_dpi / REFERENCE_DPI, rounded to the nearest clean step.
readonly REFERENCE_DPI=96

# Snap a raw floating-point scale to the nearest 0.25 increment, clamped to
# the range [1.0, 4.0]. Hyprland renders cleanly at 0.25-step boundaries.
snap_scale() {
    local raw=$1
    awk -v r="$raw" 'BEGIN {
        snapped = int(r * 4 + 0.5) / 4
        if (snapped < 1) snapped = 1
        if (snapped > 4) snapped = 4
        printf "%.2f\n", snapped
    }'
}

# Compute scale from actual physical pixel density when mm dimensions are
# available. Uses diagonal to stay correct regardless of monitor rotation.
# Prints the snapped scale value.
compute_scale_from_dpi() {
    local width_px=$1
    local height_px=$2
    local phys_w_mm=$3
    local phys_h_mm=$4

    awk -v wp="$width_px" -v hp="$height_px" \
        -v wm="$phys_w_mm" -v hm="$phys_h_mm" \
        -v ref="$REFERENCE_DPI" \
    'BEGIN {
        diag_px = sqrt(wp*wp + hp*hp)
        diag_mm = sqrt(wm*wm + hm*hm)
        diag_in = diag_mm / 25.4
        ppi     = diag_px / diag_in
        raw     = ppi / ref

        # Round to nearest 0.25 step, clamp to [1, 4]
        snapped = int(raw * 4 + 0.5) / 4
        if (snapped < 1) snapped = 1
        if (snapped > 4) snapped = 4
        printf "%.2f\n", snapped
    }'
}

# Fallback table used only when physicalWidth/physicalHeight are zero or
# missing (virtual monitors, mirrored outputs, broken EDID). This path
# cannot know the true DPI so it guesses from resolution tiers only.
fallback_scale_for_height() {
    local height=$1
    local scale

    if   ((height <= 1080)); then scale=1
    elif ((height <= 1200)); then scale=1.1
    elif ((height <= 1440)); then scale=1.25
    elif ((height <= 1600)); then scale=1.4
    elif ((height <= 1800)); then scale=1.5
    elif ((height <= 2160)); then scale=2
    elif ((height <= 2880)); then scale=2.5
    elif ((height <= 3200)); then scale=2.5
    elif ((height <= 3840)); then scale=3
    elif ((height <= 4320)); then scale=3.5
    else                          scale=4
    fi

    echo "$scale"
}

# Fetch the full monitor list once upfront to avoid redundant hyprctl calls.
ALL_MONITORS_JSON=$(hyprctl monitors -j)

# Suppress Hyprland's built-in per-change scale popups while we apply all
# monitors in batch; we send our own notification per monitor below.
hyprctl -q eval 'hl.config({ misc = { disable_scale_notification = true }})'

# jq -c '.[]' emits one compact JSON object per line, one per monitor.
while IFS= read -r monitor_json; do
    MONITOR_NAME=$(jq -r '.name' <<<"$monitor_json")
    WIDTH_PX=$(jq -r '.width' <<<"$monitor_json")
    HEIGHT_PX=$(jq -r '.height' <<<"$monitor_json")
    PHYS_W_MM=$(jq -r '.physicalWidth' <<<"$monitor_json")
    PHYS_H_MM=$(jq -r '.physicalHeight' <<<"$monitor_json")

    # Use DPI-based scale when physical dimensions are known and non-zero.
    # Fall back to the resolution table for virtual/unknown monitors.
    if ((PHYS_W_MM > 0 && PHYS_H_MM > 0)); then
        NEW_SCALE=$(compute_scale_from_dpi "$WIDTH_PX" "$HEIGHT_PX" "$PHYS_W_MM" "$PHYS_H_MM")
    else
        NEW_SCALE=$(fallback_scale_for_height "$HEIGHT_PX")
    fi

    # Apply the computed scale to this specific monitor output.
    hyprctl -q eval "hl.monitor({ output = '$MONITOR_NAME', mode = 'preferred', position = 'auto', scale = '$NEW_SCALE' })"

    # Use a random replacement ID so each monitor gets its own notification
    # slot rather than all of them collapsing into a single toast.
    notify-send -r "$RANDOM" -t 7000 "Vibranium" "${MONITOR_NAME}: scaling set to ${NEW_SCALE}x"

    # Emit the Lua config snippet for this monitor.
    # VMs always get scale 1 regardless of detected resolution.
    if [[ $CHASSIS_TYPE == vm ]]; then
        printf "\nhl.monitor({\n\toutput = '%s',\n\tmode = 'preferred',\n\tposition = 'auto',\n\tscale = '1'\n})\n" \
            "$MONITOR_NAME" >> "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/monitors.lua"
    else
        printf "\nhl.monitor({\n\toutput = '%s',\n\tmode = 'preferred',\n\tposition = 'auto',\n\tscale = '%s'\n})\n" \
            "$MONITOR_NAME" "$NEW_SCALE" >> "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/monitors.lua"
    fi

done < <(jq -c '.[]' <<<"$ALL_MONITORS_JSON")

# Re-enable Hyprland's built-in scale change notifications now that we're done.
hyprctl -q eval 'hl.config({ misc = { disable_scale_notification = false }})'
hyprctl -q reload config-only
