#!/bin/bash

# ISO Burning Script with Persistent Storage Option
# This script burns an ISO to a device and optionally creates a persistent partition

set -e

# Stage tracking
CURRENT_STEP=0
TOTAL_STEPS=0
CURRENT_SUBSTEP=0
TOTAL_SUBSTEPS=0

# Cleanup tracking
declare -a CLEANUP_FILES
declare -a CLEANUP_DIRS
declare -a CLEANUP_MOUNTS
CLEANUP_IN_PROGRESS=false

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

# Function to print step progress
print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    CURRENT_SUBSTEP=0
    TOTAL_SUBSTEPS=0
    echo
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;36m━━━ Step $CURRENT_STEP/$TOTAL_STEPS: $1\033[0m"
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# Function to print substep progress
print_substep() {
    CURRENT_SUBSTEP=$((CURRENT_SUBSTEP + 1))
    local tree_char="├─"
    if [[ $TOTAL_SUBSTEPS -gt 0 ]] && [[ $CURRENT_SUBSTEP -eq $TOTAL_SUBSTEPS ]]; then
        tree_char="└─"
    fi
    
    if [[ $TOTAL_SUBSTEPS -gt 0 ]]; then
        echo -e "\033[0;36m  $tree_char [$CURRENT_SUBSTEP/$TOTAL_SUBSTEPS] $1\033[0m"
    else
        echo -e "\033[0;36m  $tree_char $1\033[0m"
    fi
}

# Function to print info message
print_info() {
    local tree_char="├─>"
    if [[ $TOTAL_SUBSTEPS -gt 0 ]] && [[ $CURRENT_SUBSTEP -eq $TOTAL_SUBSTEPS ]]; then
        tree_char=" ─>"
    fi
    echo -e "\033[0;34m  $tree_char $1\033[0m"
}

# Cleanup functions
cleanup_mount() {
    local mount_point="$1"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || true
    fi
}

cleanup_all() {
    # Prevent recursive cleanup calls
    if [[ "$CLEANUP_IN_PROGRESS" == "true" ]]; then
        return
    fi
    CLEANUP_IN_PROGRESS=true
    
    if [[ ${#CLEANUP_MOUNTS[@]} -gt 0 ]] || [[ ${#CLEANUP_DIRS[@]} -gt 0 ]] || [[ ${#CLEANUP_FILES[@]} -gt 0 ]]; then
        echo
        echo -e "\033[0;33m═══ Cleanup ═══\033[0m"
    fi
    
    # Unmount in reverse order
    for ((i=${#CLEANUP_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${CLEANUP_MOUNTS[i]}"
        if [[ -n "$mount_point" ]] && mountpoint -q "$mount_point" 2>/dev/null; then
            echo -e "\033[0;33m  Unmounting: $mount_point\033[0m"
            cleanup_mount "$mount_point"
        fi
    done
    
    # Remove files
    for file in "${CLEANUP_FILES[@]}"; do
        if [[ -n "$file" ]] && [[ -f "$file" ]]; then
            echo -e "\033[0;33m  Removing file: $file\033[0m"
            rm -f "$file" 2>/dev/null || true
        fi
    done
    
    # Remove directories in reverse order
    for ((i=${#CLEANUP_DIRS[@]}-1; i>=0; i--)); do
        local dir="${CLEANUP_DIRS[i]}"
        if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
            echo -e "\033[0;33m  Removing directory: $dir\033[0m"
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
    
    # Clear arrays
    CLEANUP_MOUNTS=()
    CLEANUP_FILES=()
    CLEANUP_DIRS=()
}

# Register cleanup items
register_file() {
    CLEANUP_FILES+=("$1")
}

register_dir() {
    CLEANUP_DIRS+=("$1")
}

register_mount() {
    CLEANUP_MOUNTS+=("$1")
}

# Unregister cleanup items (when successfully handled)
unregister_file() {
    local file="$1"
    local new_array=()
    for f in "${CLEANUP_FILES[@]}"; do
        [[ "$f" != "$file" ]] && new_array+=("$f")
    done
    CLEANUP_FILES=("${new_array[@]}")
}

unregister_dir() {
    local dir="$1"
    local new_array=()
    for d in "${CLEANUP_DIRS[@]}"; do
        [[ "$d" != "$dir" ]] && new_array+=("$d")
    done
    CLEANUP_DIRS=("${new_array[@]}")
}

unregister_mount() {
    local mount="$1"
    local new_array=()
    for m in "${CLEANUP_MOUNTS[@]}"; do
        [[ "$m" != "$mount" ]] && new_array+=("$m")
    done
    CLEANUP_MOUNTS=("${new_array[@]}")
}

# Trap handlers
trap_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ "$CLEANUP_IN_PROGRESS" == "false" ]]; then
        echo
        print_error "Script exited with error code: $exit_code"
    fi
    cleanup_all
}

trap_int() {
    echo
    print_warning "Interrupted by user (Ctrl+C)"
    cleanup_all
    exit 130
}

trap_err() {
    local exit_code=$?
    if [[ "$CLEANUP_IN_PROGRESS" == "false" ]]; then
        echo
        print_error "Command failed with exit code: $exit_code"
    fi
}

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

# Function to refresh partition table and inform kernel
refresh_partitions() {
    local device="$1"
    sync
    blockdev --rereadpt "$device" 2>/dev/null || true
    partprobe "$device" 2>/dev/null || true
    sleep 3
}

# Function to get partition table type
get_partition_table_type() {
    local device="$1"
    local pttype=$(blkid -p -s PTTYPE -o value "$device" 2>/dev/null || echo "unknown")
    echo "$pttype"
}

# Function to get last partition number
get_last_partition_number() {
    local device="$1"
    local pttype="$2"
    local last_num=""
    
    if [[ "$pttype" == "dos" ]] || [[ "$pttype" == "msdos" ]]; then
        # Use sfdisk for MBR - it properly handles hybrid ISO partitions
        last_num=$(sfdisk -l "$device" 2>/dev/null | grep "^${device}" | awk '{print $1}' | sed "s|${device}p\?||" | sort -n | tail -1)
    elif [[ "$pttype" == "gpt" ]]; then
        last_num=$(sgdisk -p "$device" 2>/dev/null | grep "^ *[0-9]" | tail -1 | awk '{print $1}')
    fi
    
    echo "$last_num"
}

# Function to get partition device path
get_partition_path() {
    local device="$1"
    local part_num="$2"
    
    # Method 1: Try with 'p' separator (nvme, mmcblk, loop, etc.)
    local part_path="${device}p${part_num}"
    if [[ -b "$part_path" ]]; then
        echo "$part_path"
        return 0
    fi
    
    # Method 2: Try without separator (sd*, vd*, etc.)
    part_path="${device}${part_num}"
    if [[ -b "$part_path" ]]; then
        echo "$part_path"
        return 0
    fi
    
    # Method 3: Fallback - return best guess based on device name
    if [[ "$device" =~ [0-9]$ ]] || [[ "$device" =~ (nvme|mmcblk|loop) ]]; then
        echo "${device}p${part_num}"
    else
        echo "${device}${part_num}"
    fi
}

# Function to wait for partition to appear
wait_for_partition() {
    local part_path="$1"
    local timeout="${2:-15}"
    
    for i in $(seq 1 $timeout); do
        if [[ -b "$part_path" ]]; then
            return 0
        fi
        sleep 1
    done
    
    print_error "Partition $part_path was not created"
    print_info "Available partitions:"
    lsblk "$(dirname "$part_path" | sed 's/p$//')" 2>/dev/null || lsblk
    return 1
}

# Function to create partition
create_partition() {
    local device="$1"
    local size_mb="$2"  # Empty or 0 means use all remaining space
    local pttype="$3"
    
    local result=0
    
    if [[ "$pttype" == "dos" ]] || [[ "$pttype" == "msdos" ]]; then
        # MBR/DOS partition table - use sfdisk --append
        # sfdisk properly handles hybrid ISO partitions and appends without overwriting
        local last_sector=$(sfdisk -l "$device" 2>/dev/null | grep "^${device}" | awk '{print $3}' | sort -n | tail -1)
        
        if [[ -z "$last_sector" ]]; then
            print_error "Could not determine last partition end"
            sfdisk -l "$device" 2>/dev/null || true
            return 1
        fi
        
        # Start one sector after the last partition
        local start_sector=$((last_sector + 1))
        
        if [[ -z "$size_mb" ]] || [[ "$size_mb" -eq 0 ]]; then
            # Use all remaining space - empty size field means use all
            echo "${start_sector},,83" | sfdisk --append --no-reread --force "$device" 2>&1 | grep -vE "(iso9660|wipefs|Checking that|recommended)" || result=$?
        else
            # Use specified size - convert MB to sectors (MB * 1024 * 1024 / 512)
            local size_sectors=$((size_mb * 2048))
            echo "${start_sector},${size_sectors},83" | sfdisk --append --no-reread --force "$device" 2>&1 | grep -vE "(iso9660|wipefs|Checking that|recommended)" || result=$?
        fi
        
    elif [[ "$pttype" == "gpt" ]]; then
        # GPT partition table - use sgdisk
        if [[ -z "$size_mb" ]] || [[ "$size_mb" -eq 0 ]]; then
            # Use all remaining space
            sgdisk -q -n 0:0:0 -t 0:8300 "$device" 2>&1 || result=$?
        else
            # Use specified size
            sgdisk -q -n 0:0:+${size_mb}M -t 0:8300 "$device" 2>&1 || result=$?
        fi
        
    else
        print_error "Unsupported partition table type: $pttype"
        return 1
    fi
    
    return $result
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
    -o, --offline PKGS      Create offline package repository
                            PKGS is comma-separated package list
                            (e.g., base,linux,bash - includes dependencies)
                            Searches system cache and downloads if needed
    --pacman-cache PATH     Pacman cache directory (default: /var/cache/pacman/pkg)
    -y, --yes              Skip confirmation prompts (DANGEROUS - use with caution)
    -h, --help             Show this help message

EXAMPLES:
    # Burn ISO with interactive confirmation
    $(basename "$0") -i rescarch.iso -d /dev/sdX

    # Burn ISO with 2GB persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdX -p 2G

    # Burn ISO with persistent storage using all remaining space
    $(basename "$0") -i rescarch.iso -d /dev/sdX -p

    # Burn ISO with offline packages and persistent storage
    $(basename "$0") -i rescarch.iso -d /dev/sdX -o base,linux,linux-firmware -p 1G

    # Burn ISO with full system packages
    $(basename "$0") -i rescarch.iso -d /dev/sdX -o base,linux,plasma,firefox

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
OFFLINE_PACKAGES=""
PACMAN_CACHE="/var/cache/pacman/pkg"
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
            # Package list is required
            if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                OFFLINE_PACKAGES="$2"
                shift 2
            else
                print_error "Package list is required with -o option"
                echo "Example: -o base,linux,linux-firmware"
                exit 1
            fi
            ;;
        --pacman-cache)
            PACMAN_CACHE="$2"
            shift 2
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
    TOTAL_STEPS=$((TOTAL_STEPS + 2))  # Prepare packages, Create offline partition
fi
if [[ "$CREATE_PERSISTENT" == true ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))  # Create persistent partition
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: VALIDATION AND CHECKS
# ═══════════════════════════════════════════════════════════════════════════

print_step "Validation and system checks"
TOTAL_SUBSTEPS=4

# Check if running as root
print_substep "Checking system requirements"
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=(lsblk dd mkfs.ext4 partprobe mount umount parted sfdisk blkid blockdev bc)
if [[ "$CREATE_OFFLINE" == true ]]; then
    REQUIRED_TOOLS+=(repo-add tar pactree mkfs.erofs)
fi

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

if [[ "$SKIP_CONFIRM" == false ]]; then
    verify_rescarch_iso "$ISO_PATH"
else
    print_info "Skipping ISO verification (-y flag)"
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
print_substep "Gathering device and ISO information"
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
    DEVICE_INFO_EXTRA="Volatile storage (data lost on reboot)"
    
elif [[ "$DEVICE_NAME" =~ ^nvme[0-9]+n[0-9]+ ]]; then
    DEVICE_CATEGORY="NVMe SSD"
    NVME_MODEL=$(cat "/sys/block/${DEVICE_NAME}/device/model" 2>/dev/null | tr -s ' ' || echo "")
    [[ -n "$NVME_MODEL" ]] && DEVICE_INFO_EXTRA="Model: $NVME_MODEL"
    
elif [[ "$DEVICE_NAME" =~ ^mmcblk[0-9]+ ]]; then
    DEVICE_CATEGORY="MMC/SD Card"
    MMC_TYPE=$(cat "/sys/block/${DEVICE_NAME}/device/type" 2>/dev/null || echo "")
    MMC_NAME=$(cat "/sys/block/${DEVICE_NAME}/device/name" 2>/dev/null || echo "")
    [[ -n "$MMC_NAME" ]] && DEVICE_INFO_EXTRA="Name: $MMC_NAME"
    [[ -n "$MMC_TYPE" ]] && DEVICE_INFO_EXTRA="${DEVICE_INFO_EXTRA:+$DEVICE_INFO_EXTRA, }Type: $MMC_TYPE"
    
elif [[ "$DEVICE_NAME" =~ ^sd[a-z]+ ]]; then
    if [[ "$DEVICE_ROTA" == "0" ]]; then
        DEVICE_CATEGORY="SATA/SAS SSD"
    else
        DEVICE_CATEGORY="SATA/SAS HDD"
    fi
    [[ "$IS_REMOVABLE" == "1" ]] && DEVICE_CATEGORY="USB/Removable Drive"
    
elif [[ "$DEVICE_NAME" =~ ^vd[a-z]+ ]]; then
    DEVICE_CATEGORY="Virtual Disk"
    DEVICE_INFO_EXTRA="Virtualized block device"
    
elif [[ "$DEVICE_NAME" =~ ^xvd[a-z]+ ]]; then
    DEVICE_CATEGORY="Xen Virtual Disk"
    DEVICE_INFO_EXTRA="Xen paravirtualized device"
    
elif [[ "$DEVICE_NAME" =~ ^hd[a-z]+ ]]; then
    DEVICE_CATEGORY="IDE/PATA Drive"
    
elif [[ "$DEVICE_NAME" =~ ^sr[0-9]+ ]]; then
    DEVICE_CATEGORY="Optical Drive"
    DEVICE_INFO_EXTRA="Warning: Optical drives are not recommended"
    
elif [[ "$DEVICE_NAME" =~ ^nbd[0-9]+ ]]; then
    DEVICE_CATEGORY="Network Block Device"
    DEVICE_INFO_EXTRA="Remote network storage"
    
elif [[ "$DEVICE_NAME" =~ ^rbd[0-9]+ ]]; then
    DEVICE_CATEGORY="Ceph RBD"
    DEVICE_INFO_EXTRA="Ceph distributed storage"
    
else
    DEVICE_CATEGORY="Block Device"
    DEVICE_INFO_EXTRA="Generic block device (kernel supported)"
fi

# Build device description
DEVICE_DESC="$DEVICE_CATEGORY"
[[ "$DEVICE_ROTA" == "0" ]] && [[ "$DEVICE_CATEGORY" =~ ^(Block Device|Virtual Disk) ]] && DEVICE_DESC="$DEVICE_DESC (SSD)"

print_info "Device: $TARGET_DEVICE ($DEVICE_SIZE_HUMAN) - $DEVICE_DESC"
[[ -n "$DEVICE_VENDOR$DEVICE_MODEL" ]] && print_info "Hardware: ${DEVICE_VENDOR:+$DEVICE_VENDOR }${DEVICE_MODEL}"
[[ -n "$DEVICE_TRAN" ]] && [[ "$DEVICE_TRAN" != "Unknown" ]] && print_info "Transport: $DEVICE_TRAN"
[[ -n "$DEVICE_INFO_EXTRA" ]] && print_info "$DEVICE_INFO_EXTRA"

print_success "All validation checks passed"

# ═══════════════════════════════════════════════════════════════════════════
# OFFLINE PACKAGES PREPARATION (if requested)
# ═══════════════════════════════════════════════════════════════════════════

# Prepare offline packages if requested (do this BEFORE confirmation)
PKG_COUNT=0
PACKAGES_SIZE=0
PACKAGES_SIZE_HUMAN=""
TEMP_PACKAGES=""

if [[ "$CREATE_OFFLINE" == true ]]; then
    print_step "Preparing offline packages"
    TOTAL_SUBSTEPS=6
    
    # Create temporary directory for packages
    TEMP_PACKAGES=$(mktemp -d)
    register_dir "$TEMP_PACKAGES"
    
    # Resolve dependencies for specified packages
    print_substep "Resolving dependencies for: $OFFLINE_PACKAGES"
    
    # Convert comma-separated list to space-separated
    PKG_LIST="${OFFLINE_PACKAGES//,/ }"
    
    # Update sync database
    print_substep "Updating package database"
    if ! pacman -Sy --quiet; then
        print_error "Failed to update package database"
        exit 1
    fi
    
    # Use pactree to get all packages including dependencies (from sync database)
    # -s: use sync database, -l: linear output, -u: unique packages
    declare -a all_packages
    for pkg in $PKG_LIST; do
        while IFS= read -r pkgname; do
            [[ -z "$pkgname" ]] && continue
            all_packages+=("$pkgname")
        done < <(pactree -slu "$pkg")
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
    
    print_info "Resolved ${#unique_packages[@]} packages (including dependencies)"
    
    # Download all packages to cache
    print_substep "Downloading packages to cache"
    if ! pacman -Sw --noconfirm --quiet --cachedir "$PACMAN_CACHE" "${unique_packages[@]}"; then
        print_error "Failed to download packages"
        exit 1
    fi

    # Verify pacman cache directory exists
    if [[ ! -d "$PACMAN_CACHE" ]]; then
        print_error "Pacman cache directory not found: $PACMAN_CACHE"
        exit 1
    fi
    
    # Get filenames using pacman -Sp
    print_info "Getting package filenames..."
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
    
    print_substep "Copying ${#packages_to_copy[@]} package files"
    print_info "Copying from cache: $PACMAN_CACHE"
    # Copy packages from cache
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
    
    print_substep "Creating package database"
    print_info "Building repository database..."
    cd "$TEMP_PACKAGES"
    
    # Use explicit extensions to exclude .sig files
    if ! repo-add rescarch.db.tar.gz *.pkg.tar.*[^.sig] 2>/dev/null; then
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

# ═══════════════════════════════════════════════════════════════════════════
# PERSISTENT SIZE CALCULATION (if requested)
# ═══════════════════════════════════════════════════════════════════════════

# Parse persistent size if specified
if [[ "$CREATE_PERSISTENT" == true ]] && [[ -n "$PERSISTENT_SIZE" ]]; then
    PERSISTENT_SIZE_BYTES=$(parse_size "$PERSISTENT_SIZE")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    PERSISTENT_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PERSISTENT_SIZE_BYTES")
fi

# ═══════════════════════════════════════════════════════════════════════════
# DISPLAY SUMMARY AND CONFIRMATIONS
# ═══════════════════════════════════════════════════════════════════════════

echo
echo "========================================"
echo ":: ISO Information"
echo "File: $ISO_PATH"
echo "Label: $ISO_LABEL"
echo "Size: $ISO_SIZE_HUMAN"
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
    echo "Info: $DEVICE_INFO_EXTRA"
fi
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
if ! wipefs -a "$TARGET_DEVICE" 2>/dev/null; then
    print_warning "wipefs not available, using fallback method"
    dd if=/dev/zero of="$TARGET_DEVICE" bs=1M count=10 status=none 2>/dev/null || true
fi

print_substep "Refreshing partition table"
print_info "Syncing and updating kernel partition table"
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
print_info "Flushing buffers to disk..."
sync
sleep 2
print_success "ISO written and synced successfully"

# Create offline package repository if requested
if [[ "$CREATE_OFFLINE" == true ]]; then
    print_step "Creating offline package partition"
    TOTAL_SUBSTEPS=6
    
    # Set permissions on package directory to 444 (world-readable) with root:root ownership
    print_substep "Setting permissions on package files"
    if ! chown -R root:root "$TEMP_PACKAGES"; then
        print_error "Failed to set ownership on package directory"
        exit 1
    fi
    if ! chmod -R 755 "$TEMP_PACKAGES"; then
        print_error "Failed to set permissions on package directory"
        exit 1
    fi
    
    # Create EROFS image without compression (data is already compressed)
    print_substep "Creating EROFS image (uncompressed)"
    EROFS_IMAGE=$(mktemp -u).erofs
    register_file "$EROFS_IMAGE"
    # -L: set volume label
    # --all-root: make all files owned by root
    # -T0: set all timestamps to 0 for reproducibility
    if ! mkfs.erofs -L "RA_PACKAGES" --all-root -T0 "$EROFS_IMAGE" "$TEMP_PACKAGES"; then
        print_error "Failed to create EROFS image"
        exit 1
    fi
    
    # Calculate EROFS image size and add 10MB overhead
    EROFS_SIZE=$(stat -c%s "$EROFS_IMAGE" 2>/dev/null || echo "0")
    if [[ "$EROFS_SIZE" -eq 0 ]]; then
        print_error "Failed to determine EROFS image size"
        exit 1
    fi
    PACKAGES_SIZE_MB=$((EROFS_SIZE / 1024 / 1024 + 10))  # Add 10MB overhead
    EROFS_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$EROFS_SIZE")
    print_info "EROFS image: $EROFS_SIZE_HUMAN (partition: ${PACKAGES_SIZE_MB}MB)"
    
    print_substep "Creating partition ($PACKAGES_SIZE_MB MB)"
    print_info "Refreshing partition table"
    # Refresh partition table
    refresh_partitions "$TARGET_DEVICE"
    
    # Detect partition table type
    PART_TABLE_TYPE=$(get_partition_table_type "$TARGET_DEVICE")
    print_info "Partition table type: $PART_TABLE_TYPE"
    
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
    print_info "Refreshing and waiting for $TARGET_DEVICE"
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
    if ! dd if="$EROFS_IMAGE" of="$PACKAGES_PART" bs=1M status=progress oflag=sync; then
        print_error "Failed to write EROFS image to partition"
        exit 1
    fi
    
    print_substep "Cleaning up and syncing"
    print_info "Removing temporary files and flushing buffers"
    sync
    rm -f "$EROFS_IMAGE"
    unregister_file "$EROFS_IMAGE"
    
    print_success "Offline package repository created: $PACKAGES_PART (EROFS, $EROFS_SIZE_HUMAN)"
fi

# Create persistent storage partition if requested
if [[ "$CREATE_PERSISTENT" == true ]]; then
    print_step "Creating persistent storage partition"
    TOTAL_SUBSTEPS=4
    
    print_substep "Detecting partition table"
    print_info "Refreshing partition table"
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
    print_info "Refreshing and waiting for $TARGET_DEVICE"
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
echo "════════════════════════════════════════════════════════════"
print_success "USB drive created successfully!"
echo "════════════════════════════════════════════════════════════"
echo
echo "Summary:"
echo "  ✓ Device: $TARGET_DEVICE"
echo "  ✓ ISO Label: $ISO_LABEL"
if [[ "$CREATE_OFFLINE" == true ]]; then
    echo "  ✓ Offline Packages: $PACKAGES_PART ($PKG_COUNT packages, $PACKAGES_SIZE_HUMAN)"
fi
if [[ "$CREATE_PERSISTENT" == true ]]; then
    PERSIST_SIZE=$(lsblk -b -n -o SIZE "$PERSIST_PART" 2>/dev/null || echo "0")
    PERSIST_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PERSIST_SIZE" 2>/dev/null || echo "Unknown")
    echo "  ✓ Persistent Storage: $PERSIST_PART ($PERSIST_SIZE_HUMAN)"
fi
echo
echo "Your RescArch USB drive is ready to use!"
echo
