# @vibranium
# @description Convert images to JPG
function img2jpg() {
  if ! command -v magick >/dev/null 2>&1; then
    echo "imagemagick is not installed!" >&2
    return 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${funcstack[1]} <image> [magick options]"
    echo "Converts image to JPG format (quality 95, stripped metadata by default)"
    return 0
  fi

  if [[ -z "${1:-}" ]]; then
    echo "usage: ${funcstack[1]} <image> [magick options]" >&2
    return 1
  fi

  local img="$1"
  shift
  local -a rest=("$@")

  if [[ ! -f "$img" ]]; then
    echo "File not found: $img" >&2
    return 1
  fi

  local mime
  mime=$(file --brief --mime-type "$img") || return 1
  if [[ $mime == image/jpeg ]]; then
    echo "image is already a jpeg!" >&2
    return 1
  fi

  local base="${img%.*}"
  local out="${base}-converted.jpg"

  if magick "$img" "${rest[@]}" \
    -quality 95 \
    -strip \
    "$out"; then
    echo "File saved to $out"
  else
    echo "Conversion failed for $img" >&2
    return 1
  fi
}
