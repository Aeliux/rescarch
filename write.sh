#!/bin/bash

# ISO Burning Script with Persistent Storage Option
# This script burns an ISO to a device and optionally creates a persistent partition

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

# Function to verify RescArch ISO
verify_rescarch_iso() {
    local iso_path="$1"
    local temp_mount=$(mktemp -d)
    register_dir "$temp_mount"
    local is_rescarch=false
    
    # Try to mount ISO and check for RescArch-specific markers
    if mount -o loop,ro "$iso_path" "$temp_mount" 2>/dev/null; then
        register_mount "$temp_mount"
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
        
        cleanup_mount "$temp_mount"
        unregister_mount "$temp_mount"
        
        if [[ $indicators -ge 1 ]]; then
            is_rescarch=true
        fi
    else
        print_error "Failed to mount ISO file for verification"
        exit 1
    fi
    
    rmdir "$temp_mount" 2>/dev/null || true
    unregister_dir "$temp_mount"
    
    if [[ "$is_rescarch" == false ]]; then
        print_warning "Could not verify this is a RescArch ISO"
        read -p "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            exit 2
        fi
    fi
}



# Function to show help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Burns an RescArch ISO image to a block device.

OPTIONS:
    -i, --iso PATH          Path to RescArch ISO file (required)
    -d, --device DEVICE     Target block device (required, must be whole disk)
    -p, --persistent [SIZE] Create persistent storage partition
                            SIZE is optional (e.g., 1G, 500M, 2T)
                            If omitted, uses all remaining space
    -o, --offline PATH      Add offline package repository from EROFS image
                            PATH is the image file created by gen-offline-repo.sh
    -y, --yes              Skip confirmation prompts (DANGEROUS - use with caution)
    -h, --help             Show this help message

EXAMPLES:
    # Burn ISO with interactive confirmation
    $(basename "$0") -i rescarch.iso -d /dev/sdX

    # Burn ISO with 2GB persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdX -p 2G

    # Burn ISO with persistent storage using all remaining space
    $(basename "$0") -i rescarch.iso -d /dev/sdX -p

    # Create offline repository first, then write
    sudo ./gen-offline-repo.sh -p base,linux,linux-firmware -o offline.erofs
    $(basename "$0") -i rescarch.iso -d /dev/sdX -o offline.erofs -p 1G

    # Skip confirmations (use with extreme caution)
    $(basename "$0") -i rescarch.iso -d /dev/sdX -y

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
OFFLINE_EROFS_PATH=""
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
            # EROFS image path is required
            if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                OFFLINE_EROFS_PATH="$2"
                shift 2
            else
                print_error "EROFS image path is required with -o option"
                exit 1
            fi
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

# Calculate total steps for progress tracking
TOTAL_STEPS=3  # Validation, Wipe, Write ISO (includes sync)
if [[ "$CREATE_OFFLINE" == true ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))  # Create offline partition
fi
if [[ "$CREATE_PERSISTENT" == true ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))  # Create persistent partition
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: VALIDATION AND CHECKS
# ═══════════════════════════════════════════════════════════════════════════

print_step "Validation and system checks"
TOTAL_SUBSTEPS=4
if [[ "$CREATE_OFFLINE" == true ]]; then
    TOTAL_SUBSTEPS=5
fi

# Check if running as root
print_substep "Checking system requirements"
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=(lsblk dd mkfs.ext4 partprobe mount umount parted sfdisk blkid blockdev bc)

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "Required tool '$tool' is not installed"
        exit 1
    fi
done

# Validate required arguments and ISO file
print_substep "Validating ISO file"
if [[ -z "$ISO_PATH" ]]; then
    print_error "ISO file path is required. Use -i or --iso"
    echo "Use -h or --help for usage information"
    exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
fi

if [[ ! -r "$ISO_PATH" ]]; then
    print_error "ISO file is not readable: $ISO_PATH"
    exit 1
fi

ISO_FILE_SIZE=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo "0")
if [[ "$ISO_FILE_SIZE" -lt 1048576 ]]; then
    print_error "ISO file seems too small (< 1MB). Is this a valid ISO?"
    exit 1
fi
ISO_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$ISO_FILE_SIZE" 2>/dev/null || echo "$ISO_FILE_SIZE bytes")
print_info "ISO size: $ISO_SIZE_HUMAN"

verify_rescarch_iso "$ISO_PATH"

# Validate EROFS file if offline packages requested
if [[ "$CREATE_OFFLINE" == true ]]; then
    print_substep "Validating Offline Repository image"
    
    if [[ ! -f "$OFFLINE_EROFS_PATH" ]]; then
        print_error "File not found: $OFFLINE_EROFS_PATH"
        exit 1
    fi
    
    if [[ ! -r "$OFFLINE_EROFS_PATH" ]]; then
        print_error "File is not readable: $OFFLINE_EROFS_PATH"
        exit 1
    fi
    
    EROFS_FILE_SIZE=$(stat -c%s "$OFFLINE_EROFS_PATH" 2>/dev/null || echo "0")
    if [[ "$EROFS_FILE_SIZE" -lt 1024 ]]; then
        print_error "Image file seems too small (< 1KB). Is this a valid Offline Repository image?"
        exit 1
    fi
    EROFS_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$EROFS_FILE_SIZE" 2>/dev/null || echo "$EROFS_FILE_SIZE bytes")
    print_info "Image size: $EROFS_SIZE_HUMAN"
fi

# Validate target device
print_substep "Validating target device"
if [[ -z "$TARGET_DEVICE" ]]; then
    print_error "Target device is required. Use -d or --device"
    echo "Use -h or --help for usage information"
    exit 1
fi

# Normalize device path (remove trailing slashes)
TARGET_DEVICE=$(echo "$TARGET_DEVICE" | sed 's:/*$::')

# Check if path exists and is a block device
if [[ ! -e "$TARGET_DEVICE" ]]; then
    print_error "Device does not exist: $TARGET_DEVICE"
    exit 1
fi

if [[ ! -b "$TARGET_DEVICE" ]]; then
    print_error "Invalid block device: $TARGET_DEVICE"
    print_error "Device is not a block device"
    exit 1
fi

# Check if device is a partition by checking its TYPE (should be disk or loop, not part)
DEVICE_TYPE=$(lsblk -no TYPE "$TARGET_DEVICE" 2>/dev/null | head -1)
if [[ "$DEVICE_TYPE" == "part" ]]; then
    DEVICE_PARENT=$(lsblk -no PKNAME "$TARGET_DEVICE" 2>/dev/null | head -1)
    print_error "Target appears to be a partition, not a disk: $TARGET_DEVICE"
    print_error "Parent device: /dev/$DEVICE_PARENT"
    print_error "Please use the whole disk device instead"
    exit 1
fi

DEVICE_NAME=$(basename "$TARGET_DEVICE")
ROOT_DEVICE=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || echo "")
if [[ "$DEVICE_NAME" == "$ROOT_DEVICE" ]] || [[ "$TARGET_DEVICE" == "/dev/$ROOT_DEVICE" ]]; then
    print_error "BLOCKED: Target device contains the root filesystem!"
    print_error "Refusing to write to system disk: $TARGET_DEVICE"
    exit 1
fi

MOUNTED_PARTS=$(lsblk -ln -o NAME,MOUNTPOINT "$TARGET_DEVICE" 2>/dev/null | awk '$2 != "" {print $1, $2}')
if [[ -n "$MOUNTED_PARTS" ]]; then
    print_warning "Device has mounted partitions:"
    echo "$MOUNTED_PARTS"
    
    if echo "$MOUNTED_PARTS" | grep -qE '\s+(/|/boot|/home|/usr|/var|/etc|/opt)$'; then
        print_error "BLOCKED: Device contains mounted system directories!"
        print_error "Refusing to write to device with system mounts"
        exit 1
    fi
fi

# Gather information
print_substep "Gathering device information"
ISO_LABEL=$(get_iso_label "$ISO_PATH")

# Gather comprehensive device information
DEVICE_NAME=$(basename "$TARGET_DEVICE")
DEVICE_SIZE=$(lsblk -b -d -n -o SIZE "$TARGET_DEVICE" 2>/dev/null || echo "0")
DEVICE_MODEL=$(lsblk -d -n -o MODEL "$TARGET_DEVICE" 2>/dev/null | tr -s ' ' || echo "")
DEVICE_VENDOR=$(lsblk -d -n -o VENDOR "$TARGET_DEVICE" 2>/dev/null | tr -s ' ' || echo "")
DEVICE_TRAN=$(lsblk -d -n -o TRAN "$TARGET_DEVICE" 2>/dev/null || echo "")
DEVICE_TYPE=$(lsblk -d -n -o TYPE "$TARGET_DEVICE" 2>/dev/null || echo "disk")
DEVICE_ROTA=$(lsblk -d -n -o ROTA "$TARGET_DEVICE" 2>/dev/null || echo "")
DEVICE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$DEVICE_SIZE" 2>/dev/null || echo "$DEVICE_SIZE bytes")
IS_REMOVABLE=$(cat "/sys/block/${DEVICE_NAME}/removable" 2>/dev/null || echo "0")

# Detect device category and gather specific info
DEVICE_CATEGORY=""
DEVICE_INFO_EXTRA=""

if [[ "$DEVICE_NAME" =~ ^loop[0-9]+ ]]; then
    DEVICE_CATEGORY="Loop Device"
    BACKING_FILE=$(losetup -n -O BACK-FILE "$TARGET_DEVICE" 2>/dev/null || echo "")
    [[ -n "$BACKING_FILE" ]] && DEVICE_INFO_EXTRA="Backing: $BACKING_FILE"
elif [[ "$DEVICE_NAME" =~ ^ram[0-9]+|^brd[0-9]+ ]]; then
    DEVICE_CATEGORY="RAM Block Device"
elif [[ "$DEVICE_NAME" =~ ^nvme[0-9]+n[0-9]+ ]]; then
    DEVICE_CATEGORY="NVMe SSD"
    NVME_MODEL=$(cat "/sys/block/${DEVICE_NAME}/device/model" 2>/dev/null | tr -s ' ' || echo "")
    [[ -n "$NVME_MODEL" ]] && DEVICE_INFO_EXTRA="Model: $NVME_MODEL"
elif [[ "$DEVICE_NAME" =~ ^mmcblk[0-9]+ ]]; then
    DEVICE_CATEGORY="MMC/SD Card"
    MMC_TYPE=$(cat "/sys/block/${DEVICE_NAME}/device/type" 2>/dev/null || echo "")
    MMC_NAME=$(cat "/sys/block/${DEVICE_NAME}/device/name" 2>/dev/null || echo "")
    [[ -n "$MMC_NAME" ]] && DEVICE_INFO_EXTRA="Name: $MMC_NAME"
    [[ -n "$MMC_TYPE" ]] && DEVICE_INFO_EXTRA="${DEVICE_INFO_EXTRA:+$DEVICE_INFO_EXTRA\n}Type: $MMC_TYPE"
elif [[ "$DEVICE_NAME" =~ ^sd[a-z]+ ]]; then
    if [[ "$DEVICE_ROTA" == "0" ]]; then
        DEVICE_CATEGORY="SATA/SAS SSD"
    else
        DEVICE_CATEGORY="SATA/SAS HDD"
    fi
    [[ "$IS_REMOVABLE" == "1" ]] && DEVICE_CATEGORY="USB/Removable Drive"
elif [[ "$DEVICE_NAME" =~ ^vd[a-z]+ ]]; then
    DEVICE_CATEGORY="Virtual Disk"
elif [[ "$DEVICE_NAME" =~ ^xvd[a-z]+ ]]; then
    DEVICE_CATEGORY="Xen Virtual Disk"
elif [[ "$DEVICE_NAME" =~ ^hd[a-z]+ ]]; then
    DEVICE_CATEGORY="IDE/PATA Drive"
elif [[ "$DEVICE_NAME" =~ ^sr[0-9]+ ]]; then
    DEVICE_CATEGORY="Optical Drive"
elif [[ "$DEVICE_NAME" =~ ^nbd[0-9]+ ]]; then
    DEVICE_CATEGORY="Network Block Device"
elif [[ "$DEVICE_NAME" =~ ^rbd[0-9]+ ]]; then
    DEVICE_CATEGORY="Ceph RBD"
else
    DEVICE_CATEGORY="Block Device"
fi

# Build device description
DEVICE_DESC="$DEVICE_CATEGORY"
[[ "$DEVICE_ROTA" == "0" ]] && [[ "$DEVICE_CATEGORY" =~ ^(Block Device|Virtual Disk) ]] && DEVICE_DESC="$DEVICE_DESC (SSD)"

print_info "Device: $TARGET_DEVICE ($DEVICE_SIZE_HUMAN) - $DEVICE_DESC"
[[ -n "$DEVICE_VENDOR$DEVICE_MODEL" ]] && print_info "Hardware: ${DEVICE_VENDOR:+$DEVICE_VENDOR }${DEVICE_MODEL}"
[[ -n "$DEVICE_TRAN" ]] && [[ "$DEVICE_TRAN" != "Unknown" ]] && print_info "Transport: $DEVICE_TRAN"

# Calculate required space and validate
REQUIRED_SIZE=$ISO_FILE_SIZE
if [[ "$CREATE_OFFLINE" == true ]]; then
    # Add EROFS size with 10MB overhead for partition
    REQUIRED_SIZE=$((REQUIRED_SIZE + EROFS_FILE_SIZE + 10 * 1024 * 1024))
fi
if [[ "$CREATE_PERSISTENT" == true ]] && [[ -n "$PERSISTENT_SIZE" ]]; then
    # Add persistent partition size if specified
    PERSISTENT_SIZE_BYTES=$(parse_size "$PERSISTENT_SIZE")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    PERSISTENT_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PERSISTENT_SIZE_BYTES")
    REQUIRED_SIZE=$((REQUIRED_SIZE + PERSISTENT_SIZE_BYTES))
fi

REQUIRED_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$REQUIRED_SIZE" 2>/dev/null || echo "$REQUIRED_SIZE bytes")

if [[ $REQUIRED_SIZE -gt $DEVICE_SIZE ]]; then
    print_error "Not enough space on device!"
    print_error "Required: $REQUIRED_SIZE_HUMAN"
    print_error "Available: $DEVICE_SIZE_HUMAN"
    print_error "Shortage: $(numfmt --to=iec-i --suffix=B $((REQUIRED_SIZE - DEVICE_SIZE)))"
    exit 1
fi

AVAILABLE_AFTER=$((DEVICE_SIZE - REQUIRED_SIZE))
# Calculate persistent partition size for display (if using all remaining space)
if [[ "$CREATE_PERSISTENT" == true ]] && [[ -z "$PERSISTENT_SIZE" ]]; then
    PERSISTENT_WILL_BE=$AVAILABLE_AFTER
    PERSISTENT_WILL_BE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PERSISTENT_WILL_BE" 2>/dev/null || echo "$PERSISTENT_WILL_BE bytes")
fi

print_success "All validation checks passed"

# ═══════════════════════════════════════════════════════════════════════════
# DISPLAY SUMMARY AND CONFIRMATIONS
# ═══════════════════════════════════════════════════════════════════════════

echo
echo "========================================"
echo ":: ISO Information"
echo "File: $ISO_PATH"
echo "Label: $ISO_LABEL"
echo "Size: $ISO_SIZE_HUMAN"
if [[ "$CREATE_OFFLINE" == true ]]; then
    echo
    echo ":: Offline Repository"
    echo "File: $OFFLINE_EROFS_PATH"
    echo "Size: $EROFS_SIZE_HUMAN"
fi
echo
echo ":: Target Device"
echo "Device: $TARGET_DEVICE"
echo "Type: $DEVICE_DESC"
if [[ -n "$DEVICE_VENDOR$DEVICE_MODEL" ]]; then
    echo "Hardware: ${DEVICE_VENDOR:+$DEVICE_VENDOR }${DEVICE_MODEL}"
fi
echo "Size: $DEVICE_SIZE_HUMAN"
if [[ -n "$DEVICE_TRAN" ]] && [[ "$DEVICE_TRAN" != "Unknown" ]]; then
    echo "Transport: $DEVICE_TRAN"
fi
if [[ -n "$DEVICE_INFO_EXTRA" ]]; then
    echo -e "$DEVICE_INFO_EXTRA"
fi
echo
echo ":: Configuration"
if [[ "$CREATE_OFFLINE" == true ]]; then
    echo "Offline packages: YES"
else
    echo "Offline packages: NO"
fi
if [[ "$CREATE_PERSISTENT" == true ]]; then
    if [[ -n "$PERSISTENT_SIZE" ]]; then
        echo "Persistent storage: YES ($PERSISTENT_SIZE_HUMAN)"
    else
        if [[ -n "$PERSISTENT_WILL_BE_HUMAN" ]]; then
            echo "Persistent storage: YES (~$PERSISTENT_WILL_BE_HUMAN)"
        else
            echo "Persistent storage: YES (all remaining space)"
        fi
    fi
else
    echo "Persistent storage: NO"
fi
echo "========================================"
echo

# Check if device is removable (skip check for virtual/loop/ram devices)
if [[ "$IS_REMOVABLE" != "1" ]] && [[ "$DEVICE_TRAN" != "usb" ]]; then
    # Skip warning for virtual and non-physical devices
    if [[ ! "$DEVICE_NAME" =~ ^(loop|ram|brd|nbd|rbd|vd|xvd)[0-9]+ ]]; then
        print_warning "This device does NOT appear to be a removable drive!"
        print_warning "Transport type: $DEVICE_TRAN, Removable: $IS_REMOVABLE"
        print_warning "This may be an internal drive - proceed with extreme caution!"
        
        echo
        read -p "Are you SURE you want to continue? (type 'YES' in capitals): " CONFIRM
        if [[ "$CONFIRM" != "YES" ]]; then
            echo "Operation cancelled."
            exit 2
        fi
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

# ═══════════════════════════════════════════════════════════════════════════
# MAIN OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════

# Unmount any mounted partitions
echo
umount "${TARGET_DEVICE}"* 2>/dev/null || true
sync
sleep 1

# Fast wipe target device
print_step "Wiping device $TARGET_DEVICE"
TOTAL_SUBSTEPS=3

print_substep "Unmounting all partitions"
print_info "Unmounting ${TARGET_DEVICE}*"
umount "${TARGET_DEVICE}"* 2>/dev/null || true
sync

print_substep "Removing partition table and signatures"
if ! wipefs -aq "$TARGET_DEVICE"; then
    print_warning "wipefs failed, using fallback method"
    dd if=/dev/zero of="$TARGET_DEVICE" bs=1M count=10 status=none 2>/dev/null || true
fi

print_substep "Refreshing partition table"
sync
blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
partprobe "$TARGET_DEVICE" 2>/dev/null || true
sleep 2
print_success "Device wiped successfully"

# Write ISO to device
print_step "Writing ISO to $TARGET_DEVICE"
TOTAL_SUBSTEPS=2

print_substep "Writing ISO image ($ISO_SIZE_HUMAN)"
ISO_LABEL=$(get_iso_label "$ISO_PATH")
if ! dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=4M status=progress oflag=sync; then
    print_error "Failed to write ISO to device"
    exit 1
fi

print_substep "Syncing filesystem"
sync
sleep 2
print_success "ISO written and synced successfully"

# Create offline package repository if requested
if [[ "$CREATE_OFFLINE" == true ]]; then
    print_step "Creating offline package partition"
    TOTAL_SUBSTEPS=4
    
    # Calculate EROFS image size and add 10MB overhead
    EROFS_SIZE=$(stat -c%s "$OFFLINE_EROFS_PATH" 2>/dev/null || echo "0")
    if [[ "$EROFS_SIZE" -eq 0 ]]; then
        print_error "Failed to determine image size"
        exit 1
    fi
    PACKAGES_SIZE_MB=$((EROFS_SIZE / 1024 / 1024 + 10))  # Add 10MB overhead
    EROFS_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$EROFS_SIZE")

    print_substep "Creating partition ($PACKAGES_SIZE_MB MB)"
    # Refresh partition table
    refresh_partitions "$TARGET_DEVICE"
    
    # Detect partition table type
    PART_TABLE_TYPE=$(get_partition_table_type "$TARGET_DEVICE")
    
    if [[ "$PART_TABLE_TYPE" == "unknown" ]]; then
        print_error "Could not determine partition table type"
        blkid -p "$TARGET_DEVICE" || true
        exit 1
    fi
    
    # Get current highest partition number to know what the new one will be
    CURRENT_LAST=$(get_last_partition_number "$TARGET_DEVICE" "$PART_TABLE_TYPE")
    NEW_PART_NUM=$((CURRENT_LAST + 1))
    
    # Create partition
    if ! create_partition "$TARGET_DEVICE" "$PACKAGES_SIZE_MB" "$PART_TABLE_TYPE"; then
        print_error "Failed to create packages partition"
        if [[ "$PART_TABLE_TYPE" == "dos" ]] || [[ "$PART_TABLE_TYPE" == "msdos" ]]; then
            parted -s "$TARGET_DEVICE" print || true
        else
            sgdisk -p "$TARGET_DEVICE" || true
        fi
        exit 1
    fi
    
    print_substep "Waiting for partition to appear"
    # Refresh partition table again
    refresh_partitions "$TARGET_DEVICE"
    
    # Get the new partition path using the number we calculated
    LAST_PART_NUM=$NEW_PART_NUM
    if [[ -z "$LAST_PART_NUM" ]]; then
        print_error "Could not determine partition number"
        exit 1
    fi
    
    PACKAGES_PART=$(get_partition_path "$TARGET_DEVICE" "$LAST_PART_NUM")
    
    # Wait for partition to appear
    if ! wait_for_partition "$PACKAGES_PART"; then
        exit 1
    fi
    
    print_substep "Writing EROFS image to $PACKAGES_PART"
    # Write EROFS image directly to partition
    if ! dd if="$OFFLINE_EROFS_PATH" of="$PACKAGES_PART" bs=1M status=progress oflag=sync; then
        print_error "Failed to write EROFS image to partition"
        exit 1
    fi
    
    print_substep "Syncing filesystem"
    sync
    
    print_success "Offline package repository created: $PACKAGES_PART (EROFS, $EROFS_SIZE_HUMAN)"
fi

# Create persistent storage partition if requested
if [[ "$CREATE_PERSISTENT" == true ]]; then
    print_step "Creating persistent storage partition"
    TOTAL_SUBSTEPS=4
    
    print_substep "Detecting partition table"
    # Refresh partition table
    refresh_partitions "$TARGET_DEVICE"
    
    # Detect partition table type
    PART_TABLE_TYPE=$(get_partition_table_type "$TARGET_DEVICE")
    
    if [[ "$PART_TABLE_TYPE" == "unknown" ]]; then
        print_error "Could not determine partition table type"
        blkid -p "$TARGET_DEVICE" || true
        exit 1
    fi
    
    # Get current highest partition number to know what the new one will be
    CURRENT_LAST=$(get_last_partition_number "$TARGET_DEVICE" "$PART_TABLE_TYPE")
    NEW_PART_NUM=$((CURRENT_LAST + 1))
    
    # Determine size (0 means use all remaining space)
    PERSIST_SIZE_MB=0
    if [[ -n "$PERSISTENT_SIZE" ]]; then
        PERSIST_SIZE_MB=$((PERSISTENT_SIZE_BYTES / 1024 / 1024))
        print_substep "Creating partition ($PERSISTENT_SIZE_HUMAN)"
    else
        print_substep "Creating partition (all remaining space)"
    fi
    
    # Create partition
    if ! create_partition "$TARGET_DEVICE" "$PERSIST_SIZE_MB" "$PART_TABLE_TYPE"; then
        print_error "Failed to create persistent partition"
        if [[ "$PART_TABLE_TYPE" == "dos" ]] || [[ "$PART_TABLE_TYPE" == "msdos" ]]; then
            parted -s "$TARGET_DEVICE" print || true
        else
            sgdisk -p "$TARGET_DEVICE" || true
        fi
        exit 1
    fi
    
    print_substep "Waiting for partition to appear"
    # Refresh partition table again
    refresh_partitions "$TARGET_DEVICE"
    
    # Get the new partition path using the number we calculated
    LAST_PART_NUM=$NEW_PART_NUM
    if [[ -z "$LAST_PART_NUM" ]]; then
        print_error "Could not determine partition number"
        exit 1
    fi
    
    PERSIST_PART=$(get_partition_path "$TARGET_DEVICE" "$LAST_PART_NUM")
    
    # Wait for partition to appear
    if ! wait_for_partition "$PERSIST_PART"; then
        exit 1
    fi
    
    print_substep "Formatting as ext4"
    print_info "Creating ext4 filesystem on $PERSIST_PART"
    # Format partition as ext4
    if ! mkfs.ext4 -q -F -L "RA_DATA" "$PERSIST_PART"; then
        print_error "Failed to format persistent partition"
        exit 1
    fi
    
    print_success "Persistent storage partition created: $PERSIST_PART"
fi

sync

echo
echo "Bootable drive created successfully"
