#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SSD_NVME_DEVICE_LIST=($(nvme list | grep "Amazon EC2 NVMe Instance Storage" | cut -d " " -f 1 || true))
SSD_NVME_DEVICE_COUNT=${#SSD_NVME_DEVICE_LIST[@]}
RAID_DEVICE=${RAID_DEVICE:-/dev/md0}
RAID_CHUNK_SIZE=${RAID_CHUNK_SIZE:-512}  # Kilo Bytes
FILESYSTEM_BLOCK_SIZE=${FILESYSTEM_BLOCK_SIZE:-4096}  # Bytes
STRIDE=$(expr $RAID_CHUNK_SIZE \* 1024 / $FILESYSTEM_BLOCK_SIZE || true)
STRIPE_WIDTH=$(expr $SSD_NVME_DEVICE_COUNT \* $STRIDE || true)


# Checking if provisioning already happend
if [[ "$(ls -A /var/lib/pv-disks)" ]]
then
  echo 'Volumes already present in "/var/lib/pv-disks"'
  echo -e "\n$(ls -Al /var/lib/pv-disks | tail -n +2)\n"
  echo "I assume that provisioning already happend, doing nothing!"
  sleep infinity
fi

# Perform provisioning based on nvme device count
case $SSD_NVME_DEVICE_COUNT in
"0")
  echo 'No devices found of type "Amazon EC2 NVMe Instance Storage"'
  echo "Maybe your node selectors are not set correct"
  exit 1
  ;;
"1")
  mkfs.ext4 -m 0 -b $FILESYSTEM_BLOCK_SIZE $SSD_NVME_DEVICE_LIST
  DEVICE=$SSD_NVME_DEVICE_LIST
  ;;
*)
  mdadm --create --verbose $RAID_DEVICE --level=0 -c ${RAID_CHUNK_SIZE} \
    --raid-devices=${#SSD_NVME_DEVICE_LIST[@]} ${SSD_NVME_DEVICE_LIST[*]}
  while [ -n "$(mdadm --detail $RAID_DEVICE | grep -ioE 'State :.*resyncing')" ]; do
    echo "Raid is resyncing.."
    sleep 1
  done
  echo "Raid0 device $RAID_DEVICE has been created with disks ${SSD_NVME_DEVICE_LIST[*]}"
  mkfs.ext4 -m 0 -b $FILESYSTEM_BLOCK_SIZE -E stride=$STRIDE,stripe-width=$STRIPE_WIDTH $RAID_DEVICE
  DEVICE=$RAID_DEVICE
  ;;
esac

UUID=$(blkid -s UUID -o value $DEVICE | egrep '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{8}' -o)
mkdir -p /var/lib/pv-disks/$UUID
mount -t ext4 -o defaults,noatime,discard,nobarrier $DEVICE /var/lib/pv-disks/$UUID
rm -rf /var/lib/nvme/disk || true
ln -s /var/lib/pv-disks/$UUID /var/lib/nvme/disk
echo "Device $DEVICE has been mounted to /var/lib/pv-disks/$UUID"
echo "NVMe SSD provisioning is done and I will go to sleep now"

sleep infinity
