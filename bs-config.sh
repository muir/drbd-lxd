#!/bin/echo 


# used by bs-create-static-container.sh  bs-dhcp.sh  bs-pxelinux.sh  bs-tftp.sh

cmd=r0 # prefix for lxc commands.  Suggestions: sudo r0 env
name=booter
containerIP=172.20.1.33
removeFirst=Y # 'Y' or 'N'.   delete then re-create

# used by bs-create-static-container.sh  

containerRouting="bridged" # "routed" or "bridged".  Use bridged for DHCPD
hostInterface=br0 
extraCreateArgs="-s r0"

# used by bs-create-static-container.sh  bs-dhcp.sh  
# most people use 192.168.1.0 netmask 255.255.255.0 for DHCP

dhcpRouter=172.20.1.7 # gateway off the boot network
dhcpNetmask=255.255.255.0
nameservers="198.102.73.13 8.8.8.8"

# used by bs-dhcp.sh  

dhcpNet=172.20.1.0
dhcpRange="172.20.1.200 172.20.1.254"
dhcpDomain="day.org"

# used by bs-pxelinux.sh  

console=ttyS2
consoleSpeed=115200
ubuntuVersion=20.04.1
downloadDir=.
temporaryMount=/mnt

