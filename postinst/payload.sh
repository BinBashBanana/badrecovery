#!/bin/sh

SCRIPT_DATE="[2024-10-10]"

TARGET_DEVICE_P="${1%[0-9]*}"

# spinner is always the 2nd /bin/sh
spinner_pid=$(pgrep /bin/sh | head -n 2 | tail -n 1)
kill -9 "$spinner_pid"
pkill -9 tail
sleep 0.1

HAS_FRECON=0
if pgrep frecon >/dev/null 2>&1; then
	HAS_FRECON=1
	# restart frecon to make VT1 background black
	exec </dev/null >/dev/null 2>&1
	pkill -9 frecon || :
	rm -rf /run/frecon
	frecon-lite --enable-vt1 --daemon --no-login --enable-vts --pre-create-vts --num-vts=4 --enable-gfx
	until [ -e /run/frecon/vt0 ]; do
		sleep 0.1
	done
	exec </run/frecon/vt0 >/run/frecon/vt0 2>&1
	# note: switchvt OSC code only works on 105+
	printf "\033]switchvt:0\a\033]input:off\a"
	echo "Press CTRL+ALT+F1 if you're seeing this" | tee /run/frecon/vt1 /run/frecon/vt2 >/run/frecon/vt3
else
	exec </dev/tty1 >/dev/tty1 2>&1
	chvt 1
	stty -echo
	echo "Press CTRL+ALT+F1 if you're seeing this" | tee /dev/tty2 /dev/tty3 >/dev/tty4
fi

printf "\033[?25l\033[2J\033[H"

dark_output() {
	printf "\033[1;30m"
	"$@"
	printf "\033[0m"
}

block_char=$(printf "\xe2\x96\x88")
echo "Ck9PT08gICBPT08gIE9PT08gIE9PT08gIE9PT09PICBPT09PICBPT08gIE8gICBPIE9PT09PIE9PT08gIE8gICBPCk8gICBPIE8gICBPIE8gICBPIE8gICBPIE8gICAgIE8gICAgIE8gICBPIE8gICBPIE8gICAgIE8gICBPICBPIE8gCk9PT08gIE9PT09PIE8gICBPIE9PT08gIE9PT08gIE8gICAgIE8gICBPIE8gICBPIE9PT08gIE9PT08gICAgTyAgCk8gICBPIE8gICBPIE8gICBPIE8gICBPIE8gICAgIE8gICAgIE8gICBPICBPIE8gIE8gICAgIE8gICBPICAgTyAgCk9PT08gIE8gICBPIE9PT08gIE8gICBPIE9PT09PICBPT09PICBPT08gICAgTyAgIE9PT09PIE8gICBPICAgTyAgCgo=" | base64 -d | sed "s/O/$block_char/g"

echo "Welcome to BadRecovery (postinst)"
echo "Script date: $SCRIPT_DATE"
echo "https://github.com/BinBashBanana/badrecovery"
echo ""

echo "Unmounting /usb/tmp/install-mount-point"
umount /usb/tmp/install-mount-point
echo "...$?"

echo "Creating RW /tmp"
mount -t tmpfs -o rw,exec,size=50M tmpfs /tmp
echo "...$?"

echo "Modifying VPD (check_enrollment=0 block_devmode=0)"
echo "Note: the vpd utility acts really weird in recovery, but it actually writes the values ok."
vpd -i RW_VPD -s check_enrollment=0 -s block_devmode=0 >/dev/null 2>&1
echo "...$?"

echo "Setting block_devmode=0 in crossystem"
crossystem block_devmode=0
echo "...$?"

has_fwmp() {
	local result
	result=$(tpmc read 0x100a 0x28 2>/dev/null) || return 1
	set -- $result
	[ "$#" -eq 40 ] || return 1
	shift 4
	for i; do
		[ "$i" = 0 ] || return 0
	done
	return 1
}

has_platform_fwmp() {
	local result
	result=$(tpmc getp 0x100a 2>/dev/null) || return 1
	[ $((${result##* } & 3)) -ne 3 ] || return 0
	return 1
}

if has_fwmp; then
	echo "Removing FWMP"
	if tpmc getver | grep -q "vendor 43524f53$" && crossystem "devsw_boot?1" "mainfw_type?recovery" >/dev/null; then
		echo "FWMP removal may not work due to being in developer recovery mode."
		echo "If you get an error, try again in verified recovery mode."
	fi
	if has_platform_fwmp; then
		mount -t tmpfs -o mode=0755 none /usb/var
		mkdir -p -m 0777 /usb/run/dbus /usb/var/lib/tpm_manager
		chroot /usb /usr/bin/dbus-daemon --system --fork >/dev/null 2>&1
		chroot /usb /usr/sbin/trunksd
		chroot /usb /usr/bin/sudo -b -u tpm_manager -g tpm_manager /usr/sbin/tpm_managerd
		chroot /usb /usr/bin/gdbus wait --system --timeout 5 org.chromium.TpmManager
		chroot /usb /usr/bin/tpm_manager_client take_ownership >/dev/null
		printf "\x76\x28\x10\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" | chroot /usb /usr/bin/tpm_manager_client write_space --index=0x100a --file=/dev/stdin
		echo "...$?"
	else
		# note: undef may fail on TPM 1.2 devices
		# note: undef isn't implemented in tpmc before r72
		# if tpmc says code 0x18b, the FWMP space already doesn't exist (on TPM 2.0 at least)
		# if undef failed for any reason other than above, try to write 0x0 instead
		tpmc undef 0x100a
		tpmc_code=$?
		if [ $tpmc_code -ne 0 ]; then
			tpmc write 0x100a 76 28 10 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
			tpmc_code=$?
		fi
		echo "...$tpmc_code"
	fi
fi

echo "Recovering ROOT-A"
dark_output dd if="$TARGET_DEVICE_P"5 of="$TARGET_DEVICE_P"3 bs=$((1024 * 1024)) count=64 conv=notrunc

echo "Fixing stateful"
dark_output chroot /usb /sbin/mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_DEVICE_P"1

echo "Enabling devmode"
stateful_mnt=$(mktemp -d)
mount "$TARGET_DEVICE_P"1 "$stateful_mnt"
touch "$stateful_mnt/.developer_mode"
umount "$stateful_mnt"
rmdir "$stateful_mnt"

echo "Enter recovery mode and switch to developer mode now to skip the delay."

if [ $HAS_FRECON -eq 1 ]; then
	printf "\033]input:on\a"
else
	stty echo
fi

printf "\033[?25h"
exec setsid -c sh
