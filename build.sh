#!/usr/bin/env bash

shopt -s globstar
set -euo pipefail

cd "$(dirname "$0")"

# Parse arguments
DEBUG=false
MKARCHISO_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      MKARCHISO_ARGS+=("$1")
      shift
      ;;
  esac
done

mkdir -p out/packages

prepare(){
    echo "==> Fixing permissions"
    chown -R "$SUDO_USER":"$SUDO_USER" out/
    
    # Remove artifacts
    echo "==> Cleaning up artifacts"
    for artifact in "${artifacts[@]}"; do
        echo "  - Removing $artifact"
        rm -f "$artifact"
    done
}

trap prepare EXIT SIGINT SIGTERM
prepare

artifacts=()

declare -A boot_vars=(
  ["RA_BOOT_SPLASH"]="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0"
  ["RA_BOOT_CMDLINE"]="archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_label=RA_DATA cow_nofail=y"
)
declare -A pacman_vars=(
  ["RA_REPOSITORY"]="file://$(realpath out/packages)"
)

# Substitute boot variables in files ending with .ra_boot
echo "==> Processing boot files"
for boot_file in **/*.ra_boot; do
  target_file="${boot_file%.ra_boot}"
  cp "$boot_file" "$target_file"
  echo "  - Processing $target_file"
  # Add it to artifacts
  artifacts+=("$target_file")
  # Substitute variables
  for var in "${!boot_vars[@]}"; do
    sed -i "s|%$var%|${boot_vars[$var]}|g" "$target_file"
  done
done

# Substitute pacman variables in files ending with .ra_pacman
echo "==> Processing pacman files"
for pacman_file in **/*.ra_pacman; do
  target_file="${pacman_file%.ra_pacman}"
  cp "$pacman_file" "$target_file"
  echo "  - Processing $target_file"
  # Add it to artifacts
  artifacts+=("$target_file")
  # Substitute variables
  for var in "${!pacman_vars[@]}"; do
    sed -i "s|%$var%|${pacman_vars[$var]}|g" "$target_file"
  done
done

# Build packages
for pkgbuild in src/*/PKGBUILD; do
  pkgdir=$(dirname "$pkgbuild")
  echo "Building package in $pkgdir"
  # run as non root to avoid permission issues
  sudo -u "$SUDO_USER" bash -c "cd '$pkgdir' && makepkg --noconfirm --syncdeps --cleanbuild --force && mv ./*.pkg.tar.zst ../../out/packages/"
done

# Create repo database
repo-add out/packages/rescarch.db.tar.zst out/packages/*.pkg.tar.zst
if [ "$DEBUG" = true ]; then
  export RA_DEBUG=true
fi

MKARCHISO_DEFAULT_ARGS=(
  -r
  -w /tmp/archiso-tmp-$$
  -o out/
)

if [ "$DEBUG" = true ]; then
  MKARCHISO_DEFAULT_ARGS+=(-v)
fi

echo "==> Building archiso"
if [[ ${#MKARCHISO_ARGS[@]} -gt 0 ]]; then
  mkarchiso "${MKARCHISO_DEFAULT_ARGS[@]}" "${MKARCHISO_ARGS[@]}" .
else
  mkarchiso "${MKARCHISO_DEFAULT_ARGS[@]}" .
fi
