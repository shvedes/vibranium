# Always check for $VIBRANIUM_STATE existence.
# Otherwise, when logged in via TTY (Ctrl+Alt+N), it will fail.
if [[ -n $VIBRANIUM_STATE && -f "$VIBRANIUM_STATE/update.available" ]]; then
  alias update-vibranium="vb-update"
fi
