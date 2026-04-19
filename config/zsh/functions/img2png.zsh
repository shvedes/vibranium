# @vibranium
# @description Convert images to PNG
function img2png() {
  if ! command -v magick >/dev/null 2>&1; then
    echo "imagemagick is not installed!" >&2
    return 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${funcstack[1]} <image> [magick options]"
    echo "Converts image to optimized PNG (lossless compression, stripped metadata)"
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
  if [[ $mime == image/png ]]; then
    echo "image is already a png!" >&2
    return 1
  fi

  local out="${img%.*}-optimized.png"

  if magick "$img" "${rest[@]}" -strip \
    -define png:compression-filter=5 \
    -define png:compression-level=9 \
    -define png:compression-strategy=1 \
    -define png:exclude-chunk=all \
    "$out"; then
    echo "File saved to $out"
  else
    echo "Conversion failed for $img" >&2
    return 1
  fi
}
