#!/bin/bash

declare -A mime_apps=(
  # Web
  [x-scheme-handler/http]=chromium.desktop
  [x-scheme-handler/https]=chromium.desktop
  [text/html]=chromium.desktop

  # Documents / eBooks
  [application/pdf]=org.pwmt.zathura.desktop
  [application/epub+zip]=org.pwmt.zathura.desktop
  [application/postscript]=org.pwmt.zathura.desktop

  # Directories
  [inode/directory]=thunar.desktop

  # Images
  [image/jpeg]=imv-dir.desktop
  [image/png]=imv-dir.desktop
  [image/webp]=imv-dir.desktop
  [image/gif]=imv-dir.desktop
  [image/avif]=imv-dir.desktop
  [image/heif]=imv-dir.desktop
  [image/heic]=imv-dir.desktop
  [image/svg+xml]=imv.desktop
  [image/vnd.adobe.photoshop]=imv-dir.desktop
  [image/x-psd]=imv-dir.desktop
  [image/x-canon-cr2]=imv-dir.desktop
  [image/x-nikon-nef]=imv-dir.desktop

  # Videos
  [video/mp4]=mpv.desktop
  [video/webm]=mpv.desktop
  [video/x-matroska]=mpv.desktop
  [video/avi]=mpv.desktop
  [video/mpeg]=mpv.desktop

  # Audio
  [audio/mpeg]=mpv.desktop
  [audio/flac]=mpv.desktop
  [audio/wav]=mpv.desktop
  [audio/ogg]=mpv.desktop
  [audio/opus]=mpv.desktop

  # Archives
  [application/x-compressed-tar]=engrampa.desktop
  [application/x-7z-compressed]=engrampa.desktop
  [application/x-7z-compressed-tar]=engrampa.desktop
  [application/x-ace]=engrampa.desktop
  [application/x-alz]=engrampa.desktop
  [application/x-arc]=engrampa.desktop
  [application/x-arj]=engrampa.desktop
  [application/x-brotli]=engrampa.desktop
  [application/x-brotli-compressed-tar]=engrampa.desktop
  [application/x-bzip]=engrampa.desktop
  [application/x-bzip2]=engrampa.desktop
  [application/bzip2]=engrampa.desktop
  [application/x-bzip-compressed-tar]=engrampa.desktop
  [application/x-bzip1]=engrampa.desktop
  [application/x-bzip1-compressed-tar]=engrampa.desktop
  [application/x-cabinet]=engrampa.desktop
  [application/x-cbr]=engrampa.desktop
  [application/x-cbz]=engrampa.desktop
  [application/x-cd-image]=engrampa.desktop
  [application/x-compress]=engrampa.desktop
  [application/x-compressed-tar]=engrampa.desktop
  [application/x-cpio]=engrampa.desktop
  [application/vnd.debian.binary-package]=engrampa.desktop
  [application/x-ear]=engrampa.desktop
  [application/x-ms-dos-executable]=engrampa.desktop
  [application/x-gtar]=engrampa.desktop
  [application/x-gzip]=engrampa.desktop
  [application/gzip]=engrampa.desktop
  [application/x-gzpostscript]=engrampa.desktop
  [application/x-java-archive]=engrampa.desktop
  [application/java-archive]=engrampa.desktop
  [application/jar]=engrampa.desktop
  [application/jar-archive]=engrampa.desktop
  [application/x-lha]=engrampa.desktop
  [application/x-lzh-compressed]=engrampa.desktop
  [application/x-lrzip]=engrampa.desktop
  [application/x-lrzip-compressed-tar]=engrampa.desktop
  [application/x-lzip]=engrampa.desktop
  [application/x-lzip-compressed-tar]=engrampa.desktop
  [application/x-lzma]=engrampa.desktop
  [application/x-lzma-compressed-tar]=engrampa.desktop
  [application/x-lzop]=engrampa.desktop
  [application/x-lzop-compressed-tar]=engrampa.desktop
  [application/x-ms-wim]=engrampa.desktop
  [application/x-rar]=engrampa.desktop
  [application/x-rar-compressed]=engrampa.desktop
  [application/x-rpm]=engrampa.desktop
  [application/x-source-rpm]=engrampa.desktop
  [application/x-rzip]=engrampa.desktop
  [application/x-tar]=engrampa.desktop
  [application/x-tarz]=engrampa.desktop
  [application/x-stuffit]=engrampa.desktop
  [application/x-war]=engrampa.desktop
  [application/x-xz]=engrampa.desktop
  [application/x-xz-compressed-tar]=engrampa.desktop
  [application/x-zip]=engrampa.desktop
  [application/x-zip-compressed]=engrampa.desktop
  [application/x-zoo]=engrampa.desktop
  [application/zstd]=engrampa.desktop
  [application/x-zstd]=engrampa.desktop
  [application/x-zstd-compressed-tar]=engrampa.desktop
  [application/zip]=engrampa.desktop
  [application/x-archive]=engrampa.desktop
  [application/vnd.ms-cab-compressed]=engrampa.desktop

  # Text / Code
  [text/plain]=nvim.desktop
  [text/markdown]=nvim.desktop
  [text/x-shellscript]=nvim.desktop
  [application/json]=nvim.desktop
  [application/x-yaml]=nvim.desktop

  # Torrents / Magnet
  [application/x-bittorrent]=org.qbittorrent.qBittorrent.desktop
  [x-scheme-handler/magnet]=org.qbittorrent.qBittorrent.desktop
)

for mime in "${!mime_apps[@]}"; do
  xdg-mime default "${mime_apps[$mime]}" "$mime"
done
