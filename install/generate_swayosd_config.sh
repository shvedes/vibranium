#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/swayosd/style.css"
@import url("../vibranium/theme/current/swayosd.css");
@import url("../../.local/share/vibranium/defaults/swayosd.css");

window#osd, progressbar {
	border-radius:	0px;
}

progressbar {
	min-height:	12px;
}
EOF

cat <<EOF > "$HOME/.config/swayosd/config.toml"
[server]
top_margin = 0.8
EOF
