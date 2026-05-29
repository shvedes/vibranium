#!/usr/bin/bash

echo "You have a new utility: Video Downloader"
echo "You can find it in the app launcher"
vb-tui-install \
  --exec vb-util-yt-dlp \
  --name 'Video Downloader' \
  --category 'Utilities' \
  --float
