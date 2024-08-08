#!/bin/bash
# Check status of replication by reading last line of latest log file

LOGS="/var/log/zfs-replicate"

RECENT_LOG_FILE=$(ls ${LOGS} | grep autorep- | tail -n 1)
STATUS=$(tail -n 1 ${LOGS}/${RECENT_LOG_FILE})

echo "Last Replication Status"
echo "----------"
echo "${STATUS}"
echo "----------"
