## PXE boot 

Here are some recipes for setting up PXE boot

### Inside a container

The boot server can be inside a container.  Consider this optional.  Use the appropriate parent
interface and IP address.

```bash
lxc launch ubuntu:20.04 bootserver
$fs lxc config device add bootserver eth0 name=eth0 nictype=routed parent=enp0s3 type=nic ipv4.address=172.20.10.88
lxc exec bootserver /bin/bash
```

If networking doesn't work, add the following block to the config (with edits) using `lxc config edit bootserver`:


```bash
config:
  user.network-config: |
    version: 2
    ethernets:
        eth0:
            addresses:
            - 192.168.1.200/32
            nameservers:
                addresses:
                - 8.8.8.8
                search: []
            routes:
            -   to: 0.0.0.0/0
                via: 169.254.0.1
                on-link: true
```

If that still isn't enough, then inside the container:

```bash
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config
cat > /etc/netplan/10-manual.yaml <<END
network:
    version: 2
    ethernets:
        eth0:
            addresses:
            - 192.168.1.200/32
            nameservers:
                addresses:
                - 8.8.8.8
                search: []
            routes:
            -   to: 0.0.0.0/0
                via: 169.254.0.1
                on-link: true
END
netplan apply
```

## Common steps (NFS or live CD)

***NFS Steps do not work yet***

These apply to both NFS boot server and live CD boot server

```bash
sudo apt install openbsd-inetd isc-dhcp-server syslinux pxelinux net-tools
sudo apt install atftpd
sudo perl -p -i -e 'm/^tftp/ && s,\s/srv/tftp$, /tftpboot,' /etc/inetd.conf
sudo service openbsd-inetd restart
sudo mkdir -p /tftpboot/pxelinux.cfg
sudo ln -s . /tftpboot/tftpboot
sudo cp /usr/lib/PXELINUX/pxelinux.0 /tftpboot/
sudo cp /usr/lib/syslinux/modules/bios/* /tftpboot/

sudo tee /tftpboot/pxelinux.cfg/default <<END
DEFAULT	disk
PROMPT	1
SERIAL	0 9600 0x003
TIMEOUT	200
DISPLAY	menus/bootmsg.DISPLAY.default

LABEL	disk
	LOCALBOOT	0
END

sudo tee /tftpboot/menus/bootmsg.DISPLAY.default <<END
	boot choices

disk		boot from local disk (DEFAULT)
END
```

You also need to [configure your DHCP server](https://help.ubuntu.com/community/DisklessUbuntuHowto).
Note: follow the instructions there just for DHCP setup.  You won't need NFS.

There are also decent DHCP server setup instructions in
`/usr/share/doc/syslinux-common/asciidoc/pxelinux.txt.gz`

### PXE boot with NFS  

If you're doing this inside LXD, you cannout use `nfs-kernel-server`.  Use `nfs-ganesha` instead.

#### Container 

```bash
NFSROOT=/nfsroot
MYNETWORK=172.20.2.0/24
sudo apt install nfs-ganesha

sudo tee -a /etc/ganesha/ganesha.conf <<END
EXPORT
{
	# must be unique 0..65535
	Export_Id = 3282;
	Path = ${NFSROOT};
	Pseudo = /;
	Access_Type = RW;
	Squash = no_root_squash;
	Clients = ${MYNETWORK};
}
END

sudo systemctl enable nfs-ganesha
sudo systemctl start nfs-ganesha
```

#### Outside container

```bash
NFSROOT=/nfsroot
MYNETWORK=172.20.2.0/24
sudo apt install nfs-kernel-server
sudo systemctl enable nfs-kernel-server
sudo systemctl start nfs-kernel-server
sudo tee -a /etc/exports <<END
$NFSROOT             $MYNETWORK(rw,no_root_squash,async,insecure)
END
sudo exportfs -rv
```


```bash
NFSROOT=/nfsroot
sudo apt install debootstrap initramfs-tools 
sudo debootstrap --variant=buildd focal $NFSROOT
sudo mkdir -p /root/bin
sudo tee /root/bin/enter-`basename $NFSROOT` <<'END'
#!/bin/sh
mount -t proc /proc $NFSROOT/proc
mount --rbind /sys $NFSROOT/sys
mount --rbind /dev $NFSROOT/dev
chroot $NFSROOT
umount -R $NFSROOT/dev
umount -R $NFSROOT/sys 
umount -R $NFSROOT/proc 
END
sudo chmod +x /root/bin/enter-`basename $NFSROOT`
sudo cp /etc/apt/sources.list $NFSROOT/etc/apt/
sudo /root/bin/enter-`basename $NFSROOT`
```

In the chroot, whatever tools are needed for repair

```bash
apt update
apt upgrade
apt install btrfs-progs drbd-utils linux-image-generic systemd systemctl ifupdown net-tools

cat > /etc/fstab <<'END'
/proc    /proc    proc    defaults   0 0
/sys     /sys     sysfs   defaults   0 0
END
passwd root
echo BOOT=nfs > /etc/initramfs-tools/initramfs.conf
grep ^BOOT /etc/initramfs-tools/initramfs.conf
mkinitramfs -o ~/initrd.img

echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
dpkg -P cloud-init
rm -rf /etc/cloud
cat > /etc/network/interfaces <<END
auto lo
iface lo inet loopback
iface eth0 inet manual
END

cat > /etc/fstab <<END
proc            /proc           proc    defaults        0       0
/dev/nfs        /               nfs     defaults        0       0
none            /tmp            tmpfs   defaults        0       0
none            /var/run        tmpfs   defaults        0       0
none            /var/lock       tmpfs   defaults        0       0
none            /var/tmp        tmpfs   defaults        0       0
END

perl -pi -e 's/^(\s*)(exec update-grub)/$1# $2/' /etc/kernel/postinst.d/zz-update-grub

mkdir -p /root/.ssh
echo "YOUR SSH KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chmod 711 /root/.ssh
```

Do you need a [serial console](http://0pointer.de/blog/projects/serial-console.html)?

Do this in the nfs root:

```bash
systemctl enable serial-getty@ttyS2.service
```

Later, add `console=ttyS2,115200 console=tty0` to the kernel config parameters.

Now finish setting up the boot server

```bash
NFSROOT=/nfsroot
sudo mkdir -p /tftpboot/nfsroot
sudo cp $NFSROOT/boot/vmlinuz /tftpboot/nfsroot/
sudo cp $NFSROOT/root/initrd.img /tftpboot/nfsroot/

MY_IP=`ip route get 8.8.8.8 | sed -n '/src/{s/.*src *\([^ ]*\).*/\1/p;q}'`
echo my ip address is $MY_IP

sudo tee -a /tftpboot/pxelinux.cfg/default <<END
LABEL	nfs
KERNEL	nfsroot/vmlinuz
APPEND	root=/dev/nfs initrd=nfsroot/initrd.img nfsroot=${MY_IP}:/nfsroot ip=dhcp rw net.ifnames=0 biosdevname=0
END

sudo tee -a /tftpboot/menus/bootmsg.DISPLAY.default <<END
nfs		boot diskless with NFS
END

sudo chmod -R a+r /tftpboot
```


### PXE boot with live CD

PXE boot so that if one system goes down, you can use the other one to
help fix it.  There are many ways to do this.  The easiest is to use
tftp to serve a pxelinux that boots using a ramdisk loaded over http.

```bash
sudo apt install micro-httpd 
```

Turn off serving on port 80.  Why does anything think that installing an unconfigured
web server is a good idea?
Since nobody uses gopher anymore, that's a fine port for serving /tftpboot files

```bash
sudo perl -p -i -e 's/^(www\s)/#$1/' /etc/inetd.conf
sudo perl -p -i -e '/^tftp\s/ && print "gopher	stream	tcp	nowait	nobody	/usr/sbin/tcpd /usr/sbin/micro-httpd /tftpboot\n"' /etc/inetd.conf
sudo service openbsd-inetd restart
```

Build a /tftpboot

#### Add an ubuntu live CD

Pick one from [here](http://releases.ubuntu.com/)

```bash
VERSION=20.04.1
wget http://old-releases.ubuntu.com/releases/$VERSION/ubuntu-$VERSION-live-server-amd64.iso
sudo mkdir -p /tftpboot/ubuntu$VERSION
sudo cp ubuntu-$VERSION-live-server-amd64.iso /tftpboot/ubuntu$VERSION
sudo mount /tftpboot/ubuntu$VERSION/ubuntu-$VERSION-live-server-amd64.iso /mnt
sudo cp /mnt/casper/vmlinuz /mnt/casper/initrd /tftpboot/ubuntu$VERSION
sudo umount /mnt

MY_IP=`ip route get 8.8.8.8 | sed -n '/src/{s/.*src *\([^ ]*\).*/\1/p;q}'`
echo my ip address is $MY_IP

sudo tee -a /tftpboot/pxelinux.cfg/default <<END

LABEL	ubuntu${VERSION}
	KERNEL ubuntu${VERSION}/vmlinuz
	INITRD ubuntu${VERSION}/initrd
	APPEND root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=http://${MY_IP}:70/ubuntu${VERSION}/ubuntu-${VERSION}-live-server-amd64.iso
END

sudo tee -a /tftpboot/menus/bootmsg.DISPLAY.default <<END
ubuntu${VERSION}   boot ubuntu live cd
END

sudo chmod -R a+r /tftpboot
```

If you're using a serial console, note that `console` can only be specified once for the liveCD.  
Add: `console=ttyS2,115200` or whatever is appropraite to the kernel config parameters above .

## References

[Ubuntu Diskless HowTo](https://help.ubuntu.com/community/DisklessUbuntuHowto)

