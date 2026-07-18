#!/bin/bash

# In case if power profile was changed outside of Vibranium.
# Also rebuild state file in case of a driver / kernel change.
vb-core-power --quiet --force "$(powerprofilesctl get)"
