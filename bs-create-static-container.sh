#!/bin/bash

# creating an ubuntu container with a static IP address turns out to be
# somewhat difficult.  There are a whole bunch of possible approaches
# to solve this.

source ./bs-config.sh

set -xe
if [ "$removeFirst" = "Y" ]; then
	$cmd lxc stop $name --timeout=5 || $cmd lxc stop -f $name
	$cmd lxc delete $name 
fi

$cmd lxc launch ubuntu:20.04 $name
sleep 5
$cmd lxc list
$cmd lxc file push - $name/etc/cloud/cloud.cfg.d/99-disable-network-config <<END
network: {config: disabled}
END
(
cat <<END;
network:
    version: 2
    ethernets:
        eth0:
            addresses:
            - ${containerIP}/32
            nameservers:
                addresses:
END
for nameserver in ${nameservers[@]}; do 
	echo "                - ${nameserver}"
done;
cat <<END
                search: []
            routes:
            -   to: 0.0.0.0/0
                via: 169.254.0.1
                on-link: true
END
) | $cmd lxc file push - $name/etc/netplan/10-manual.yaml 
$cmd lxc exec $name -- netplan apply < /dev/null
$cmd lxc stop $name --timeout=10 || $cmd lxc stop -f $name
$cmd lxc config device add $name eth0 name=eth0 nictype=routed \
	parent=$hostInterface type=nic ipv4.address=$containerIP
# $cmd lxc config show $name 
$cmd lxc start $name

# thank you https://blog.simos.info/how-to-know-when-a-lxd-container-has-finished-starting-up/ for the following
$cmd lxc exec $name -- bash -c 'while [ "$(systemctl is-system-running 2>/dev/null)" != "running" ] && [ "$(systemctl is-system-running 2>/dev/null)" != "degraded" ]; do sleep 1; done' </dev/null

# validate the system is functioning
# anyone know how to resolve the complaints that systemctl has?

$cmd lxc list
$cmd lxc exec $name -- apt-get update </dev/null
$cmd lxc exec $name -- apt-get -y upgrade
$cmd lxc exec $name -- systemctl --failed </dev/null
$cmd lxc exec $name -- snap remove lxd </dev/null

