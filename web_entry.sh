#!/bin/bash
# this script should have pid 1

SHARED_FS_MNT="$1"

BUILD_OPTS=()
[ -f "$SHARED_FS_MNT"/opt.type ] && BUILD_OPTS+=("-t $(cat $SHARED_FS_MNT/opt.type)")
[ -f "$SHARED_FS_MNT"/opt.internal_disk ] && BUILD_OPTS+=("--internal_disk $(cat $SHARED_FS_MNT/opt.internal_disk)")
[ -f "$SHARED_FS_MNT"/opt.debug ] && BUILD_OPTS+=("--debug")

if time ./build_badrecovery.sh -i /dev/sda --yes --finalsizefile "$SHARED_FS_MNT"/finalsize ${BUILD_OPTS[@]}; then
	echo "Done building!"
else
	echo -e "An error occured\033[?25h"
	stty echo
	bash
fi

poweroff -f
tail -f /dev/null
