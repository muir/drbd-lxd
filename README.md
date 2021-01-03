
!!! AS OF Feb 3, 2020: IN-PROGRESS-DOCUEMENT, NOT YET READY !!!

# HA setup with LXD + DRBD with real static IP addresses for the containers

This is a recipe for a two-node shared-nothing high-availablity container server with
static IPs.  The containers will look like real hosts.  Anything you run in the
containers becomes highly available without any customization.  This does not 
include a load balancer: the availablity is achieved with failover rather than
redundancy.

This is an excellent choice for a 2-system setup.  It works fine with a few
systems but for more than a few, other setups are reccomended.

## Stack choices

### Ubuntu 20.04

There are really basic choices for your host OS.  Do you use a standard 
distribution or do you use a specialized container distribution?  My goal
here is a choice that will remain valid for the next 15 years.  Since
I was previously burned by openvz on Debian, I'm shying away from specialty
distributions.

Of the mainstream distributions, I have a personal preference for Ubuntu.
I'm pretty sure it will be around for a while.

The hosts are meant to be low maintenance so an Ubuntu LTS release fits the
bill. 

LXD support in Ubuntu 20.04 is only as a snap.  We'll have to install LXD
completely by hand.

### LXD instead of LXC

LXC really isn't meant to be used directly by humans.  The commands are inconsistent and
painful.

LXC/LXD instead of Docker.  Docker is great for containerizing an application.
It does not containerize whole hosts.  Only the specific ports that are wanted
are routed to Docker containers.  Persistence data in Docker requires layered
filesystems.  Sometimes Docker is exactly what's needed.  This is a recipe for
full system containers with persistence.

For mainline Linux distros, LXC, LXD, and Docker are the only game in town
for containers.

LXD in 2021 Compared to OpenVZ as of 2008...

Network configuration: OpenVZ trivially allows you to assign multiple static IP
addresses to containers.  Containers can only use those addresses.  Using static
IP addresses with LXD is complicated and requires setting up a bridge interface.
Once a container is on the bridge, it can use freely use any IP address it wants
to (not constrained by the host).  If I'm wrong about how I set this up, please
give me corrected instructions that allow me to set up multiple static IP addresses
per container.

Working on container filesystems.  OpenVZ containers do not use uid maps.  As best
I can tell, OpenVZ security was such that you couldn't escape from a container so
a uid map wasn't needed.  Working on the contents of a container with a uid map
is painful.

Documentation of LXD is plentiful and incomplete.  LXD is very flexible and can be
deployed in all sorts of situations.  Most of the documentation has examples that
were not useful for developing this recipe.

### DRBD

There aren't a lot of choices for a shared-nothing HA setup.  
[DRBD](https://help.ubuntu.com/lts/serverguide/drbd.html) provides over-the-network
mirroring of raw devices.  It can be used as the block device for most filesytems.

Alternatively, there are a few distributed filesystems: 
- [BeeGFS](https://www.beegfs.io/content/) - free but not open source;
- [Ceph](https://docs.ceph.com/docs/mimic/) - [requires an odd number of monitor nodes](https://technologyadvice.com/blog/information-technology/ceph-vs-gluster/);
- [Gluster](https://www.gluster.org/) - "Step 1 – Have at least three nodes";
- [XtreeemFS](http://www.xtreemfs.org/) - [poor performance](https://www.slideshare.net/azilian/performance-comparison).

None of those are performant, open source, and support a two-node configuration.

I used DRBD in my previous setup and while it's a bit complicated to set up,
it proved itself to be quite reliable.  And quick.

[DRBD configuration](https://github.com/LINBIT/drbd-8.0/blob/master/scripts/drbd.conf)
has lots of options.

Missing DRBD feature: call a script every time the status changes, passing in
all relevant data.  This would enable things like automatically promoting
one node if they're both secondary (and favoring the node that is not
out-of-date).

The biggest danger of running DRBD is getting into a split-brain situation. This can
happen if only one system is up and then it is brought down and then the other system
is up.  

### Container storage

LXD supports many ways to configure the storage for your containers.
If you want snapshotting capability then you need to run on top of LVM
or use ZFS or btrfs.  That's useful.

[ZFS doesn't seem to play well with DRBD](http://cedric.dufour.name/blah/IT/ZfsOnTopOfDrbd.html)
so that's out.

[At least one person](https://petrovs.info/2014/11/28/ha-cluster-with-linux-containers/)
uses btrfs with DRBD and doesn't think it's a terrible idea.

This recipe uses `btrfs`.

### Scripts for failover

There are a couple of alternatives:
- [Carp](https://ucarp.wordpress.com/) / (ucarp(8))[http://manpages.ubuntu.com/manpages/bionic/man8/ucarp.8.html]
- [VRRP (keepalived)](https://www.keepalived.org/);
- [Heartbeat/Pacemaker](http://linux-ha.org/wiki/Pacemaker).

Heartbeat is quite complicated.  
Carp (`ucarp`) is simple.  The issue I have with it is that it switches too easily.
keepalived looks moderately complicated but isn't well targeted to this applciation.

In general, these daemons try to provide very fast failover.  That's not what's needed
for this. Failover when you have to mount filesystems and restart a bunch of containers 
is somewhat expensive so we don't want a daemon that reacts instantly.

Instead, we can use use [drbd-watcher](https://github.com/muir/drbd-watcher) to invoke
scripts when the DRBD situation changes.

## Recipe

After installing Ubuntu 20.04 server...

### Ditch netplan

Set up networking using `/etc/network/interfaces` since netplan does not support
interface aliases and is thus not suitable for anything custom.

```bash
sudo apt install ifupdown net-tools
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 
```

This is the `/etc/network/interfaces` file on my test box:

```
auto lo
iface lo inet loopback

auto enp0s3
iface enp0s3 inet dhcp

iface enp0s8 inet static
        address 172.20.10.4/24
```

Once that's done you can make it totally final with:

```bash
dpkg -P cloud-init
rm -rf /etc/cloud
```

Ubuntu 20.04 can delay startup while looking for a network.  This isn't helpful for a server.
Disable it for good.

```bash
systemctl disable systemd-networkd-wait-online.service
systemctl mask systemd-networkd-wait-online.service
```

### Turn on IP forwarding:

```bash
sudo perl -p -i -e 's/^#?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p /etc/sysctl.conf
```

Note: This same thing may be needed inside containers

### Partition your DRBD disks.

You won't be booting off a DRBD partition (it may be possible but that's
not what this recipe is about).

use cfdisk (or whatever partition tool you prefer) to create partitions 
on the disk to be used for drbd.  
one 128MB * number-of-data-partitions partition for the meta-data.
the rest of the disk for data.
The number of data partitions should probably be one or two. 

### Set up DRBD

The [Ubuntu instructions](https://ubuntu.com/server/docs/ubuntu-ha-drbd)
are easy to follow.  Use them.

Suggestions:
- Do not using meta-disk internal because it puts the metadata at the end of the partition which means that you can't easily resize it.
- Use /dev/disk/by-partuuid/xxxxx to reference partition so that if you ever have a disk missing at boot you don't try to overly the wrong disk

### Mount filesystems

If you have more than one DRBD partition, do this multiple times...

```bash
fs=r0
drbd=0

mkdir /$fs
echo "/dev/drbd$drbd /$fs btrfs rw,noauto,relatime,space_cache,subvol=/,ssd 0 0 " | tee -a /etc/fstab
mount /$fs
```

### Bridged vs routed vs NAT

The goal of this recipe is full systems with static IP addresses.  Using various
bridges (`bridge-utils`, LXD bridge, etc) it is possible to set up LXD (and LXC)
with static IPs that allow the host to reach the container and vice versa.  It's
a bit painful, but it mostly works.

It falls down when the containers try to talk to other systems on the same
network.  ARP Reply packets don't make it back to the containers.  There are
a couple of possible hacky solutions:

- [fake briding](https://linux.die.net/man/8/parprouted) -- unexplored
- [forced arp](https://linux.die.net/man/8/send_arp) -- hacky, error prone, hard to manage
- a working bridge?   I didn't find one.

In LXD 3.18, there is a new `nictype` supported: `routed` that does exactly
what's wanted.

Installing LXD with [snap](https://snapcraft.io/) is not
compatible with setting a override `LXD_DIR` as required for running on top
of ephemeral (DRBD) filesystems.  Even extracting the binaries from a snap
doesn't work as they don't honor the `PATH` environment variable.

Since we're installing LXD manually, we can use the latest version.

## Build LXC/LXD from source

Install dependencies as suggested by the LXD build-from-source instructions:

```bash
sudo apt install acl autoconf dnsmasq-base git golang \
	libacl1-dev libcap-dev liblxc1 liblxc-dev libtool \
	libudev-dev libuv1-dev make pkg-config rsync \
	squashfs-tools tar tcl xz-utils ebtables \
	libapparmor-dev libseccomp-dev libcap-dev \
	lvm2 thin-provisioning-tools btrfs-progs \
	curl gettext jq sqlite3 libsqlite3-dev uuid-runtime bzr socat 
```

### Pick a release

Find a LXC release from their
[download page](https://linuxcontainers.org/lxc/downloads/).
Find a LXD release from their
[downlaod page](https://linuxcontainers.org/lxd/downloads/)

### Build LXC

Building LXC is easy. It's necessary to do it first so that LXD links against
a LXC library that knows about `routed` nictypes.

```bash
LXC_VERSION=4.0.5
mkdir -p $HOME/LXC
cd $HOME/LXC
wget https://linuxcontainers.org/downloads/lxc/lxc-$LXC_VERSION.tar.gz
tar xf lxc-$LXC_VERSION.tar.gz
cd lxc-$LXC_VERSION
./autogen.sh && ./configure && make && sudo make install
```

### Build LXD

The 
[build instructions](https://github.com/lxc/lxd) on the official site
don't work.  Try these instead.

```bash
LXD_VERSION=4.9
mkdir -p $HOME/LXD
cd $HOME/LXD
wget https://linuxcontainers.org/downloads/lxd/lxd-$LXD_VERSION.tar.gz
tar xf lxd-$LXD_VERSION.tar.gz
mv lxd-$LXD_VERSION/_dist/* .
rm src/github.com/lxc/lxd && mkdir src/github.com/lxc/lxd
mv lxd-$LXD_VERSION/* src/github.com/lxc/lxd
cd src/github.com/lxc/lxd
rmdir _dist && ln -s ../../.. _dist
export GOPATH=$HOME/LXD
make deps
```

Now cut'n'paste those `export` commands into your shell.

We need to step in to grab the lxc libraries we just installed:

```bash
CGO_CFLAGS="$CGO_CFLAGS -I/usr/local/include"
GO_LDFLAGS="$CGO_LDFLAGS -L/usr/local/lib"
LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/usr/local/lib"
```

Now we can build the rest:

```bash
make
```

### Install LXD

```bash
DEST=/usr/local/lxd
sudo mkdir -p /usr/local/bin $DEST $DEST/bin $DEST/lib
sudo cp $GOPATH/bin/* $DEST/bin/
cd $GOPATH/deps
for i in *; do
	if [ -d $i/.libs ]; then
		sudo mkdir -p $DEST/lib/$i
		sudo cp -r $i/.libs/* $DEST/lib/$i
	fi
done
for i in $DEST/bin/*; do sudo ln -s $DEST/lxdwrapper.sh /usr/local/bin/`basename $i`; done
```

### Install scripts

```bash
DEST=/usr/local/lxd
curl -s https://raw.githubusercontent.com/muir/drbd-lxd/lxdwrapper.sh | sudo tee $DEST/lxdwrapper.sh
sudo chmod +x $DEST/lxdwrapper.sh
```

If you have more than one DRBD partition, do this multiple times...

```bash
fs=r0
curl -s https://raw.githubusercontent.com/muir/drbd-lxd/fswrapper.sh | sudo tee /usr/local/bin/$fs
sudo chmod +x $DEST/usr/local/bin/$fs
```

## Set up LXD

We need to grab a couple of initialization files from the regular LXD package:

```bash
fs=r0
sudo apt install lxd-tools lxd
sudo systemctl disable lxd

sudo mkdir /$fs/lxd

perl -p -e 's/After=(.*)/After=$1 '"$fs"'.mount/' /lib/systemd/system/lxd.service | \
	perl -p -e '/^Restart=/ && print "Environment=LXD_DIR='"$fs"'/lxd\n"' | \
	perl -p -e 's,/usr/bin/lxd,/usr/local/bin/lxd,g' | \
	sudo tee /etc/systemd/system/"$fs"lxd.service

sudo systemctl start "$fs"lxd
```

### For Ubuntu 20.04 and other systems that don't have `lxd.service`...

An alternative:

```bash
fs=r0
cat << END | sudo tee /etc/systemd/system/"$fs"lxd.service
[Unit]
Description=$fs LXD - main daemon
After=network-online.target openvswitch-switch.service lxcfs.service 
Requires=network-online.target lxcfs.service 
Documentation=man:lxd(1)

[Service]
EnvironmentFile=-/etc/environment
Environment=LXD_DIR=${fs}/lxd
ExecStartPre=/usr/lib/x86_64-linux-gnu/lxc/lxc-apparmor-load
ExecStart=/usr/local/bin/lxd --group lxd --logfile=/var/log/lxd/lxd.log
ExecStartPost=/usr/local/bin/lxd waitready --timeout=600
KillMode=process
TimeoutStartSec=600s
TimeoutStopSec=30s
Restart=on-failure
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity

[Install]
END

### Initialize LXD

Override defaults for storage pool name.
Override defaults for networks.  If you let lxd "use" a network then
it will want to manage it with DHCP and NAT.  For people who want to
manage their own network with static IPs this is a bad thing.
Do not create a new local network bridge

```bash
$fs lxd init
Would you like to use LXD clustering? (yes/no) [default=no]: 
Do you want to configure a new storage pool? (yes/no) [default=yes]: 
Name of the new storage pool [default=default]: r0
Name of the storage backend to use (btrfs, dir, lvm) [default=btrfs]: 
Would you like to create a new btrfs subvolume under /r0/lxd? (yes/no) [default=yes]: 
Would you like to connect to a MAAS server? (yes/no) [default=no]: 
Would you like to create a new local network bridge? (yes/no) [default=yes]: no
Would you like to configure LXD to use an existing bridge or host interface? (yes/no) [default=no]: yes
Name of the existing bridge or host interface: enp0s8
Would you like LXD to be available over the network? (yes/no) [default=no]:  
Would you like stale cached images to be updated automatically? (yes/no) [default=yes] 
Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]: yes
```

### DRBD watcher script

Rather than using a keep alive daemon of some sort, we'll simply monitor the
DRBD status.

#### Watcher

Install [drbd-watcher](https://github.com/muir/drbd-watcher) as
`/usr/local/bin/drbd-watcher`.

#### Fencing

Install a script to manage fencing.  This can be implemented in many ways. The key
thing is to use an external service that is highly reliable.

Commands should be:

- `lock $RESOURCE`
- `unlock $RESOURCE`

Where `$RESOURCE` should be unique in your lock script and storage and
tied to your DRBD resource.  For lock storage that is used just by a
pair of systems, this can be just the resource identifier (eg `"r0"`)
and `$HOST` is the local hostname.  Status can be returned by the exit
code: 0 for success, 1 for failure.

This fencing script uses google cloud storage.

Install [gsutil & gcloud](https://cloud.google.com/storage/docs/gsutil_install#deb)

Install the script:

```bash
curl -s https://raw.githubusercontent.com/muir/drbd-lxd/drbd-fence.sh | sudo tee /usr/local/bin/drbd-fence
chmod +x /usr/local/bin/drbd-fence 
```

#### Reaction script

Install a script to react to changes in DRBD status.  The danger with such a script
is having some kind of fencing so that if you have only one node up and then bring it
down and then bring up the other node.

```bash
curl -s https://raw.githubusercontent.com/muir/drbd-lxd/drbd-react.sh | sudo tee /usr/local/bin/drbd-react
sudo chmod +x $DEST/usr/local/bin/drbd-react
```

#### Run the script on boot and keep it running

This seems to be the core of systemd...

```bash
cat << END | sudo tee /etc/systemd/system/drbd-watcher.service
[Unit]
Description=Monitor DRBD for changes

[Service]
ExecStart=/usr/local/bin/drbd-watcher /usr/local/bin/drbd-react
Restart=always
RestartSec=300

[Install]
WantedBy=default.target
END

systemctl start drbd-watcher
```


### Convert an OpenVZ container

Assuming you have a private (root) directory of an OpenVZ container in `root`:

```
rm -r root/dev root/proc
mkdir root/dev root/proc
(cd root; tar czf ../c1.tgz .)

tac metadata <<'END'
architecture: "x86_64"
creation_date: 1580073803
properties:
architecture: "x86_64"
description: "Ubuntu 14.04"
os: "debian"
release: "trusty"
END

$fs lxc image import metadata c1.tgz --alias c1image
$fs lxc launch c1image c1
```

### Static IP addresses

Setting static IP addresses can be done two ways.  First stop the container:

```bash
$fs lxc stop c1
```

You can do it with a command line:

```bash
$fs lxc config device set c1 eth0 nictype=routed parent=enp0s8 ipv4.address 172.20.10.88
```

Or edit the config of a container
and configure multiple static IP addresses.  For example:

`$fs lxc config edit dnstest` then define the network with:

```yaml
devices:
  eth0:
    ipv4.address: 172.20.10.88, 172.20.10.90
    nictype: routed
    parent: enp0s8
    type: nic
```

Inside the container, the network should not be configured.  It will start up as it needs to be.
Do not do DHCP.

Then restart:

```bash
$fs lxc start c1
```

## CARP

```bash
apt install ucarp
```


## Bonding ethernets for reliability and capacity

Typically in a DRBD setup, there will be a private cross-over cable
between the two hosts.  There is also likely a regular ethernet with
a switch that they're both connected to.

For reliability and performance, there are advantages to using both
networks at once.  The reliability advantage is that DRBD gets really
unhappy if both nodes are up but cannot reach each other.

Assuming that you aren't already using VLANs then the idea is to continue
not using VLANs except for the bonded DRBD traffic.

There are lots of people who do VLAN on top of bonding.  There are very few
people who do bonding on top ov VLAN.  One that does talk about it is
[scorchio](http://scorchio.pure-guava.org.nz/posts/Bonding_over_VLAN/).

See [vlan setup](https://wiki.ubuntu.com/vlan) for some basic vlan
configuration settings.

If the primary interface is untagged, leave it be.  Add a tagged interface
too (they can co-exist).  Set up the tagged interface on the main ethernet.

Then set up [bonding](https://help.ubuntu.com/community/UbuntuBonding)
between the private ethernet and the VLAN on the main
ethernet.  Use `bond-mode balance-rr` for simplicity.

Since DRBD traffic will now be going over the shared ethernet, perhaps
some security is order.  In the DRBD config, set

```
  net {
    cram-hmac-alg "sha1";
    shared-secret "your very own secret";
  }
```

## Extras

### PXE boot 

PXE boot so that if one system goes down, you can use the other one to
help fix it.  There are many ways to do this.  The easiest is to use
tftp to serve a pxelinux that boots using a ramdisk loaded over http.


```bash
apt install atftpd openbsd-inetd micro-httpd
```

Turn off serving on port 80.  Why does anything think that installing an unconfigured
web server is a good idea?
Since nobody uses gopher anymore, that's a fine port for serving /tftpboot files

```bash
perl -p -i 's/^(www\s)/#$1/' /etc/inetd.conf
perl -p -i '/^tftp\s/ && print "gopher	stream	tcp	nowait	nobody	/usr/sbin/tcpd /usr/sbin/micro-httpd /tftpboot\n"' /etc/inetd.conf
service openbsd-inetd restart
```

Build a /tftpboot

```bash
VERSION=20.04
wget http://old-releases.ubuntu.com/releases/$VERSION/ubuntu-$VERSION-live-server-amd64.iso
mkdir -p /tftpboot/ubuntu$VERSION
mv ubuntu-$VERSION-live-server-amd64.iso /tftpboot/ubuntu$VERSION
mount /tftpboot/ubuntu$VERSION/ubuntu-$VERSION-live-server-amd64.iso /mnt
cp /mnt/casper/vmlinuz /mnt/casper/initrd /mnt/ubuntu$VERSION


```

### obvious tools that 

Ubuntu 20.04 makes /etc/rc.local a pain. 
[here's how](https://linuxmedium.com/how-to-enable-etc-rc-local-with-systemd-on-ubuntu-20-04/)


### distrobuilder

If you don't trust pre-built images made by strangers, you can use
a Go program made by strangers, [distrobuilder](https://github.com/lxc/distrobuilder)
to build your container images.

## Other resources

[Here](https://www.thomas-krenn.com/en/wiki/HA_Cluster_with_Linux_Containers_based_on_Heartbeat,_Pacemaker,_DRBD_and_LXC)
is a similar recipe.  The main difference is that it uses a java-based
graphical user interface to control things.  That's not my cup of tea.

[Here](https://petrovs.info/2014/11/28/ha-cluster-with-linux-containers/) is a recipe that uses LXC,
DRBD, and btrfs.  This receipe doesn't include how to do failover.

