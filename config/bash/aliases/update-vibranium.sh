if [[ -n $VIBRANIUM_STATE && -f "$VIBRANIUM_STATE/update.available" ]]; then
  alias update-vibranium="vb-update"
fi
