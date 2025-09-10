#!/bin/bash

# LVM Partition Expansion Script
# This script helps to find a new hard drive, initialize it as a Physical Volume (PV),
# extend an existing Volume Group (VG) with this new PV, and then expand a
# Logical Volume (LV) and its filesystem.

# !!! WARNING !!!
# This script performs critical system modifications.
# IMPROPER USE CAN LEAD TO IRREVERSIBLE DATA LOSS.
# ENSURE YOU HAVE A COMPLETE BACKUP OF YOUR SYSTEM BEFORE PROCEEDING.

# --- Configuration ---
LOG_FILE="/var/log/lvm_expansion_$(date +%Y%m%d_%H%M%S).log"
# --- End Configuration ---

# Redirect all output to log file and console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- LVM Partition Expansion Script ---"
echo "Log file: $LOG_FILE"
echo ""

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: Required command '$1' not found. Please install it."
        exit 1
    fi
}

# Check for necessary commands
check_command "lsblk"
check_command "pvcreate"
check_command "vgextend"
check_command "lvextend"
check_command "resize2fs"
check_command "xfs_growfs"
check_command "pvs"
check_command "vgs"
check_command "lvs"
check_command "df"
check_command "findmnt"

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root. Please use 'sudo'."
   exit 1
fi

echo "--- Step 1: Identify the new hard drive ---"
echo "Listing all block devices. Look for a new disk that is not partitioned, not mounted, and has no filesystem type (FSTYPE)."
echo "Typically, these will be listed as 'disk' type with empty FSTYPE and MOUNTPOINT."
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE,KNAME --noheadings | grep " disk " | awk '{print $1, $2, $3, $4, $5, $6}'
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

NEW_DRIVE_NAME=""
read -p "Enter the KNAME of the new hard drive (e.g., sdb, sdc): " NEW_DRIVE_NAME

if [ -z "$NEW_DRIVE_NAME" ]; then
    echo "Error: No new drive name entered. Exiting."
    exit 1
fi

NEW_DRIVE_PATH="/dev/$NEW_DRIVE_NAME"

if ! lsblk "$NEW_DRIVE_PATH" &> /dev/null; then
    echo "Error: Device '$NEW_DRIVE_PATH' does not exist. Please check the KNAME."
    exit 1
fi

echo ""
echo "!!! DANGER !!!"
echo "You have selected '$NEW_DRIVE_PATH'."
echo "DOUBLE-CHECK THIS IS THE CORRECT, EMPTY DRIVE YOU INTEND TO USE."
echo "ALL DATA ON THIS DRIVE WILL BE LOST."
read -p "Type 'YES' (in capitals) to confirm that '$NEW_DRIVE_PATH' is the correct drive: " CONFIRM_NEW_DRIVE
if [ "$CONFIRM_NEW_DRIVE" != "YES" ]; then
    echo "Confirmation failed. Exiting to prevent data loss."
    exit 1
fi

# Check if the disk already has partitions or LVM signatures
echo "Checking for existing partitions or LVM signatures on $NEW_DRIVE_PATH..."
if parted -s "$NEW_DRIVE_PATH" print > /dev/null 2>&1; then
    echo "Warning: '$NEW_DRIVE_PATH' appears to have existing partition table."
    read -p "Are you absolutely sure you want to proceed and overwrite it? Type 'yes' to continue: " OVERWRITE_CONFIRM
    if [ "$OVERWRITE_CONFIRM" != "yes" ]; then
        echo "Aborting. Please ensure the drive is truly empty or back up its data."
        exit 1
    fi
fi
if pvscan "$NEW_DRIVE_PATH" &> /dev/null; then
    echo "Warning: '$NEW_DRIVE_PATH' already appears to be an LVM Physical Volume. This script expects a new, uninitialized drive."
    read -p "Do you want to proceed assuming it's okay to reuse this PV? Type 'yes' to continue: " REUSE_PV_CONFIRM
    if [ "$REUSE_PV_CONFIRM" != "yes" ]; then
        echo "Aborting. Please ensure the drive is truly new or prepare it accordingly."
        exit 1
    fi
fi

echo ""
echo "--- Step 2: Create a Physical Volume (PV) ---"
echo "Initializing '$NEW_DRIVE_PATH' as an LVM Physical Volume."
echo "This will wipe any existing data and partition tables on '$NEW_DRIVE_PATH'."
read -p "Press Enter to continue with pvcreate, or Ctrl+C to abort."
pvcreate "$NEW_DRIVE_PATH"
if [ $? -ne 0 ]; then
    echo "Error: pvcreate failed. Exiting."
    exit 1
fi
echo "Physical Volume '$NEW_DRIVE_PATH' created successfully."
pvs

echo ""
echo "--- Step 3: Extend an existing Volume Group (VG) ---"
echo "Listing existing Volume Groups:"
vgs

TARGET_VG_NAME=""
read -p "Enter the name of the Volume Group (VG) to expand (e.g., vg_system): " TARGET_VG_NAME

if [ -z "$TARGET_VG_NAME" ]; then
    echo "Error: No VG name entered. Exiting."
    exit 1
fi

if ! vgs "$TARGET_VG_NAME" &> /dev/null; then
    echo "Error: Volume Group '$TARGET_VG_NAME' does not exist. Exiting."
    exit 1
fi

echo "Adding '$NEW_DRIVE_PATH' to Volume Group '$TARGET_VG_NAME'."
read -p "Press Enter to continue with vgextend, or Ctrl+C to abort."
vgextend "$TARGET_VG_NAME" "$NEW_DRIVE_PATH"
if [ $? -ne 0 ]; then
    echo "Error: vgextend failed. Exiting."
    exit 1
fi
echo "Volume Group '$TARGET_VG_NAME' extended successfully."
vgs

echo ""
echo "--- Step 4: Expand a Logical Volume (LV) ---"
echo "Listing Logical Volumes in Volume Group '$TARGET_VG_NAME':"
lvs "$TARGET_VG_NAME"

TARGET_LV_NAME=""
read -p "Enter the name of the Logical Volume (LV) to expand (e.g., lv_root): " TARGET_LV_NAME

if [ -z "$TARGET_LV_NAME" ]; then
    echo "Error: No LV name entered. Exiting."
    exit 1
fi

TARGET_LV_PATH="/dev/$TARGET_VG_NAME/$TARGET_LV_NAME"

if ! lvs "$TARGET_LV_PATH" &> /dev/null; then
    echo "Error: Logical Volume '$TARGET_LV_PATH' does not exist in VG '$TARGET_VG_NAME'. Exiting."
    exit 1
fi

echo "Logical Volume '$TARGET_LV_PATH' selected for expansion."

# Calculate max available space in the VG for the LV
FREE_VG_SPACE_MB=$(vgs --noheadings -o vg_free --unit m "$TARGET_VG_NAME" | awk '{print int($1)}')
echo "Approximately ${FREE_VG_SPACE_MB}MiB free in Volume Group '$TARGET_VG_NAME'."

# Offer to use all free space
read -p "How much space (e.g., 10G, 500M) do you want to add to '$TARGET_LV_PATH'? (Or type 'MAX' to use all available space): " EXPAND_SIZE

if [ -z "$EXPAND_SIZE" ]; then
    echo "Error: No expansion size entered. Exiting."
    exit 1
fi

LVE_COMMAND="lvextend"
if [[ "$EXPAND_SIZE" =~ ^[Mm]$ ]] || [[ "$EXPAND_SIZE" =~ ^[Mm][Aa][Xx]$ ]]; then
    echo "Expanding Logical Volume '$TARGET_LV_PATH' to use all available space."
    LVE_COMMAND+=" -l +100%FREE"
else
    # Basic validation, ensure it's a number followed by G/M/T
    if ! [[ "$EXPAND_SIZE" =~ ^[0-9]+[GgMmTt]$ ]]; then
        echo "Error: Invalid size format. Please use e.g. 10G or 500M. Exiting."
        exit 1
    fi
    echo "Adding $EXPAND_SIZE to Logical Volume '$TARGET_LV_PATH'."
    LVE_COMMAND+=" -L +$EXPAND_SIZE"
fi

read -p "Press Enter to continue with lvextend, or Ctrl+C to abort."
$LVE_COMMAND "$TARGET_LV_PATH"
if [ $? -ne 0 ]; then
    echo "Error: lvextend failed. Exiting."
    exit 1
fi
echo "Logical Volume '$TARGET_LV_PATH' expanded successfully."
lvs "$TARGET_LV_PATH"

echo ""
echo "--- Step 5: Resize the Filesystem ---"
# Get the mount point of the LV
MOUNT_POINT=$(findmnt -no TARGET "$TARGET_LV_PATH" 2>/dev/null)

if [ -z "$MOUNT_POINT" ]; then
    echo "Warning: Could not find mount point for '$TARGET_LV_PATH'."
    echo "You will need to manually resize the filesystem. Use 'df -hT' to find the mount point."
    echo "Then use 'resize2fs $TARGET_LV_PATH' (for extX) or 'xfs_growfs /mount/point' (for XFS)."
    echo "Script completed with a warning. Please resize filesystem manually."
    exit 0
fi

echo "Logical Volume '$TARGET_LV_PATH' is mounted at '$MOUNT_POINT'."
FS_TYPE=$(df -T "$MOUNT_POINT" | awk 'NR==2 {print $2}')

case "$FS_TYPE" in
    ext2|ext3|ext4)
        echo "Filesystem type is $FS_TYPE. Resizing with resize2fs..."
        read -p "Press Enter to continue with resize2fs, or Ctrl+C to abort."
        resize2fs "$TARGET_LV_PATH"
        if [ $? -ne 0 ]; then
            echo "Error: resize2fs failed. Please check the filesystem for errors."
            echo "Script completed with an error during filesystem resize."
            exit 1
        fi
        echo "Filesystem resized successfully!"
        ;;
    xfs)
        echo "Filesystem type is XFS. Resizing with xfs_growfs..."
        # xfs_growfs works on the mount point
        read -p "Press Enter to continue with xfs_growfs, or Ctrl+C to abort."
        xfs_growfs "$MOUNT_POINT"
        if [ $? -ne 0 ]; then
            echo "Error: xfs_growfs failed. Please check the filesystem for errors."
            echo "Script completed with an error during filesystem resize."
            exit 1
        fi
        echo "Filesystem resized successfully!"
        ;;
    *)
        echo "Error: Unsupported filesystem type '$FS_TYPE' on '$MOUNT_POINT'."
        echo "You will need to manually resize the filesystem. Please consult documentation for '$FS_TYPE'."
        echo "Script completed with an error due to unsupported filesystem."
        exit 1
        ;;
esac

echo ""
echo "--- LVM Expansion Complete! ---"
echo "The Logical Volume '$TARGET_LV_PATH' and its filesystem have been expanded."
echo "Current disk usage:"
df -hT "$MOUNT_POINT"
echo "Please verify everything is as expected."
