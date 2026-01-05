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

# Function to show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Burns an RescArch ISO image to a block device.

OPTIONS:
    -i, --iso PATH          Path to RescArch ISO file (required)
    -d, --device DEVICE     Target device path, e.g., /dev/sdb (required)
    -p, --persistent        Create persistent storage partition
    -y, --yes              Skip confirmation prompts (DANGEROUS - use with caution)
    -h, --help             Show this help message

EXAMPLES:
    # Burn ISO with interactive confirmation
    $(basename "$0") -i rescarch.iso -d /dev/sdb

    # Burn ISO with persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdb -p

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
for tool in lsblk dd sgdisk mkfs.ext4 partprobe; do
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

# Get device information
DEVICE_SIZE=$(lsblk -b -d -n -o SIZE "$TARGET_DEVICE" 2>/dev/null || echo "0")
DEVICE_MODEL=$(lsblk -d -n -o MODEL "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_TRAN=$(lsblk -d -n -o TRAN "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_TYPE=$(lsblk -d -n -o TYPE "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")

echo
echo ":: Target Device Information"
echo "Device: $TARGET_DEVICE"
echo "Size: $(numfmt --to=iec-i --suffix=B "$DEVICE_SIZE" 2>/dev/null || echo "$DEVICE_SIZE bytes")"
echo "Model: $DEVICE_MODEL"
echo "Transport: $DEVICE_TRAN"
echo "Type: $DEVICE_TYPE"
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
    echo
    print_warning "THIS WILL COMPLETELY ERASE ALL DATA ON $TARGET_DEVICE"
    echo "ISO file: $ISO_PATH"
    echo "Target device: $TARGET_DEVICE ($DEVICE_MODEL)"
    echo "Persistent storage: $([ "$CREATE_PERSISTENT" == true ] && echo "YES" || echo "NO")"
    echo
    echo "Do you understand that:"
    echo "  1. All data on $TARGET_DEVICE will be permanently destroyed"
    echo "  2. This operation cannot be undone"
    echo "  3. You have backed up any important data"
    echo
    read -p "Type 'YES' to proceed: " UNDERSTAND
    if [[ "$UNDERSTAND" != "YES" ]]; then
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

if [[ "$CREATE_PERSISTENT" == true ]]; then
    echo
    echo "Creating persistent storage partition..."
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Create new partition after ISO
    if ! sgdisk -n 0:0:0 -t 0:8300 "$TARGET_DEVICE"; then
        print_error "Failed to create persistent partition"
        exit 1
    fi
    
    # Refresh partition table
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Determine partition name
    if [[ "$TARGET_DEVICE" =~ nvme || "$TARGET_DEVICE" =~ mmcblk ]]; then
        PERSIST_PART="${TARGET_DEVICE}p3"
    else
        PERSIST_PART="${TARGET_DEVICE}3"
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
