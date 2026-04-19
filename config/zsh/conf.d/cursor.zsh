# Remove "/" from the list of characters considered part of a "word"
# WORDCHARS defines what zsh treats as a single unit for cursor movement
# (e.g. ALT+F / ALT+B) and some completion behaviors.
#
# By default "/" is INCLUDED, so paths like:
#   /home/user/Downloads
# are treated as one long word.
#
# This substitution removes "/" from WORDCHARS:
#   ${WORDCHARS//\//}  -> replace all "/" with nothing
#
# Result:
#   /home/user/Downloads is split into segments:
#   /home/ | user/ | Downloads
#
# So now:
#   ALT+F / ALT+B moves between path components instead of jumping the whole path
#   editing paths becomes much more precise (Fish-like behavior)
WORDCHARS=${WORDCHARS//\//}
