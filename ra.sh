#!/bin/bash

# RescArch Shared Utilities
# Common functions used across RescArch scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    local show_messages="${1:-true}"
    
    # Prevent recursive cleanup calls
    if [[ "$CLEANUP_IN_PROGRESS" == "true" ]]; then
        return
    fi
    CLEANUP_IN_PROGRESS=true
    
    if [[ ${#CLEANUP_MOUNTS[@]} -gt 0 ]] || [[ ${#CLEANUP_DIRS[@]} -gt 0 ]] || [[ ${#CLEANUP_FILES[@]} -gt 0 ]]; then
        if [[ "$show_messages" == "true" ]]; then
            echo
            echo -e "\033[0;33m═══ Cleanup ═══\033[0m"
        fi
    fi
    
    # Unmount in reverse order
    for ((i=${#CLEANUP_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${CLEANUP_MOUNTS[i]}"
        if [[ -n "$mount_point" ]] && mountpoint -q "$mount_point" 2>/dev/null; then
            [[ "$show_messages" == "true" ]] && echo -e "\033[0;33m  Unmounting: $mount_point\033[0m"
            cleanup_mount "$mount_point"
        fi
    done
    
    # Remove files
    for file in "${CLEANUP_FILES[@]}"; do
        if [[ -n "$file" ]] && [[ -f "$file" ]]; then
            [[ "$show_messages" == "true" ]] && echo -e "\033[0;33m  Removing file: $file\033[0m"
            rm -f "$file" 2>/dev/null || true
        fi
    done
    
    # Remove directories in reverse order
    for ((i=${#CLEANUP_DIRS[@]}-1; i>=0; i--)); do
        local dir="${CLEANUP_DIRS[i]}"
        if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
            [[ "$show_messages" == "true" ]] && echo -e "\033[0;33m  Removing directory: $dir\033[0m"
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
        cleanup_all true  # Show cleanup messages on error
    else
        cleanup_all false  # Hide cleanup messages on normal exit
    fi
}

trap_int() {
    echo
    print_warning "Interrupted by user (Ctrl+C)"
    cleanup_all true  # Show cleanup messages on interruption
    exit 130
}

trap_err() {
    local exit_code=$?
    if [[ "$CLEANUP_IN_PROGRESS" == "false" ]]; then
        echo
        print_error "Command failed with exit code: $exit_code"
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
            echo "${start_sector},,83" | sfdisk -q --append --no-reread --force "$device" 2>&1 || result=$?
        else
            # Use specified size - convert MB to sectors (MB * 1024 * 1024 / 512)
            local size_sectors=$((size_mb * 2048))
            echo "${start_sector},${size_sectors},83" | sfdisk -q --append --no-reread --force "$device" 2>&1 || result=$?
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

# Initialize cleanup tracking variables if not already set
if [[ -z "$CLEANUP_IN_PROGRESS" ]]; then
    CLEANUP_IN_PROGRESS=false
    declare -a CLEANUP_FILES
    declare -a CLEANUP_DIRS
    declare -a CLEANUP_MOUNTS
fi

# Initialize step tracking variables if not already set
if [[ -z "$CURRENT_STEP" ]]; then
    CURRENT_STEP=0
    TOTAL_STEPS=0
    CURRENT_SUBSTEP=0
    TOTAL_SUBSTEPS=0
fi
