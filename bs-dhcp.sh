#!/bin/bash

source ./bs-config.sh

# DHCPD

dhcpNameservers=`echo "${nameservers}" | perl -p -e 's/(\S)\s+(\S)/\1, \2/g'`
set -xe
$cmd lxc exec $name -- apt-get install -y isc-dhcp-server < /dev/null
$cmd lxc exec $name -- cp -n /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.orig </dev/null
$cmd lxc file push - $name/etc/dhcp/dhcpd.conf <<END
option domain-name "${dhcpDomain}";
option domain-name-servers $dhcpNameservers;
class "pxe" {
	next-server ${containerIP};
	match if substring (option vendor-class-identifier, 0, 9) = "PXEClient"; allow booting;
	filename "/tftpboot/pxelinux.0";
}
subnet ${dhcpNet} netmask ${dhcpNetmask} {
	range ${dhcpRange};
	option routers ${dhcpRouter};
	option domain-name-servers ${dhcpNameservers};
	option domain-name "${dhcpDomain}";
}
allow booting;
allow bootp;
default-lease-time 7200;
max-lease-time 86400;
END
$cmd lxc exec $name -- chmod a+r /etc/dhcp/dhcpd.conf </dev/null
$cmd lxc exec $name -- perl -p -i -e 's/INTERFACESv4=""/INTERFACESv4="eth0"/' /etc/default/isc-dhcp-server </dev/null

$cmd lxc exec $name -- systemctl enable isc-dhcp-server </dev/null
$cmd lxc exec $name -- systemctl start isc-dhcp-server </dev/null
$cmd lxc exec $name -- service isc-dhcp-server status </dev/null

