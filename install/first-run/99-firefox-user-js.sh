#!/usr/bin/env bash

# WARN: at the moment, it doesn't work as expected.

exit 0

firefox -CreateProfile default-release

PROFILE_DIR=$(echo "$HOME/.config/mozilla/firefox/"*.default-release)

# Source: BetterFox
# https://github.com/yokoffing/Betterfox/blob/main/Smoothfox.js
cat > "$PROFILE_DIR/user.js" <<EOF
user_pref("apz.overscroll.enabled", true); // DEFAULT NON-LINUX
user_pref("general.smoothScroll", true); // DEFAULT
user_pref("general.smoothScroll.msdPhysics.continuousMotionMaxDeltaMS", 12);
user_pref("general.smoothScroll.msdPhysics.enabled", true);
user_pref("general.smoothScroll.msdPhysics.motionBeginSpringConstant", 600);
user_pref("general.smoothScroll.msdPhysics.regularSpringConstant", 650);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaMS", 25);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaRatio", "2");
user_pref("general.smoothScroll.msdPhysics.slowdownSpringConstant", 250);
user_pref("general.smoothScroll.currentVelocityWeighting", "1");
user_pref("general.smoothScroll.stopDecelerationWeighting", "1");
user_pref("mousewheel.default.delta_multiplier_y", 300); // 250-400; adjust this number to your liking

user_pref("browser.compactmode.show", true);
user_pref("browser.uidensity", 1); // use compact mode by default
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
EOF
