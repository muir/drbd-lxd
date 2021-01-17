#!/bin/bash 

fs=/`basename $0`
dir=`dirname $0`
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
		exec $dir/$cmd "$@"
		;;
	start)
		drbdadm primary $resource
		vgimport -a
		lvchange -ay /dev/$resource
		mount "/$fs" && systemctl start "$fs"lxd
		;;
	stop)
		export LXD_DIR="$fs/lxd"
		$dir/lxc stop --all
		$dir/lxc stop -f --all
		systemctl stop "$fs"lxd 
		fuser -k -m "/$fs"
		unmount "/$fs"
		lvchange -an /dev/$resource
		vgexport -a
		drbdadm secondary $resource
		# kill -USR1 `cat /proc/pid....`
		;;
	*)
		echo "unknown command."
		echo "commands are: $0 lxc|lxd|start|stop"
		exit 1
		;;
esac

