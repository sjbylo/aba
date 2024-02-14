#!/bin/bash -e
# Incremental backups script.  Used to only backup (and copy) the changes since the last backup.

now=$(date "+%Y-%m-%d-%H-%M-%S")

if [ ! -s .backup.time.previous ]; then
	rm -f .backup.time.*
	# Do first full backup
	tar czf /tmp/backup-$now.tgz $(find sync/oc-mirror-workspace/ -type f) 
else
	# Do inc. backup since the last backup
	tar czf /tmp/backup-$now.tgz $(find sync/oc-mirror-workspace/ -type f -newer .backup.time.previous) 
fi
timestampfile=.backup.time.$now
touch $timestampfile && ln -s $timestampfile .backup.time.previous

