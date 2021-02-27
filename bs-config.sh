#!/bin/echo 

# edit these then run this file with bash
# most people use 192.168.1.0 netmask 255.255.255.0 

cmd=sudo 
name=booter
containerIP=172.20.2.18
hostInterface=enp37s0
dhcpNet=172.20.2.0
dhcpNetmask=255.255.255.0
dhcpRouter=172.20.2.1
nameservers="172.20.2.1 8.8.8.8"
dhcpRange="172.20.2.200 172.20.2.254"
dhcpDomain="sharnoff.org"
console=ttyS2
consoleSpeed=115200
ubuntuVersion=20.04.1
downloadDir=.
temporaryMount=/mnt
removeFirst=Y
