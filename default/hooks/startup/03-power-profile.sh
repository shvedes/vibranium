#!/bin/bash

# In case if power profile was changed outside of Vibranium.
vb-core-power --quiet "$(powerprofilesctl get)"
