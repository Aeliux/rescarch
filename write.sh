#!/bin/bash

# ISO Burning Script with Persistent Storage Option
# This script burns an ISO to a device and optionally creates a persistent partition

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

# Function to verify RescArch ISO
verify_rescarch_iso() {
    local iso_path="$1"
    local temp_mount=$(mktemp -d)
    local is_rescarch=false
    
    echo "Verifying ISO file..."
    
    # Try to mount ISO and check for RescArch-specific markers
    if mount -o loop,ro "$iso_path" "$temp_mount" 2>/dev/null; then
        # Check for multiple RescArch indicators
        local indicators=0
        
        # Check 1: Look for rescarch directory
        if [[ -d "$temp_mount/rescarch" ]] || [[ -d "$temp_mount/usr/share/rescarch" ]]; then
            indicators=$((indicators + 1))
        fi
        
        # Check 2: Look for rescarch in boot entries
        if ls "$temp_mount/loader/entries/"*.conf &>/dev/null && \
           grep -qi "rescarch" "$temp_mount/loader/entries/"*.conf 2>/dev/null; then
            indicators=$((indicators + 1))
        elif [[ -f "$temp_mount/boot/grub/grub.cfg" ]] && \
             grep -qi "rescarch" "$temp_mount/boot/grub/grub.cfg" 2>/dev/null; then
            indicators=$((indicators + 1))
        fi
        
        # Check 3: Look for rescarch in syslinux config
        if [[ -f "$temp_mount/syslinux/syslinux.cfg" ]] && \
           grep -qi "rescarch" "$temp_mount/syslinux/syslinux.cfg" 2>/dev/null; then
            indicators=$((indicators + 1))
        fi
        
        umount "$temp_mount" 2>/dev/null || true
        
        if [[ $indicators -ge 1 ]]; then
            is_rescarch=true
            print_success "ISO appears to be a RescArch ISO"
        fi
    else
        print_error "Failed to mount ISO file for verification"
        exit 1
    fi
    
    rmdir "$temp_mount" 2>/dev/null || true
    
    if [[ "$is_rescarch" == false ]]; then
        print_warning "Could not verify this is a RescArch ISO"
        read -p "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            exit 2
        fi
    fi
}

# Function to parse size string (e.g., "1G", "500M", "2T")
parse_size() {
    local size_str="$1"
    local size_bytes=0
    
    # Extract number and unit
    if [[ "$size_str" =~ ^([0-9]+)([KMGT]?)$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            K) size_bytes=$((number * 1024)) ;;
            M) size_bytes=$((number * 1024 * 1024)) ;;
            G) size_bytes=$((number * 1024 * 1024 * 1024)) ;;
            T) size_bytes=$((number * 1024 * 1024 * 1024 * 1024)) ;;
            "") size_bytes=$number ;;
            *) 
                print_error "Invalid size unit: $unit"
                return 1
                ;;
        esac
        
        echo "$size_bytes"
        return 0
    else
        print_error "Invalid size format: $size_str (use format like 1G, 500M, 2T)"
        return 1
    fi
}

# Function to get ISO volume label
get_iso_label() {
    local iso_path="$1"
    local label=""
    
    # Try isoinfo first (if available)
    if command -v isoinfo &> /dev/null; then
        label=$(isoinfo -d -i "$iso_path" 2>/dev/null | grep "Volume id:" | sed 's/Volume id: //' | tr -d ' ')
    fi
    
    # Fallback to blkid
    if [[ -z "$label" ]] && command -v blkid &> /dev/null; then
        label=$(blkid -s LABEL -o value "$iso_path" 2>/dev/null | tr -d ' ')
    fi
    
    # Default label if nothing found
    if [[ -z "$label" ]]; then
        label="RESCARCH"
    fi
    
    echo "$label"
}

# Function to show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Burns an RescArch ISO image to a block device.

OPTIONS:
    -i, --iso PATH          Path to RescArch ISO file (required)
    -d, --device DEVICE     Target device path, e.g., /dev/sdb (required)
    -p, --persistent [SIZE] Create persistent storage partition
                            SIZE is optional (e.g., 1G, 500M, 2T)
                            If omitted, uses all remaining space
    -o, --offline           Create offline package repository from rescarch package cache
                            (creates separate partition with signed packages)
    -y, --yes              Skip confirmation prompts (DANGEROUS - use with caution)
    -h, --help             Show this help message

EXAMPLES:
    # Burn ISO with interactive confirmation
    $(basename "$0") -i rescarch.iso -d /dev/sdb

    # Burn ISO with 2GB persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdb -p 2G

    # Burn ISO with persistent storage using all remaining space
    $(basename "$0") -i rescarch.iso -d /dev/sdb -p

    # Burn ISO with offline packages and persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdb -o -p 1G

    # Skip confirmations (use with extreme caution)
    $(basename "$0") -i rescarch.iso -d /dev/sdb -y

WARNING:
    This script will PERMANENTLY ERASE all data on the target device.
    Always double-check the device path before proceeding.
EOF
}

# Parse command line arguments
ISO_PATH=""
TARGET_DEVICE=""
CREATE_PERSISTENT=false
PERSISTENT_SIZE=""
CREATE_OFFLINE=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--iso)
            ISO_PATH="$2"
            shift 2
            ;;
        -d|--device)
            TARGET_DEVICE="$2"
            shift 2
            ;;
        -p|--persistent)
            CREATE_PERSISTENT=true
            # Check if next argument is a size specification
            if [[ -n "$2" ]] && [[ "$2" =~ ^[0-9]+[KMGT]?$ ]] && [[ "$2" != -* ]]; then
                PERSISTENT_SIZE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -o|--offline)
            CREATE_OFFLINE=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=(lsblk dd sgdisk mkfs.ext4 partprobe mount umount)
if [[ "$CREATE_OFFLINE" == true ]]; then
    REQUIRED_TOOLS+=(repo-add tar gpg)
fi

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "Required tool '$tool' is not installed"
        exit 1
    fi
done

# Validate required arguments
if [[ -z "$ISO_PATH" ]]; then
    print_error "ISO file path is required. Use -i or --iso"
    echo "Use -h or --help for usage information"
    exit 1
fi

if [[ -z "$TARGET_DEVICE" ]]; then
    print_error "Target device is required. Use -d or --device"
    echo "Use -h or --help for usage information"
    exit 1
fi

# Validate ISO file exists
if [[ ! -f "$ISO_PATH" ]]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
fi

# Validate ISO file is readable
if [[ ! -r "$ISO_PATH" ]]; then
    print_error "ISO file is not readable: $ISO_PATH"
    exit 1
fi

# Check ISO file size (should be > 1MB)
ISO_FILE_SIZE=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo "0")
if [[ "$ISO_FILE_SIZE" -lt 1048576 ]]; then
    print_error "ISO file seems too small (< 1MB). Is this a valid ISO?"
    exit 1
fi

# Verify this is a RescArch ISO
if [[ "$SKIP_CONFIRM" == false ]]; then
    verify_rescarch_iso "$ISO_PATH"
fi

# Normalize device path (remove trailing slashes and partition numbers if accidentally included)
TARGET_DEVICE=$(echo "$TARGET_DEVICE" | sed 's:/*$::')

# Validate target device path format
if [[ ! "$TARGET_DEVICE" =~ ^/dev/[a-z]+ ]]; then
    print_error "Invalid device path format: $TARGET_DEVICE"
    print_error "Expected format: /dev/sdX or /dev/nvmeXnY"
    exit 1
fi

# Ensure device path doesn't include partition number
if [[ "$TARGET_DEVICE" =~ [0-9]$ ]] && [[ ! "$TARGET_DEVICE" =~ nvme[0-9]+n[0-9]+$ ]]; then
    print_error "Device path should not include partition number: $TARGET_DEVICE"
    print_error "Use the disk device (e.g., /dev/sdb, not /dev/sdb1)"
    exit 1
fi

# Validate target device exists
if [[ ! -b "$TARGET_DEVICE" ]]; then
    print_error "Invalid block device: $TARGET_DEVICE"
    print_error "Device does not exist or is not a block device"
    exit 1
fi

# CRITICAL: Prevent writing to system disks
DEVICE_NAME=$(basename "$TARGET_DEVICE")

# Check if device is mounted as root or contains root filesystem
ROOT_DEVICE=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || echo "")
if [[ "$DEVICE_NAME" == "$ROOT_DEVICE" ]] || [[ "$TARGET_DEVICE" == "/dev/$ROOT_DEVICE" ]]; then
    print_error "BLOCKED: Target device contains the root filesystem!"
    print_error "Refusing to write to system disk: $TARGET_DEVICE"
    exit 1
fi

# Check for any mounted partitions on target device
MOUNTED_PARTS=$(lsblk -ln -o NAME,MOUNTPOINT "$TARGET_DEVICE" 2>/dev/null | awk '$2 != "" {print $1, $2}')
if [[ -n "$MOUNTED_PARTS" ]]; then
    print_warning "Device has mounted partitions:"
    echo "$MOUNTED_PARTS"
    
    # Check if any mount points are critical system directories
    if echo "$MOUNTED_PARTS" | grep -qE '\s+(/|/boot|/home|/usr|/var|/etc|/opt)$'; then
        print_error "BLOCKED: Device contains mounted system directories!"
        print_error "Refusing to write to device with system mounts"
        exit 1
    fi
fi

# Get ISO label and size
ISO_LABEL=$(get_iso_label "$ISO_PATH")
ISO_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$ISO_FILE_SIZE" 2>/dev/null || echo "$ISO_FILE_SIZE bytes")

# Prepare offline packages if requested (do this BEFORE confirmation)
PKG_COUNT=0
PACKAGES_SIZE=0
PACKAGES_SIZE_HUMAN=""
TEMP_PACKAGES=""

if [[ "$CREATE_OFFLINE" == true ]]; then
    echo
    echo "Preparing offline package repository..."
    
    PACKAGES_DIR="out/packages"
    if [[ ! -d "$PACKAGES_DIR" ]]; then
        print_error "Packages directory not found: $PACKAGES_DIR"
        exit 1
    fi
    
    # Create temporary directory for packages
    TEMP_PACKAGES=$(mktemp -d)
    trap "rm -rf '$TEMP_PACKAGES'" EXIT
    
    echo "Scanning for signed packages..."
    
    # Find all package files and keep only the latest version
    declare -A latest_packages
    
    # Parse package files and group by name
    for pkg_file in "$PACKAGES_DIR"/*.pkg.tar.{zst,xz,gz}; do
        [[ -f "$pkg_file" ]] || continue
        
        # Check if package has a signature
        if [[ ! -f "${pkg_file}.sig" ]]; then
            continue
        fi
        
        # Extract package name and version using pacman-style parsing
        filename=$(basename "$pkg_file")
        # Remove extension
        pkgname_ver="${filename%.pkg.tar.*}"
        
        # Extract package name (everything before last -version-release)
        if [[ "$pkgname_ver" =~ ^(.+)-([^-]+)-([^-]+)$ ]]; then
            pkgname="${BASH_REMATCH[1]}"
            pkgver="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            
            # Store or update latest version
            if [[ -z "${latest_packages[$pkgname]}" ]]; then
                latest_packages[$pkgname]="$pkg_file"
            else
                # Simple comparison - you might want to use vercmp for better accuracy
                latest_packages[$pkgname]="$pkg_file"
            fi
        fi
    done
    
    # Copy latest packages and their signatures
    for pkg_file in "${latest_packages[@]}"; do
        if [[ -f "$pkg_file" ]] && [[ -f "${pkg_file}.sig" ]]; then
            cp "$pkg_file" "$TEMP_PACKAGES/"
            cp "${pkg_file}.sig" "$TEMP_PACKAGES/"
            PKG_COUNT=$((PKG_COUNT + 1))
        fi
    done
    
    if [[ $PKG_COUNT -eq 0 ]]; then
        print_error "No signed packages found in $PACKAGES_DIR"
        rm -rf "$TEMP_PACKAGES"
        exit 1
    fi
    
    echo "Creating package database..."
    cd "$TEMP_PACKAGES"
    if ! repo-add rescarch.db.tar.gz *.pkg.tar.* 2>/dev/null; then
        print_error "Failed to create package database"
        cd - > /dev/null
        exit 1
    fi
    cd - > /dev/null
    
    # Calculate required size
    PACKAGES_SIZE=$(du -sb "$TEMP_PACKAGES" | awk '{print $1}')
    PACKAGES_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PACKAGES_SIZE")
    
    print_success "Prepared $PKG_COUNT signed packages ($PACKAGES_SIZE_HUMAN)"
fi

# Parse persistent size if specified
if [[ "$CREATE_PERSISTENT" == true ]] && [[ -n "$PERSISTENT_SIZE" ]]; then
    PERSISTENT_SIZE_BYTES=$(parse_size "$PERSISTENT_SIZE")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    PERSISTENT_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PERSISTENT_SIZE_BYTES")
fi

# Get device information
DEVICE_SIZE=$(lsblk -b -d -n -o SIZE "$TARGET_DEVICE" 2>/dev/null || echo "0")
DEVICE_MODEL=$(lsblk -d -n -o MODEL "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_TRAN=$(lsblk -d -n -o TRAN "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_TYPE=$(lsblk -d -n -o TYPE "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$DEVICE_SIZE" 2>/dev/null || echo "$DEVICE_SIZE bytes")

echo
echo "========================================"
echo ":: ISO Information"
echo "File: $ISO_PATH"
echo "Label: $ISO_LABEL"
echo "Size: $ISO_SIZE_HUMAN"
echo
echo ":: Target Device"
echo "Device: $TARGET_DEVICE"
echo "Size: $DEVICE_SIZE_HUMAN"
echo "Model: $DEVICE_MODEL"
echo "Transport: $DEVICE_TRAN"
echo "Type: $DEVICE_TYPE"
echo
echo ":: Configuration"
if [[ "$CREATE_OFFLINE" == true ]]; then
    echo "Offline packages: YES ($PKG_COUNT packages, $PACKAGES_SIZE_HUMAN)"
else
    echo "Offline packages: NO"
fi
if [[ "$CREATE_PERSISTENT" == true ]]; then
    if [[ -n "$PERSISTENT_SIZE" ]]; then
        echo "Persistent storage: YES ($PERSISTENT_SIZE_HUMAN)"
    else
        echo "Persistent storage: YES (all remaining space)"
    fi
else
    echo "Persistent storage: NO"
fi
echo "========================================"
echo

# Check if device is removable
IS_REMOVABLE=$(cat "/sys/block/$(basename "$TARGET_DEVICE")/removable" 2>/dev/null || echo "0")

if [[ "$IS_REMOVABLE" != "1" ]] && [[ "$DEVICE_TRAN" != "usb" ]]; then
    print_warning "This device does NOT appear to be a removable USB device!"
    print_warning "Transport type: $DEVICE_TRAN, Removable: $IS_REMOVABLE"
    
    echo
    read -p "Are you SURE you want to continue? (type 'YES' in capitals): " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Operation cancelled."
        exit 2
    fi
fi

# Safety confirmation
if [[ "$SKIP_CONFIRM" == false ]]; then
    print_warning "THIS WILL PERMANENTLY ERASE ALL DATA ON $TARGET_DEVICE!"
    read -p "Type 'YES' in capitals to proceed: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Operation cancelled."
        exit 2
    fi
else
    print_warning "Skipping confirmation due to -y flag"
    print_warning "Writing to $TARGET_DEVICE in 3 seconds... (Ctrl+C to abort)"
    sleep 3
fi

# Unmount any mounted partitions
echo
echo "Unmounting any mounted partitions on $TARGET_DEVICE..."
umount "${TARGET_DEVICE}"* 2>/dev/null || true
sync
sleep 1

# Write ISO to device
echo
echo "Writing ISO to $TARGET_DEVICE..."
if ! dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=4M status=progress oflag=sync; then
    print_error "Failed to write ISO to device"
    exit 1
fi
sync

# Create offline package repository if requested
if [[ "$CREATE_OFFLINE" == true ]]; then
    echo
    echo "Creating offline package partition..."
    
    # Calculate required size with buffer
    PACKAGES_SIZE_MB=$((PACKAGES_SIZE / 1024 / 1024 + 100))  # Add 100MB buffer
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Create partition for packages (partition 3)
    if ! sgdisk -n 0:0:+${PACKAGES_SIZE_MB}M -t 0:8300 "$TARGET_DEVICE"; then
        print_error "Failed to create packages partition"
        exit 1
    fi
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Determine partition name
    if [[ "$TARGET_DEVICE" =~ nvme || "$TARGET_DEVICE" =~ mmcblk ]]; then
        PACKAGES_PART="${TARGET_DEVICE}p3"
    else
        PACKAGES_PART="${TARGET_DEVICE}3"
    fi
    
    # Wait for partition to appear
    for i in {1..10}; do
        if [[ -b "$PACKAGES_PART" ]]; then
            break
        fi
        sleep 1
    done
    
    if [[ ! -b "$PACKAGES_PART" ]]; then
        print_error "Packages partition $PACKAGES_PART was not created"
        exit 1
    fi
    
    # Format partition as ext4 with fixed label
    echo "Formatting packages partition..."
    if ! mkfs.ext4 -L "RESCARCH_PACKAGES" "$PACKAGES_PART"; then
        print_error "Failed to format packages partition"
        exit 1
    fi
    
    # Mount and copy packages
    TEMP_MOUNT=$(mktemp -d)
    if ! mount "$PACKAGES_PART" "$TEMP_MOUNT"; then
        print_error "Failed to mount packages partition"
        rmdir "$TEMP_MOUNT"
        exit 1
    fi
    
    echo "Copying packages to partition..."
    if ! cp -r "$TEMP_PACKAGES"/* "$TEMP_MOUNT/"; then
        print_error "Failed to copy packages"
        umount "$TEMP_MOUNT"
        rmdir "$TEMP_MOUNT"
        exit 1
    fi
    
    sync
    umount "$TEMP_MOUNT"
    rmdir "$TEMP_MOUNT"
    
    print_success "Offline package repository created: $PACKAGES_PART"
fi

# Create persistent storage partition if requested
if [[ "$CREATE_PERSISTENT" == true ]]; then
    echo
    echo "Creating persistent storage partition..."
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Determine partition number (3 or 4 depending on offline packages)
    if [[ "$CREATE_OFFLINE" == true ]]; then
        PERSIST_NUM=4
    else
        PERSIST_NUM=3
    fi
    
    # Create partition with specified size or use all remaining space
    if [[ -n "$PERSISTENT_SIZE" ]]; then
        SIZE_MB=$((PERSISTENT_SIZE_BYTES / 1024 / 1024))
        echo "Creating persistent partition ($PERSISTENT_SIZE_HUMAN)..."
        if ! sgdisk -n 0:0:+${SIZE_MB}M -t 0:8300 "$TARGET_DEVICE"; then
            print_error "Failed to create persistent partition"
            exit 1
        fi
    else
        # Use all remaining space
        echo "Creating persistent partition with all remaining space..."
        if ! sgdisk -n 0:0:0 -t 0:8300 "$TARGET_DEVICE"; then
            print_error "Failed to create persistent partition"
            exit 1
        fi
    fi
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Determine partition name
    if [[ "$TARGET_DEVICE" =~ nvme || "$TARGET_DEVICE" =~ mmcblk ]]; then
        PERSIST_PART="${TARGET_DEVICE}p${PERSIST_NUM}"
    else
        PERSIST_PART="${TARGET_DEVICE}${PERSIST_NUM}"
    fi
    
    # Wait for partition to appear
    for i in {1..10}; do
        if [[ -b "$PERSIST_PART" ]]; then
            break
        fi
        sleep 1
    done
    
    if [[ ! -b "$PERSIST_PART" ]]; then
        print_error "Persistent partition $PERSIST_PART was not created"
        exit 1
    fi
    
    # Format partition as ext4
    echo "Formatting persistent partition as ext4..."
    if ! mkfs.ext4 -L "RESCARCH_DATA" "$PERSIST_PART"; then
        print_error "Failed to format persistent partition"
        exit 1
    fi
    
    print_success "Persistent storage partition created: $PERSIST_PART"
fi

sync
print_success "ISO successfully written to $TARGET_DEVICE"
