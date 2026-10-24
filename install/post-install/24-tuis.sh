#!/bin/bash

helpers::log::info "Installing TUIs"

vb-tui-install \
	--exec btop \
	--name 'System Monitor' \
	--icon 'utilities-system-monitor' \
	--category 'System' \
	--keywords 'Resource;Network;Disk;GPU;Process'

vb-tui-install \
	--exec vb-util-yt-dlp \
	--name 'Video Downloader' \
	--category 'Utilities' \
	--icon 'video'

vb-tui-install \
	--exec vb-cmd-manpager \
	--name 'Man Page Viewer' \
	--category 'Utilities;System' \
	--icon 'bookworm'
