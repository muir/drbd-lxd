#!/bin/bash 

fs=/`basename $0`
bin=`dirname $0`
cmd="$1"

export F="$fs"
resource=`perl -n -e 'm,^/dev/r(\d+)/r\1lxd\s+\Q$ENV{F}\E\s, && print "r$1\n"' /etc/fstab`
if ! [[ "$resource" =~ ^r[0-9]+$ ]]; then
       	echo "could not determine drbd resource name" 
	exit 1 
fi
unset F

shift 1 
case "$cmd" in
	lxc|lxd)
		export LXD_DIR="$fs/lxd"
		exec $bin/$cmd "$@"
		;;
	start)
		drbdadm primary $resource
		mount "/$fs" && systemctl start "$fs"lxd
		mount "/$fs/pools" && systemctl start "$fs"lxd
		;;
	stop)
		export LXD_DIR="$fs/lxd"
		$bin/lxc stop --all
		$bin/lxc stop -f --all
		systemctl stop "$fs"lxd 
		fuser -k -m "/$fs/pools"
		unmount "/$fs/pools"
		fuser -k -m "/$fs"
		unmount "/$fs"
		drbdadm secondary $resource
		# kill -USR1 `cat /proc/pid....`
		;;
	*)
		echo "unknown command."
		echo "commands are: $0 lxc|lxd|start|stop"
		exit 1
		;;
esac

