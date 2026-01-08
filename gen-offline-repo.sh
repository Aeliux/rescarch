#!/bin/bash

# RescArch Offline Repository Generator
# This script creates an EROFS image containing packages for offline installation

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
if [[ -f "$SCRIPT_DIR/ra.sh" ]]; then
    source "$SCRIPT_DIR/ra.sh"
else
    echo "ERROR: Cannot find ra.sh in $SCRIPT_DIR" >&2
    exit 1
fi

# Set up traps
trap trap_exit EXIT
trap trap_int INT TERM
trap trap_err ERR

# Function to show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Creates an EROFS image containing packages for offline RescArch installation.

OPTIONS:
    -p, --packages LIST     Comma-separated package list (required)
                            Example: base,linux,bash
                            Includes all dependencies automatically
    -o, --output PATH       Output path for EROFS image (default: rescarch-offline.erofs)
    --pacman-cache PATH     Pacman cache directory (default: /var/cache/pacman/pkg)
    -h, --help             Show this help message

EXAMPLES:
    # Create offline repo with base system
    $(basename "$0") -p base,linux,linux-firmware -o offline.erofs

    # Create offline repo with full desktop environment
    $(basename "$0") -p base,linux,plasma,firefox,thunderbird

    # Use custom pacman cache
    $(basename "$0") -p base,linux --pacman-cache /mnt/cache -o offline.erofs

NOTES:
    - Requires root privileges
    - All package dependencies are automatically resolved and included
    - Package signatures are included for verification
    - The output EROFS image can be passed to write.sh with -o option

EOF
}

# Parse command line arguments
OFFLINE_PACKAGES=""
OUTPUT_PATH="rescarch-offline.erofs"
PACMAN_CACHE="/var/cache/pacman/pkg"

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--packages)
            OFFLINE_PACKAGES="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --pacman-cache)
            PACMAN_CACHE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Validation
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

if [[ -z "$OFFLINE_PACKAGES" ]]; then
    print_error "Package list is required. Use -p or --packages"
    echo "Example: -p base,linux,linux-firmware"
    echo "Use -h or --help for usage information"
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=(pacman pactree repo-add tar mkfs.erofs)
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "Required tool '$tool' is not installed"
        exit 1
    fi
done

# Verify pacman cache directory exists
if [[ ! -d "$PACMAN_CACHE" ]]; then
    print_error "Pacman cache directory not found: $PACMAN_CACHE"
    exit 1
fi

# Check if output file already exists
if [[ -f "$OUTPUT_PATH" ]]; then
    print_warning "Output file already exists: $OUTPUT_PATH"
    read -p "Overwrite? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 2
    fi
    rm -f "$OUTPUT_PATH"
fi

# Set total steps for progress tracking
TOTAL_STEPS=6

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: PREPARE TEMPORARY DIRECTORY
# ═══════════════════════════════════════════════════════════════════════════

print_step "Preparing temporary directory"
TOTAL_SUBSTEPS=1

print_substep "Creating temporary package directory"
TEMP_PACKAGES=$(mktemp -d)
register_dir "$TEMP_PACKAGES"
print_info "Working directory: $TEMP_PACKAGES"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: RESOLVE DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════

print_step "Resolving dependencies"
TOTAL_SUBSTEPS=3

print_substep "Updating package database"
if ! pacman -Sy --quiet; then
    print_error "Failed to update package database"
    exit 1
fi

print_substep "Analyzing package dependencies"
print_info "Base packages: $OFFLINE_PACKAGES"

# Convert comma-separated list to space-separated
PKG_LIST="${OFFLINE_PACKAGES//,/ }"

# Use pactree to get all packages including dependencies (from sync database)
# -s: use sync database, -l: linear output, -u: unique packages
declare -a all_packages
for pkg in $PKG_LIST; do
    print_info "Resolving dependencies for: $pkg"
    while IFS= read -r pkgname; do
        [[ -z "$pkgname" ]] && continue
        all_packages+=("$pkgname")
    done < <(pactree -slu "$pkg" 2>/dev/null)
done

if [[ ${#all_packages[@]} -eq 0 ]]; then
    print_error "Failed to resolve package dependencies"
    print_info "Check if packages exist: pacman -Ss $PKG_LIST"
    exit 1
fi

print_substep "Removing duplicate packages"
# Remove duplicates
declare -A seen
declare -a unique_packages
for pkg in "${all_packages[@]}"; do
    if [[ -z "${seen[$pkg]}" ]]; then
        seen[$pkg]=1
        unique_packages+=("$pkg")
    fi
done

print_success "Resolved ${#unique_packages[@]} packages (including dependencies)"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: DOWNLOAD PACKAGES
# ═══════════════════════════════════════════════════════════════════════════

print_step "Downloading packages"
TOTAL_SUBSTEPS=1

print_substep "Downloading ${#unique_packages[@]} packages to cache"
if ! pacman -Sw --noconfirm --quiet --cachedir "$PACMAN_CACHE" "${unique_packages[@]}"; then
    print_error "Failed to download packages"
    exit 1
fi
print_success "All packages downloaded successfully"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: COPY PACKAGES
# ═══════════════════════════════════════════════════════════════════════════

print_step "Copying packages from cache"
TOTAL_SUBSTEPS=2

print_substep "Getting package filenames"
NEEDED_FILES=$(pacman -Sp --print-format '%f' "${unique_packages[@]}" 2>&1)

if [[ $? -ne 0 ]]; then
    print_error "Failed to get package filenames"
    echo "$NEEDED_FILES"
    exit 1
fi

# Build array of unique filenames
declare -A seen_files
declare -a packages_to_copy
while IFS= read -r filename; do
    [[ -z "$filename" ]] && continue
    if [[ -z "${seen_files[$filename]}" ]]; then
        seen_files[$filename]=1
        packages_to_copy+=("$filename")
    fi
done <<< "$NEEDED_FILES"

print_substep "Copying ${#packages_to_copy[@]} package files and signatures"
print_info "Source: $PACMAN_CACHE"

PKG_COUNT=0
for filename in "${packages_to_copy[@]}"; do
    pkg_file="$PACMAN_CACHE/$filename"
    sig_file="${pkg_file}.sig"
    
    if [[ ! -f "$pkg_file" ]]; then
        print_error "Package not found: $pkg_file"
        exit 1
    fi
    
    if [[ ! -f "$sig_file" ]]; then
        print_error "Signature not found: $sig_file"
        print_info "Package signatures are required for offline repository"
        exit 1
    fi
    
    cp "$pkg_file" "$TEMP_PACKAGES/"
    cp "$sig_file" "$TEMP_PACKAGES/"
    PKG_COUNT=$((PKG_COUNT + 1))
done

if [[ $PKG_COUNT -eq 0 ]]; then
    print_error "No packages were copied"
    exit 1
fi

print_success "Copied $PKG_COUNT packages with signatures"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: CREATE PACKAGE DATABASE
# ═══════════════════════════════════════════════════════════════════════════

print_step "Creating package database"
TOTAL_SUBSTEPS=2

print_substep "Building repository database"
cd "$TEMP_PACKAGES"

# Use explicit extensions to exclude .sig files
if ! repo-add -q rescarch-offline.db.tar.gz *.pkg.tar.*[^.sig] 2>/dev/null; then
    print_error "Failed to create package database"
    cd - > /dev/null
    exit 1
fi
cd - > /dev/null

print_substep "Creating repository configuration file"
REPO_CONF_PATH="$TEMP_PACKAGES/repositories.conf"
cat > "$REPO_CONF_PATH" << 'EOF'
[rescarch-offline]
Server = file:///var/rescarch/packages
EOF

print_success "Package database created successfully"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: CREATE EROFS IMAGE
# ═══════════════════════════════════════════════════════════════════════════

print_step "Creating EROFS image"
TOTAL_SUBSTEPS=3

print_substep "Setting permissions on package files"
if ! chown -R root:root "$TEMP_PACKAGES"; then
    print_error "Failed to set ownership on package directory"
    exit 1
fi
if ! chmod -R 755 "$TEMP_PACKAGES"; then
    print_error "Failed to set permissions on package directory"
    exit 1
fi

print_substep "Building EROFS filesystem"
# Create EROFS image
# -L: set volume label
# --all-root: make all files owned by root
# -T0: set all timestamps to 0 for reproducibility
if ! mkfs.erofs --quiet -L "RA_PACKAGES" --all-root -T0 "$OUTPUT_PATH" "$TEMP_PACKAGES"; then
    print_error "Failed to create EROFS image"
    exit 1
fi

print_substep "Calculating image size"
EROFS_SIZE=$(stat -c%s "$OUTPUT_PATH" 2>/dev/null || echo "0")
if [[ "$EROFS_SIZE" -eq 0 ]]; then
    print_error "Failed to determine EROFS image size"
    exit 1
fi
EROFS_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$EROFS_SIZE")

# Calculate space needed on device (with overhead)
PACKAGES_SIZE_MB=$((EROFS_SIZE / 1024 / 1024 + 10))  # Add 10MB overhead

print_success "EROFS image created: $OUTPUT_PATH"
print_info "Image size: $EROFS_SIZE_HUMAN"
print_info "Required partition size: ~${PACKAGES_SIZE_MB}MB"

echo
echo "========================================"
echo ":: Offline Repository Created"
echo "Packages: $PKG_COUNT"
echo "Total size: $EROFS_SIZE_HUMAN"
echo "Output file: $OUTPUT_PATH"
echo
echo ":: Usage"
echo "Pass this image to write.sh:"
echo "  sudo ./write.sh -i rescarch.iso -d /dev/sdX -o $OUTPUT_PATH"
echo "========================================"
echo
