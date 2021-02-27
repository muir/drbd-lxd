#!/bin/bash

fs=`basename $0`
bin=`dirname $0`
cmd="$1"

export F="/$fs"
resource=`perl -n -e 'm,^/dev/drbd(\d+)\s+\Q$ENV{F}\E\s, && print "r$1\n"' /etc/fstab`
if ! [[ "$resource" =~ ^r[0-9]+$ ]]; then
       	echo "could not determine drbd resource name"
	exit 1
fi
unset F

shift 1
case "$cmd" in
	lxc|lxd)
		export LXD_DIR="/$fs/lxd"
		exec $bin/$cmd "$@"
		;;
	start)
		if [[ "$1" != "" ]]; then
			echo "did you mean $bin lxc start $@ ?"
			exit 1
		fi
		set -ex
		drbdadm primary $resource
		if mountpoint -q "/$fs"; then
			echo "/$fs already mounted"
		else 
			mount "/$fs"
			sleep 1
		fi
		systemctl start "$fs"lxd
		if [[ -e "/$fs/actions/post-up" ]]; then
			/$fs/actions/post-up
		fi
		;;
	stop|suspend)
		if [[ "$1" != "" ]]; then
			echo "did you mean $bin lxc stop $@ ?"
			exit 1
		fi
		set -x
		export LXD_DIR="/$fs/lxd"
		if [[ -e "/$fs/actions/post-up" ]]; then
			/$fs/actions/pre-down
		fi
		$bin/lxc stop --all --timeout 10
		$bin/lxc stop -f --all
		systemctl stop "$fs"lxd
		fuser -k -m "/$fs/pools"
		fuser -k -m "/$fs/lxd/storage-pools/$fs"
		fuser -k -m "/$fs"
		umount -R "/$fs"
		systemctl stop multipathd
		if [[ "$cmd" = "stop" ]]; then
			drbdadm secondary $resource
		fi
		# kill -USR1 `cat /proc/pid....`
		;;
	*)
		echo "unknown command."
		echo "commands are: $0 lxc|lxd|start|stop"
		exit 1
		;;
esac

