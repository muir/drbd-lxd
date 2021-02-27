#!/bin/bash

source ./bs-config.sh
set -xe

# TFTP & HTTP

if [ "$removeFirst" = "Y" ]; then
	$cmd lxc exec $name -- apt-get purge -y openbsd-inetd atftpd micro-httpd </dev/null
	$cmd lxc exec $name -- rm -f /etc/inetd.conf
fi

$cmd lxc exec $name -- apt-get install -y openbsd-inetd </dev/null
$cmd lxc exec $name -- apt-get install -y atftpd micro-httpd </dev/null
$cmd lxc exec $name -- perl -p -i -e 'm/^tftp/ && s,\s/srv/tftp$, /tftpboot,' /etc/inetd.conf </dev/null
$cmd lxc exec $name -- perl -p -i -e 's/^(www\s)/#$1/' /etc/inetd.conf </dev/null
$cmd lxc exec $name -- perl -p -i -e '/^tftp\s/ && print "gopher	stream	tcp	nowait	nobody	/usr/sbin/tcpd /usr/sbin/micro-httpd /tftpboot\n"' /etc/inetd.conf </dev/null
$cmd lxc exec $name -- cat /etc/inetd.conf </dev/null
$cmd lxc exec $name -- service openbsd-inetd restart </dev/null
$cmd lxc exec $name -- service openbsd-inetd status </dev/null
