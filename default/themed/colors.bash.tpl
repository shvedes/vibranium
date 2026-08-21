# shellcheck disable=all

# P_ stands for Pango.
#
# These variables are used by other
# bash scripts that invoke notifications
# with formatted output.

P_BACKGROUND_H="{{ background_h_lower }}"
P_BACKGROUND_0="{{ background_0_lower }}"
P_BACKGROUND_1="{{ background_1_lower }}"
P_BACKGROUND_2="{{ background_2_lower }}"
P_BACKGROUND_3="{{ background_3_lower }}"
P_BACKGROUND_4="{{ background_4_lower }}"
P_BACKGROUND_5="{{ background_5_lower }}"

P_FOREGROUND_H="{{ foreground_h_lower }}"
P_FOREGROUND_0="{{ foreground_0_lower }}"
P_FOREGROUND_1="{{ foreground_1_lower }}"
P_FOREGROUND_2="{{ foreground_2_lower }}"
P_FOREGROUND_3="{{ foreground_3_lower }}"
P_FOREGROUND_4="{{ foreground_4_lower }}"

P_ACCENT_DIM="{{ accent_lower|dim=0.10 }}"
P_ACCENT="{{ accent_lower }}"
P_ACCENT_BRIGHT="{{ accent_lower|pop=0.10 }}"

P_BLACK_DIM="{{ black_lower|dim=0.10 }}"
P_BLACK="{{ black_lower }}"
P_BLACK_BRIGHT="{{ black_lower|pop=0.10 }}"

P_GRAY_DIM="{{ gray_lower|dim=0.10 }}"
P_GRAY="{{ gray_lower }}"
P_GRAY_BRIGHT="{{ gray_lower|pop=0.10 }}"

P_RED_DIM="{{ red_lower|dim=0.10 }}"
P_RED="{{ red_lower }}"
P_RED_BRIGHT="{{ red_lower|pop=0.10 }}"

P_PINK_DIM="{{ pink_lower|dim=0.10 }}"
P_PINK="{{ pink_lower }}"
P_PINK_BRIGHT="{{ pink_lower|pop=0.10 }}"

P_GREEN_DIM="{{ green_lower|dim=0.10 }}"
P_GREEN="{{ green_lower }}"
P_GREEN_BRIGHT="{{ green_lower|pop=0.10 }}"

P_YELLOW_DIM="{{ yellow_lower|dim=0.10 }}"
P_YELLOW="{{ yellow_lower }}"
P_YELLOW_BRIGHT="{{ yellow_lower|pop=0.10 }}"

P_ORANGE_DIM="{{ orange_lower|dim=0.10 }}"
P_ORANGE="{{ orange_lower }}"
P_ORANGE_BRIGHT="{{ orange_lower|pop=0.10 }}"

P_BLUE_DIM="{{ blue_lower|dim=0.10 }}"
P_BLUE="{{ blue_lower }}"
P_BLUE_BRIGHT="{{ blue_lower|pop=0.10 }}"

P_PURPLE_DIM="{{ purple_lower|dim=0.10 }}"
P_PURPLE="{{ purple_lower }}"
P_PURPLE_BRIGHT="{{ purple_lower|pop=0.10 }}"

P_CYAN_DIM="{{ cyan_lower|dim=0.10 }}"
P_CYAN="{{ cyan_lower }}"
P_CYAN_BRIGHT="{{ cyan_lower|pop=0.10 }}"

P_WHITE_DIM="{{ white_lower|dim=0.10 }}"
P_WHITE="{{ white_lower }}"
P_WHITE_BRIGHT="{{ white_lower|pop=0.10 }}"

# vim:ft=bash
