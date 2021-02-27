#!/bin/bash

source ./bs-config.sh
set -xe

# TFTPBOOT

if [ "$removeFirst" = "Y" ]; then
	$cmd lxc exec $name -- rm -rf /tftpboot
fi

$cmd lxc exec $name -- apt-get install -y syslinux pxelinux </dev/null
$cmd lxc exec $name -- mkdir -p /tftpboot/pxelinux.cfg </dev/null
$cmd lxc exec $name -- ln -s . /tftpboot/tftpboot </dev/null
$cmd lxc exec $name -- cp /usr/lib/PXELINUX/pxelinux.0 /tftpboot/ </dev/null
$cmd lxc exec $name -- bash -c 'cp /usr/lib/syslinux/modules/bios/* /tftpboot/' </dev/null

$cmd lxc file push - $name/tftpboot/pxelinux.cfg/default <<END
DEFAULT	disk
PROMPT	1
SERIAL	0 9600 0x003
TIMEOUT	200
DEFAULT menu.c32
MENU TITLE PXE Special Boot Menu

LABEL	disk
	MENU LABEL boot from disk (default)
	MENU DEFAULT
	LOCALBOOT	0
LABEL	lb80
	LOCALBOOT 0x80
LABEL	lb81
	LOCALBOOT 0x81
LABEL	lb82
	LOCALBOOT 0x82
LABEL	lb83
	LOCALBOOT 0x83
LABEL	hd0mbr
	MENU LABEL boot from disk0
	KERNEL  chain.c32
	APPEND  hd0
LABEL	hd1mbr
	MENU LABEL boot from disk1
	KERNEL  chain.c32
	APPEND  hd1
LABEL	hd2mbr
	MENU LABEL boot from disk2
	KERNEL  chain.c32
	APPEND  hd2
LABEL	hd3mbr
	MENU LABEL boot from disk3
	KERNEL  chain.c32
	APPEND  hd3
LABEL	ubuntu${ubuntuVersion}
	MENU LABEL ubuntu${ubuntuVersion} live CD
	KERNEL ubuntu${ubuntuVersion}/vmlinuz
	INITRD ubuntu${ubuntuVersion}/initrd
	APPEND root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=http://${containerIP}:70/ubuntu${ubuntuVersion}/ubuntu-${ubuntuVersion}-live-server-amd64.iso
LABEL	ubuntu${ubuntuVersion}${console}
	MENU LABEL ubuntu${ubuntuVersion} live CD over ${console}
	KERNEL ubuntu${ubuntuVersion}/vmlinuz
	INITRD ubuntu${ubuntuVersion}/initrd
	APPEND root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=http://${containerIP}:70/ubuntu${ubuntuVersion}/ubuntu-${ubuntuVersion}-live-server-amd64.iso console=${console},${consoleSpeed}
END

# ISO, kernel, initrd

if [[ ! -e "${downloadDir}/ubuntu-${ubuntuVersion}-live-server-amd64.iso" ]]; then 
	(cd "$downloadDir" && wget http://old-releases.ubuntu.com/releases/${ubuntuVersion}/ubuntu-${ubuntuVersion}-live-server-amd64.iso)
fi

$cmd lxc exec $name -- mkdir -p /tftpboot/ubuntu${ubuntuVersion} </dev/null
$cmd lxc file push ${downloadDir}/ubuntu-${ubuntuVersion}-live-server-amd64.iso ${name}/tftpboot/ubuntu${ubuntuVersion}/ubuntu-${ubuntuVersion}-live-server-amd64.iso 
sudo mount ${downloadDir}/ubuntu-${ubuntuVersion}-live-server-amd64.iso ${temporaryMount}
$cmd lxc file push ${temporaryMount}/casper/vmlinuz ${name}/tftpboot/ubuntu${ubuntuVersion}/vmlinuz
$cmd lxc file push ${temporaryMount}/casper/initrd ${name}/tftpboot/ubuntu${ubuntuVersion}/initrd
sudo umount ${temporaryMount} 

# make it readable

$cmd lxc exec $name -- chmod -R a+r /tftpboot </dev/null
$cmd lxc exec $name -- ls -FCR /tftpboot </dev/null
$cmd lxc exec $name -- tail -10 /tftpboot/pxelinux.cfg/default </dev/null
