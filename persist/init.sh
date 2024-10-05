#!/bin/bash

rm -rf /var/lib/whitelist/---persist---*/*
if [ -e /tmp/payload.sh ]; then
	exit
fi

cd /
cp /var/lib/whitelist/persist/payload.sh /tmp/payload.sh
exec bash -c "bash <(cat /tmp/payload.sh)"
