#!/usr/bin/env bash

rm -rf assets/webbuilder.tar assets/webbuilder.tar.zip
tar -cvf assets/webbuilder.tar web_entry.sh build_badrecovery.sh encstateful persist postinst unverified busybox/arm busybox/x86 lib/wax_common.sh lib/shflags lib/bin/i386/cgpt --owner=0 --group=0
cd assets
zip webbuilder.tar.zip webbuilder.tar
rm webbuilder.tar
