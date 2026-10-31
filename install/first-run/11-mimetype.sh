#!/bin/bash

declare -A mime_apps=(
  [x-scheme-handler/http]=chromium.desktop
  [x-scheme-handler/https]=chromium.desktop
  [text/html]=chromium.desktop

  [application/pdf]=org.pwmt.zathura.desktop
  [application/epub+zip]=org.pwmt.zathura.desktop
  [application/postscript]=org.pwmt.zathura.desktop

  [inode/directory]=thunar.desktop

  [image/jpeg]=image-viewer.desktop
  [image/png]=image-viewer.desktop
  [image/webp]=image-viewer.desktop
  [image/gif]=image-viewer.desktop
  [image/avif]=image-viewer.desktop
  [image/heif]=image-viewer.desktop
  [image/heic]=image-viewer.desktop
  [image/svg+xml]=image-viewer.desktop
  [image/vnd.adobe.photoshop]=image-viewer.desktop
  [image/x-psd]=image-viewer.desktop
  [image/x-canon-cr2]=image-viewer.desktop
  [image/x-nikon-nef]=image-viewer.desktop

  [video/mp4]=mpv.desktop
  [video/webm]=mpv.desktop
  [video/x-matroska]=mpv.desktop
  [video/avi]=mpv.desktop
  [video/mpeg]=mpv.desktop

  [audio/mpeg]=mpv.desktop
  [audio/flac]=mpv.desktop
  [audio/wav]=mpv.desktop
  [audio/ogg]=mpv.desktop
  [audio/opus]=mpv.desktop

  [text/plain]=nvim.desktop
  [text/markdown]=nvim.desktop
  [text/x-shellscript]=nvim.desktop
  [application/json]=nvim.desktop
  [application/x-yaml]=nvim.desktop

  [application/x-bittorrent]=org.qbittorrent.qBittorrent.desktop
  [x-scheme-handler/magnet]=org.qbittorrent.qBittorrent.desktop
)

for mime in "${!mime_apps[@]}"; do
  xdg-mime default "${mime_apps[$mime]}" "$mime"
done
