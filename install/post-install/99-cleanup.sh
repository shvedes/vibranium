#!/bin/bash

yay -Rnsc yay-debug --noconfirm || true
yay -Scc --noconfirm || true
yay -Ycc --noconfirm || true
