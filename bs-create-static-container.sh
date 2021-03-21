#!/bin/bash

# creating an ubuntu container with a static IP address turns out to be
# somewhat difficult.  There are a whole bunch of possible approaches
# to solve this.

#
# Depending on the bs-config.sh, this can use 'routed' or 'bridge' LXC networking
# For most purposes, 'routed' is cleaner, but 'bridged' is required for a DHCP server
#

source "${CONTAINER_CONFIG:-./bs-config.sh}"

# GENERATE THE CONTAINER NETPLAN

IPprefix_by_netmask() {
    #function returns prefix for given netmask in arg1
    bits=0
    for octet in $(echo $1| sed 's/\./ /g'); do 
         binbits=$(echo "obase=2; ibase=10; ${octet}"| bc | sed 's/0//g') 
         let bits+=${#binbits}
    done
    echo "/${bits}"
}

case "$containerRouting" in 
	routed)
	  containerCidr="/32"
	  routes=`cat <<END
            routes:
              - to: 0.0.0.0/0
                via: 169.254.0.1
                on-link: true
END`
	  ;;
	bridged)
	  containerCidr=`IPprefix_by_netmask ${dhcpNetmask}`
          routes=`cat <<END
            routes:
              - to: 0.0.0.0/0
                via: ${dhcpRouter}
                metric: 100
END`
	  ;;
	*)
	   echo containerRouting must be bridged or routed
	   exit 1
	   ;;
esac

netplan=`
cat <<END;
network:
    version: 2
    ethernets:
        eth0:
            addresses:
              - ${containerIP}${containerCidr}
            nameservers:
                addresses:
END
for nameserver in ${nameservers[@]}; do 
	echo "                - ${nameserver}"
done;
cat <<END
                search: []
${routes}
END
`

# echo "$netplan"

set -x
if [ "$removeFirst" = "Y" ]; then
	$cmd lxc stop $name --timeout=5 || $cmd lxc stop -f $name
	$cmd lxc delete $name 
fi

set -e
$cmd lxc launch ubuntu:20.04 $name $extraCreateArgs
$cmd lxc exec $name -- bash -c 'while [ "$(systemctl is-system-running 2>/dev/null)" != "running" ] && [ "$(systemctl is-system-running 2>/dev/null)" != "degraded" ]; do sleep 1; done' </dev/null
$cmd lxc list
echo "network: {config: disabled}" | \
	$cmd lxc file push - $name/etc/cloud/cloud.cfg.d/99-disable-network-config
echo "$netplan" | $cmd lxc file push - $name/etc/netplan/10-manual.yaml 
$cmd lxc exec $name -- rm /etc/netplan/50-cloud-init.yaml < /dev/null
$cmd lxc exec $name -- netplan apply < /dev/null
$cmd lxc stop $name --timeout=10 || $cmd lxc stop -f $name
$cmd lxc config device add $name eth0 name=eth0 nictype="$containerRouting" \
	parent=$hostInterface type=nic ipv4.address=$containerIP
# $cmd lxc config show $name 
$cmd lxc start $name

# Validating a container is started is a bit hard.
# https://blog.simos.info/how-to-know-when-a-lxd-container-has-finished-starting-up/
$cmd lxc exec $name -- bash -c 'while [ "$(systemctl is-system-running 2>/dev/null)" != "running" ] && [ "$(systemctl is-system-running 2>/dev/null)" != "degraded" ]; do sleep 1; done' </dev/null

# validate the system is functioning
# anyone know how to resolve the complaints that systemctl has?

$cmd lxc list
$cmd lxc exec $name -- apt-get update </dev/null
$cmd lxc exec $name -- apt-get -y upgrade
$cmd lxc exec $name -- systemctl --failed </dev/null
$cmd lxc exec $name -- snap remove lxd </dev/null

