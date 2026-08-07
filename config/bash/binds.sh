# Use fish-like ^W word deletion.
# When used with paths, it deletes the closest word instead of the full path.

# Disable tty-level word-erase handling so Ctrl+W reaches readline instead
# of being consumed by the terminal driver first.
stty werase undef

# Rebind Ctrl+W in readline to stop at slashes, not just whitespace.
bind '"\C-w": unix-filename-rubout'
