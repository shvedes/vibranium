#!/bin/bash

timestamp=$(date +%s)

mv ~/.config/rofi ~/.config/rofi.$timestamp
cp -r $VIBRANIUM/config/rofi ~/.config
