#!/usr/bin/env bash

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RESET=$'\e[0m'
GRAY=$'\e[90m'
CYAN=$'\e[0;36m'

spinner_frames=(
    '[=           ]' '[==          ]' '[===         ]' '[====        ]'
    '[ ====       ]' '[  ====      ]' '[   ====     ]' '[    ====    ]'
    '[     ====   ]' '[      ====  ]' '[       ==== ]' '[        ====]'
    '[         ===]' '[          ==]' '[           =]'
)

# Create frame file once — persists across all install_theme() calls
frame_file=$(mktemp)
echo 0 > "$frame_file"

_spinner() {
  local name="$1"
  local file="$2"
  local i
  i=$(cat "$file")           # seed from previous run
  while true; do
    printf "\r\033[K%s[GTK THEMES]%s Installing %s%s%s %s" \
      "$YELLOW" "$RESET" "$CYAN" "$name" "$RESET" "${GRAY}${spinner_frames[$i]}${RESET}"
    echo "$i" > "$file"      # persist current index
    i=$(( (i + 1) % ${#spinner_frames[@]} ))
    sleep 0.15
  done
}

# Array of repositories
REPOS=(
  "Osaka-GTK-Theme"
  "Gruvbox-GTK-Theme"
  "Nightfox-GTK-Theme"
  "Rose-Pine-GTK-Theme"
  "Tokyonight-GTK-Theme"
  "Everforest-GTK-Theme"
  "Catppuccin-GTK-Theme"
  "Kanagawa-GKT-Theme"
  #          ^
  # This is hilarious
)

# Destination directory
DEST_DIR="$HOME/.themes"
mkdir -p "$DEST_DIR"

# Associative array for accents ("" for no -t flag and no accent in name)
declare -A accents
accents["Osaka-GTK-Theme"]="teal"
accents["Gruvbox-GTK-Theme"]="green"
accents["Nightfox-GTK-Theme"]=""
accents["Rose-Pine-GTK-Theme"]="pink"
accents["Tokyonight-GTK-Theme"]=""
accents["Everforest-GTK-Theme"]="green"
accents["Catppuccin-GTK-Theme"]="lavender"
accents["Kanagawa-GKT-Theme"]="grey"

# Associative array for colors per theme (space-separated strings)
declare -A colors
colors["Osaka-GTK-Theme"]="dark light"
colors["Gruvbox-GTK-Theme"]="dark light"
colors["Nightfox-GTK-Theme"]="dark"
colors["Rose-Pine-GTK-Theme"]="dark light"
colors["Tokyonight-GTK-Theme"]="dark"
colors["Everforest-GTK-Theme"]="dark"
colors["Catppuccin-GTK-Theme"]="dark light"
colors["Kanagawa-GKT-Theme"]="dark"

# Function to install a theme repo
install_theme() {
  local repo="$1"
  local clone_dir="./$repo"
  local base_name=""
  local variants=()

  # Strip "-GTK-Theme" / "-GKT-Theme" suffix for display
  local display_name="${repo//-GTK-Theme/}"
  display_name="${display_name//-GKT-Theme/}"

  # Start a single spinner that runs from clone through all variants
  local spinner_pid
  _spinner "$display_name" "$frame_file" &
  spinner_pid=$!

  git clone -q "https://github.com/Fausto-Korpsvart/$repo"
  if (( $? != 0 )); then
    kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
    printf "\r\033[K%s[GTK THEMES]%s Failed to clone %s%s%s\n" "$RED" "$RESET" "$CYAN" "$display_name" "$RESET"
    return 1
  fi

  cd "$clone_dir/themes" || {
    kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
    printf "\r\033[K%s[GTK THEMES]%s Failed to enter %s%s%s\n" "$RED" "$RESET" "$CYAN" "$display_name" "$RESET"
    cd ..; rm -rf "$clone_dir"; return 1
  }
  git switch -q --detach HEAD~3

  # Set base_name and variants based on repo
  case "$repo" in
    "Osaka-GTK-Theme")
      base_name="Osaka"
      variants=("default" "solarized")
      ;;
    "Gruvbox-GTK-Theme")
      base_name="Gruvbox"
      variants=("default" "soft" "medium")
      ;;
    "Nightfox-GTK-Theme")
      base_name="Nightfox"
      variants=("default" "carbonfox" "duskfox" "nordfox" "terafox")
      ;;
    "Rose-Pine-GTK-Theme")
      base_name="Rosepine"
      variants=("default" "moon")
      ;;
    "Tokyonight-GTK-Theme")
      base_name="Tokyonight"
      variants=("default" "moon")
      ;;
    "Everforest-GTK-Theme")
      base_name="Everforest"
      variants=("default" "soft" "medium")
      ;;
    "Catppuccin-GTK-Theme")
      base_name="Catppuccin"
      variants=("default" "frappe" "macchiato")
      ;;
    "Kanagawa-GKT-Theme")
      base_name="Kanagawa"
      variants=("default" "dragon")
      ;;
    *)
      kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
      printf "\r\033[K%s[GTK THEMES]%s No configuration for %s%s%s\n" "$RED" "$RESET" "$CYAN" "$display_name" "$RESET"
      cd ../..
      rm -rf "$clone_dir"
      return 1
      ;;
  esac

  local accent="${accents[$repo]}"
  local accent_param=""
  local accent_in_name=""
  if [ -n "$accent" ]; then
    accent_param="$accent"
    accent_in_name="$(tr '[:lower:]' '[:upper:]' <<< ${accent:0:1})${accent:1}"
  fi

  # Get colors for this repo as array
  local repo_colors=(${colors[$repo]})

  # Loop over colors
  for color in "${repo_colors[@]}"; do
    local this_variants=("${variants[@]}")
    if [ "$color" == "light" ]; then
      this_variants=("default")  # Only default for light
    fi

    # Loop over variants
    for variant in "${this_variants[@]}"; do
      local tweaks=""
      if [ "$variant" != "default" ]; then
        tweaks="--tweaks $variant"
      fi

      local generated_variant_suffix=""
      if [ "$variant" != "default" ]; then
        local cap_variant; cap_variant="$(tr '[:lower:]' '[:upper:]' <<< ${variant:0:1})${variant:1}"
        generated_variant_suffix="-$cap_variant"
      fi

      local desired_name=""
      local desired_suffix=""
      case "$repo" in
        "Catppuccin-GTK-Theme")
          if [ "$color" == "light" ]; then
            desired_name="Catppuccin-Latte"
          else
            case "$variant" in
              "default") desired_suffix="-Mocha" ;;
              "frappe") desired_suffix="-Frappe" ;;
              "macchiato") desired_suffix="-Macchiato" ;;
            esac
            desired_name="$base_name$desired_suffix"
          fi
          ;;
        "Gruvbox-GTK-Theme" | "Everforest-GTK-Theme")
          if [ "$color" == "light" ]; then
            desired_name="$base_name-Light"
          else
            case "$variant" in
              "default") desired_suffix="-Hard" ;;
              "soft") desired_suffix="-Soft" ;;
              "medium") desired_suffix="-Medium" ;;
            esac
            desired_name="$base_name$desired_suffix"
          fi
          ;;
        "Nightfox-GTK-Theme")
          case "$variant" in
            "default") desired_name="Nightfox" ;;
            *) desired_suffix="-$(tr '[:lower:]' '[:upper:]' <<< ${variant:0:1})${variant:1}" ; desired_name="$base_name$desired_suffix" ;;
          esac
          ;;
        "Rose-Pine-GTK-Theme")
          if [ "$color" == "light" ]; then
            desired_name="Rosepine-Dawn"
          else
            case "$variant" in
              "default") desired_name="Rosepine" ;;
              "moon") desired_name="Rosepine-Moon" ;;
            esac
          fi
          ;;
        "Tokyonight-GTK-Theme")
          case "$variant" in
            "default") desired_name="Tokyonight-Night" ;;
            "moon") desired_name="Tokyonight-Moon" ;;
          esac
          ;;
        "Kanagawa-GKT-Theme")
          if [ "$color" = "light" ]; then
            desired_name="$base_name-Lotus"
          else
            case "$variant" in
              "default") desired_name="Kanagawa-Wave" ;;
              "dragon") desired_name="Kanagawa-Dragon" ;;
            esac
          fi
          ;;
        "Osaka-GTK-Theme")
          case "$variant" in
            "default") desired_suffix="" ;;
            "solarized") desired_suffix="-Solarized" ;;
          esac
          local color_upper; color_upper="$(tr '[:lower:]' '[:upper:]' <<< "${color:0:1}")${color:1}"

          desired_name="$base_name$desired_suffix"
          if [ "$color" == "light" ] || [ "$variant" == "default" ]; then
            desired_name="$desired_name-$color_upper"
          fi
          ;;
      esac

      local color_upper="$(tr '[:lower:]' '[:upper:]' <<< ${color:0:1})${color:1}"

      local generated_base="$base_name"
      if [ -n "$accent_in_name" ]; then
        generated_base+="-$accent_in_name"
      fi
      generated_base+="-$color_upper-Compact$generated_variant_suffix"

      install_opts="-s compact -c $color $tweaks -t $accent_param"
      eval "./install.sh $install_opts" &>/dev/null || { echo "Install failed for $repo $variant $color"; continue; }

      # Rename if directories exist
      if [ -d "$DEST_DIR/$generated_base" ]; then
        mv "$DEST_DIR/$generated_base" "$DEST_DIR/$desired_name"
        sed -i -e "/^Name=/s/=.*/=${desired_name}/" \
            -e "/^GtkTheme=/s/=.*/=${desired_name}/" \
            -e "/^MetacityTheme=/s/=.*/=${desired_name}/" \
            -e "/^CursorTheme/s/=.*/=macOS/" \
            "$DEST_DIR/${desired_name}/index.theme"
      else
        echo "Warning: $generated_base not found"
      fi

      local generated_hdpi="$generated_base-hdpi"
      local desired_hdpi="$desired_name-hdpi"
      if [ -d "$DEST_DIR/$generated_hdpi" ]; then
        mv "$DEST_DIR/$generated_hdpi" "$DEST_DIR/$desired_hdpi"
      fi

      local generated_xhdpi="$generated_base-xhdpi"
      local desired_xhdpi="$desired_name-xhdpi"
      if [ -d "$DEST_DIR/$generated_xhdpi" ]; then
        mv "$DEST_DIR/$generated_xhdpi" "$DEST_DIR/$desired_xhdpi"
      fi
    done
  done

  # All variants done -- kill spinner and print final settled line
  kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null

  # Clean up
  cd ../..
  rm -rf "$clone_dir"
}

# Main loop
for repo in "${REPOS[@]}"; do
  install_theme "$repo"
done

rm -f "$frame_file"
mv "$HOME/.themes" "$HOME/.local/share"
ln -sf "$HOME/.local/share/.themes" "$HOME/.themes"

printf "\r\033[K%s[GTK THEMES]%s GTK themes installed\n" "$GREEN" "$RESET"

