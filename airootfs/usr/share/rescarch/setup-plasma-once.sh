#!/bin/bash
# Run Plasma desktop setup once on first login

set -e

MARKER_FILE="$HOME/.config/rescarch-plasma-configured"

if [ ! -f "$MARKER_FILE" ]; then
    # Apply the desktop configuration
    qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$(cat /usr/share/rescarch/setup-desktop.js)"
    
    # Create marker file to prevent running again
    mkdir -p "$HOME/.config"
    touch "$MARKER_FILE"
fi
