#!/usr/bin/env bash

if ! [ -d "$1" ]; then
	echo "Please specify a valid directory containing buildroot" >&2
	exit 1
fi

tar -czvf buildroot-badrecovery.tar.gz --exclude="./dl" -C "$1" . --owner=0 --group=0
