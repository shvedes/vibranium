# P_ stands for Pango.
#
# These variables are used by other
# bash scripts that invoke notifications
# with formatted output.

P_BACKGROUND_H="{{ background_lower|lightness=-0.02 }}"
P_BACKGROUND_0="{{ background_lower }}"
P_BACKGROUND_1="{{ background_lower|lightness=+0.04 }}"
P_BACKGROUND_2="{{ background_lower|lightness=+0.08 }}"
P_BACKGROUND_3="{{ background_lower|lightness=+0.12 }}"
P_BACKGROUND_4="{{ background_lower|lightness=+0.16 }}"
P_BACKGROUND_5="{{ background_lower|lightness=+0.20 }}"

P_FOREGROUND_H="{{ foreground_lower|lightness=+0.02 }}"
P_FOREGROUND_0="{{ foreground_lower }}"
P_FOREGROUND_1="{{ foreground_lower|lightness=-0.04 }}"
P_FOREGROUND_2="{{ foreground_lower|lightness=-0.08 }}"
P_FOREGROUND_3="{{ foreground_lower|lightness=-0.12 }}"
P_FOREGROUND_4="{{ foreground_lower|lightness=-0.16 }}"

P_ACCENT_DIM="{{ accent_lower|lightness=-0.15 }}"
P_ACCENT="{{ accent_lower }}"
P_ACCENT_BRIGHT="{{ accent_lower|lightness=+0.15 }}"

P_BLACK_DIM="{{ background_lower|lightness=+0.15 }}"
P_BLACK="{{ background_lower|lightness=+0.15 }}"
P_BLACK_BRIGHT="{{ background_lower|lightness=+0.20 }}"

P_GRAY_DIM="{{ background_lower|lightness=+0.15 }}"
P_GRAY="{{ background_lower|lightness=+0.25 }}"
P_GRAY_BRIGHT="{{ background_lower|lightness=+0.35 }}"

P_RED_DIM="{{ color1_lower|lightness=-0.15 }}"
P_RED="{{ color1_lower }}"
P_RED_BRIGHT="{{ color1_lower|lightness=+0.15 }}"

P_PINK_DIM="{{ color5_lower|lightness=-0.15 }}"
P_PINK="{{ color5_lower }}"
P_PINK_BRIGHT="{{ color5_lower|lightness=+0.15 }}"

P_GREEN_DIM="{{ color2_lower|lightness=-0.15 }}"
P_GREEN="{{ color2_lower }}"
P_GREEN_BRIGHT="{{ color2_lower|lightness=+0.15 }}"

P_YELLOW_DIM="{{ color3_lower|lightness=-0.15 }}"
P_YELLOW="{{ color3_lower }}"
P_YELLOW_BRIGHT="{{ color3_lower|lightness=+0.15 }}"

P_ORANGE_DIM="{{ color11_lower|lightness=-0.15 }}"
P_ORANGE="{{ color11_lower }}"
P_ORANGE_BRIGHT="{{ color11_lower|lightness=+0.15 }}"

P_BLUE_DIM="{{ color4_lower|lightness=-0.15 }}"
P_BLUE="{{ color4_lower }}"
P_BLUE_BRIGHT="{{ color4_lower|lightness=+0.15 }}"

P_PURPLE_DIM="{{ color5_lower|lightness=-0.15 }}"
P_PURPLE="{{ color5_lower }}"
P_PURPLE_BRIGHT="{{ color5_lower|lightness=+0.15 }}"

P_CYAN_DIM="{{ color6_lower|lightness=-0.15 }}"
P_CYAN="{{ color6_lower }}"
P_CYAN_BRIGHT="{{ color6_lower|lightness=+0.15 }}"

P_WHITE_DIM="{{ foreground_lower|lightness=-0.15 }}"
P_WHITE="{{ foreground_lower|lightness=-0.15 }}"
P_WHITE_BRIGHT="{{ foreground_lower|lightness=-0.05 }}"

# vim:ft=bash
