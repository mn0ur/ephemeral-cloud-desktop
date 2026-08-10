#!/usr/bin/env bash
# Grow a user's desktop volume, keeping every file already on it.
#
# EBS expansion is online and in place: the data is not copied, moved or
# recreated. The filesystem inside is grown by resize2fs on the next desktop
# start (see terraform/user-data.sh.tpl) - the block device growing is not
# enough on its own, which is the part that catches people out.
#
# ONE DIRECTION ONLY. EBS cannot shrink a volume, and there is no undo. Going
# smaller means creating a new smaller volume and copying data into it.
#
# Usage: expand-volume.sh <username> <new-size-gb>
#   e.g. expand-volume.sh mnuowr 30
set -euo pipefail

USERNAME="${1:?usage: expand-volume.sh <username> <new-size-gb>}"
NEW_SIZE="${2:?usage: expand-volume.sh <username> <new-size-gb>}"
REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

case "$NEW_SIZE" in
  ''|*[!0-9]*) echo "FATAL: size must be a whole number of GB, got '$NEW_SIZE'"; exit 1 ;;
esac

VOL=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Owner,Values=$USERNAME" "Name=tag:Role,Values=desktop-guest-data" \
  --query 'Volumes[0].VolumeId' --output text)

if [ "$VOL" = "None" ] || [ -z "$VOL" ]; then
  echo "FATAL: no desktop volume found for user '$USERNAME' in $REGION."
  echo "They may never have started a desktop with 'keep my data' enabled."
  exit 1
fi

CURRENT=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOL" \
  --query 'Volumes[0].Size' --output text)

echo "user:    $USERNAME"
echo "volume:  $VOL"
echo "size:    ${CURRENT}GB -> ${NEW_SIZE}GB"

if [ "$NEW_SIZE" -eq "$CURRENT" ]; then
  echo "Already ${CURRENT}GB. Nothing to do."
  exit 0
fi

# Refuse rather than let AWS reject it later with a less obvious message.
if [ "$NEW_SIZE" -lt "$CURRENT" ]; then
  echo "FATAL: cannot shrink an EBS volume (${CURRENT}GB -> ${NEW_SIZE}GB)."
  echo "EBS supports growing only. To go smaller, create a new volume and copy the data."
  exit 1
fi

aws ec2 modify-volume --region "$REGION" --volume-id "$VOL" --size "$NEW_SIZE" \
  --query 'VolumeModification.[VolumeId,TargetSize,ModificationState]' --output text

echo
echo "Done. The volume is now ${NEW_SIZE}GB."
echo "The filesystem inside still reports ${CURRENT}GB until the next desktop"
echo "start, which runs resize2fs and picks up the new space automatically."
echo "Every existing file is untouched."
