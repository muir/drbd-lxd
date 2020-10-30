#!/bin/bash

# This script does not strongly protect against both systems locking
# at the same time which could happen if they were both up
# but unable to talk to each other for some reason

bucket=gs://drbd2
cmd="$1"
resource="$2"

case "$cmd" in
	lock)
		resource=$2
		current=`gsutil cp $bucket/resource -`
		hostname=`hostname`
		case "$current" in 
			UNLOCKED)
				set -e
				echo $hostname | gsutil cp - $bucket/resource.lock
				# Pause in case of a simultaneous write by our peer.
				# This pause is not a guarantee but it likely catches
				# overlapping writes and allows only one system to
				# proceed.
				sleep 10 
				recheck=`gsutil cp $bucket/resource -`
				if [ "$recheck" == "$hostname" ]; then
					exit 0
				else
					exit 1
				fi
				;;
			"$hostname")
				echo lock already held
				exit 0
				;;
			"")
				echo lock not set up.  Use "'$0 unlock $resource'" to initialized
				exit 1
				;;
			*)
				echo lock held by $current
				exit 1
				;;
		esac
		;;
	unlock)
		echo "UNLOCKED" | gsutil cp - $bucket/resource.lock
		;;
	*)
		echo "unknown command"
		exit 1
esac
