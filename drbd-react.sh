#!/bin/bash

resource=$1
connection=$2
self_role=$3
remote_role=$4
self_disk=$5
remote_disk=$6
filesystem=$7

set -e

if [ "$connection" == "Connected" ]; then 
	if [ "$connection" != "$OLD_CONNECTED_STATE" ]; then
		echo "$resource - unfencing"
		/usr/local/bin/drbd-fence unlock $resource
	fi
else
	if [ "$self_role" == "Primary" ]; then
		echo "$resource - fencing off discounted peer"
		/usr/local/bin/drbd-fence lock $resource
	fi
fi

if [[ "$remote_role" == "Primary" ]]; then
	echo "$resource - remote is primary, nothing we can do"
	exit 0
fi

if [[ "$self_role" == "Secondary" ]] && [[ "$self_disk" == "UpToDate" ]]; then
	if [[ "$OLD_SELF_ROLE" == "Primary" ]]; then
		# Someone manually downgraded us?  Let's leave it be for now.
		echo "$resource - we've been downgraded, not intervening"
		exit 0
	fi
	
	# we know our peer isn't primary so let's try to become primary
	if [ "$connection" != "Connected" ]; then 
		echo "$resource - fencing off discounted peer"
		/usr/local/bin/drbd-fence lock $resource
	fi
	echo "$resource - become primary and start services"
	/usr/local/bin/$resource primary
fi

if [[ "$self_role" == "Primary" ]] && [[ "$OLD_SELF_ROLE" != "Primary" ]]; then
	echo "$resource - start services"
	/usr/local/bin/$resource primary
fi

if [[ "$self_role" == "Primary" ]] && [[ "$self_disk" != "UpToDate" ]] && [[ "$remote_disk" == "UpToDate" ]] && [[ "$connection" == "Connected" ]]; then 
	echo "$resource - demote self, stopping services"
	/usr/local/bin/$resource secondary
fi
