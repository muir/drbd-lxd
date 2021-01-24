
!!! AS OF Jan 20, 2021: NEARING COMPLETION, ALMOST WORKS WORKS !!!

!!! see [current problem](https://discuss.linuxcontainers.org/t/lxc-launch-failed-to-create-file-backup-yaml-no-such-file-or-directory/10021) !!!

# HA setup with LXD + DRBD with real static IP addresses for the containers

This is a recipe for a two-node shared-nothing high-availablity container server with
static IPs.  The containers will look like real hosts.  Anything you run in the
containers becomes highly available without any customization.  This does not
include a load balancer: the availablity is achieved with failover rather than
redundancy.  Containers have persistent storage that fails over with the
contaniner.

This is an excellent choice for a 2-system setup.  It works fine with a few
systems but for more than a few, other setups are reccomended.

## Stack choices

### Ubuntu 20.04

There are really basic choices for your host OS.  Do you use a standard
distribution or do you use a specialized container distribution?  My goal
here is a choice that will remain valid for the next 15 years.

Of the mainstream distributions, I have a personal preference for Ubuntu.
I'm pretty sure it will be around for a while.

The hosts are meant to be low maintenance so an Ubuntu LTS release fits the
bill.

LXD support in Ubuntu 20.04 is only as a snap.  We'll have to install LXD
completely by hand because the snap-based LXD does not honor overriding 
the LXD_DIR environment variable.

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

[DRBD configuration](https://github.com/LINBIT/drbd-8.0/blob/main/scripts/drbd.conf)
has lots of options.

Missing DRBD feature: call a script every time the status changes, passing in
all relevant data.  This would enable things like automatically promoting
one node if they're both secondary (and favoring the node that is not
out-of-date).

The biggest danger of running DRBD is getting into a split-brain situation. This can
happen if only one system is up and then it is brought down and then the other system
is brought up.

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
- [Carp](https://ucarp.wordpress.com/) / [ucarp(8)](http://manpages.ubuntu.com/manpages/bionic/man8/ucarp.8.html)
- [VRRP (keepalived)](https://www.keepalived.org/);
- [Heartbeat/Pacemaker](http://linux-ha.org/wiki/Pacemaker).

Heartbeat is quite complicated.
Carp (`ucarp`) is simple.  The issue I have with it is that it switches too easily.
keepalived looks moderately complicated but isn't well targeted to this applciation.

In general, these daemons try to provide very fast failover.  That's not what's needed
for this. Failover when you have to mount filesystems and restart a bunch of containers
is somewhat expensive so we don't want a daemon that reacts instantly.

Instead, we'll leverage the built-in monitoring that DRBD provides to invoke
scripts when the DRBD situation changes.  [drbd-watcher](https://github.com/muir/drbd-watcher) 

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
Disable it for good:

```bash
systemctl disable systemd-networkd-wait-online.service
systemctl mask systemd-networkd-wait-online.service
```

### Turn on IP forwarding:

```bash
sudo perl -p -i -e 's/^#?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p /etc/sysctl.conf
```

Note: This same thing may be needed inside containers.

### Partition your DRBD disks.

You won't be booting off a DRBD partition (it may be possible but that's
not what this recipe is about).

use `cfdisk` (or whatever partition tool you prefer) to create partitions
on the disk to be used for drbd.
one 128MB times number-of-data-partitions partition for the meta-data.
the rest of the disk for data.
The number of data partitions should probably be one or two.

### Set up DRBD

The [Ubuntu instructions](https://ubuntu.com/server/docs/ubuntu-ha-drbd)
are easy to follow.  Use them.

Suggestions:
- Do not using meta-disk internal because it puts the metadata at the end of the partition which means that you can't easily resize it.
- Use /dev/disk/by-partuuid/xxxxx to reference partition so that if you ever have a disk missing at boot you don't try to overly the wrong disk
- Put the resource specific configs in `/etc/drbd.d/r[0-9].res`

I recommend the following split brain configuration:

```
net {
	after-sb-0pri discard-least-changes;
	after-sb-1pri consensus;
	after-sb-2pri disconnect;
}
```

Discard-least-changes should always be safe given the fencing setup (described below).

In the case that split brain is not automatically resolved, it will have to be resolved
manually.  Google "drbd split brain recovery".  Generally the method to do recovery is
to pick a victum and invalidate it:

```bash
drbdadm disconnect r1
drbdadm secondary r1
drbdadm connect --discard-my-data r1
```

Then tell the other system to reconnect:

```bash
drbdadm primary r1
drbdadm connect r1
```

### Mount filesystems

If you have more than one DRBD partition, do this multiple times...

```bash
drbd=0
fs=r$drbd

sudo mkdir /$fs
echo "/dev/drbd$drbd /$fs btrfs rw,noauto,relatime,space_cache,subvol=/,ssd 0 0 " | sudo tee -a /etc/fstab
sudo mount /$fs
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

Since we're installing LXD manually anyway, we can use the latest version.  
Note: Ubuntu 18.04 includes lxd as a regular package, but the version is too
old to support routed networking.

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
LXC_VERSION=4.0.6
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
LXD_VERSION=4.10
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
```

### Install wrapper scripts

The first is a wrapper around LXD that sets LD_LIBRARY_PATH

```bash
DEST=/usr/local/lxd
sudo echo -n; curl -s https://raw.githubusercontent.com/muir/drbd-lxd/main/lxdwrapper.sh | sudo tee $DEST/lxdwrapper.sh
sudo chmod +x $DEST/lxdwrapper.sh
for i in $DEST/bin/*; do sudo ln -s $DEST/lxdwrapper.sh /usr/local/bin/`basename $i`; done
```

The second switches betwen multiple LXD installations since you need separate LXD metadata
for each drbd partition.

If you have more than one DRBD partition, do this multiple times...

```bash
fs=r0
sudo echo -n; curl -s https://raw.githubusercontent.com/muir/drbd-lxd/main/fswrapper.sh | sudo tee /usr/local/bin/$fs
sudo chmod +x /usr/local/bin/$fs
```

## Set up LXD

The following is loosely derived from the systemd files that are part of the Ubuntu 18.04 lxd package.  Do this
for each drbd filesytem.

```bash
mkdir /var/log/lxd

fs=r0
sudo echo -n; cat << END | sudo tee /etc/systemd/system/"$fs"lxd.service
[Unit]
Description=${fs} LXD - main daemon
After=network-online.target openvswitch-switch.service lxcfs.service
Requires=network-online.target lxcfs.service
ConditionPathExists=/${fs}/lxd
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
END

mkdir /$fs/lxd
systemctl start "$fs"lxd
```

### Initialize LXD

Override defaults for storage pools: do not create one.
Override defaults for networks.  If you let lxd "use" a network then
it will want to manage it with DHCP and NAT.  For people who want to
manage their own network with static IPs this is a bad thing.
Do not create a new local network bridge.

```bash
$fs lxd init
Would you like to use LXD clustering? (yes/no) [default=no]:
Do you want to configure a new storage pool? (yes/no) [default=yes]: no
Would you like to connect to a MAAS server? (yes/no) [default=no]:
Would you like to create a new local network bridge? (yes/no) [default=yes]: no
Would you like to configure LXD to use an existing bridge or host interface? (yes/no) [default=no]: yes
Name of the existing bridge or host interface: enp0s3
Would you like LXD to be available over the network? (yes/no) [default=no]:
Would you like stale cached images to be updated automatically? (yes/no) [default=yes]
Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]:
```

Then create the storage pool manually:

```bash
drbd=0
sudo btrfs subvolume create /${fs}/pools
echo "/dev/drbd$drbd /$fs/pools btrfs rw,noauto,relatime,space_cache,subvol=/pools,ssd 0 0 " | sudo tee -a /etc/fstab
sudo $fs lxc storage create ${fs} btrfs source=/${fs}/pools
```

### DRBD watcher script

Rather than using a keep alive daemon of some sort, we'll simply monitor the
DRBD status.

#### Watcher

Install [drbd-watcher](https://github.com/muir/drbd-watcher), a small program
that invokes scripts to react to changes in DRBD status.

#### Fencing

Fencing is an important concept with two-node failover.  In normal operation,
the systems run in master/slave mode with data writes returning only when the data
has been written to both systems.

If one system is down, the other can run.  At this point the other system becomes
out-of-sync and stale, but since it's down, it doesn't know that it's stale.

When the stale system comes up, if it cannot reach the other system, it doesn't
know if it's safe to become the master.  If it were to become master, the data
would diverge in a way that cannot be automatically resolved since the data is a
filesystem.

Fencing is how the stale system can tell if it is safe to start: when a system
is running all by itself, it must create a "fence" that stops the other
system from becoming master.  This fence must be somewhere that both systems can
access even if the other system is down.

Install a script to manage fencing.  This can be implemented in many ways. The key
thing is to use **external** storage that is highly reliable.  External means: not
on the systems that need to be fenced from each other.

Fencing only needs to lock the resource when there is a disconnected primary.

Commands should be:

- `lock $RESOURCE`
- `unlock $RESOURCE`

Where `$RESOURCE` should be unique in your lock script and storage and
tied to your DRBD resource.  For lock storage that is used just by a
pair of systems, this can be just the resource identifier (eg `"r0"`).
Status can be returned by the exit code: 0 for success, 1 for failure.

__This__ fencing script uses Google cloud storage.  If you don't like that, pick
a different external storage system and write a trivial script to access it.  I suggest
using a google account for this that is only used for this.

Install [gsutil & gcloud](https://cloud.google.com/storage/docs/gsutil_install#deb)

Run `gcloud init` as root since it will be root that's needing to access the resources.

Install the script:

```bash
sudo echo -n; curl -s https://raw.githubusercontent.com/muir/drbd-lxd/main/drbd-fence.sh | sudo tee /usr/local/bin/drbd-fence
sudo chmod +x /usr/local/bin/drbd-fence
```

Test it:

```bash
/usr/local/bin/drbd-fence unlock r0
/usr/local/bin/drbd-fence lock r0
/usr/local/bin/drbd-fence unlock r0
```

Initialize the fence by unlocking each resource.

#### Reaction script

Install a script to react to changes in DRBD status.  The danger with such a script
is having some kind of fencing so that if you have only one node up and then bring it
down and then bring up the other node.

```bash
sudo echo -n; curl -s https://raw.githubusercontent.com/muir/drbd-lxd/main/drbd-react.sh | sudo tee /usr/local/bin/drbd-react
sudo chmod +x /usr/local/bin/drbd-react
```

#### Run the script on boot and keep it running

This seems to be the core of systemd...

```bash
sudo echo -n; cat << END | sudo tee /etc/systemd/system/drbd-watcher.service
[Unit]
Description=Monitor DRBD for changes

[Service]
ExecStart=/usr/local/bin/drbd-watcher /usr/local/bin/drbd-react
Restart=always
RestartSec=300

[Install]
WantedBy=default.target
END

sudo systemctl enable drbd-watcher
sudo systemctl start drbd-watcher
sudo systemctl status drbd-watcher
```

## Using LXD

We'll need a container for the next bit of setup, so either create a fresh
one or convert one from a prior setup.

Finding good documentation on the structure of a container has proved somewhat
challenging.  
[Stéphane Graber](https://stgraber.org/2016/03/30/lxd-2-0-image-management-512/)
has the best I've found so far.

### Create a container

Confusingly, the LXD client is called `lxc`.  Yeah, that's the same name as the
underlying container system that LXD is built on top of.  And yes, the LXC has
a command line too.o

In any case, there are
[instruction here](https://linuxcontainers.org/lxd/getting-started-cli/#lxd-client)

If you don't trust pre-built images made by strangers, you can use
a Go program made by strangers, [distrobuilder](https://github.com/lxc/distrobuilder)
to build your container images.

### Convert an OpenVZ container

Assuming you have a private (root) directory of an OpenVZ container in `rootfs`:

```bash
sudo su
rm -r rootfs/dev rootfs/proc
mkdir rootfs/dev rootfs/proc
echo "# unconfigured" > rootfs/etc/fstab

cat rootfs/etc/lsb-release

epoch=`perl -e 'print time'`
source rootfs/etc/lsb-release
hn=`cat rootfs/etc/hostname`
cat > metadata.yaml <<END
architecture: x86_64
creation_date: ${epoch}
properties:
  description: legacy "${hn}" -- ${DISTRIB_DESCRIPTION}
  os: ${DISTRIB_ID}
  release: ${DISTRIB_CODENAME} ${DISTRIB_RELEASE}
END
cat metadata.yaml

container=dns
tar czf "$container"image.tgz metadata.yaml rootfs
fs=r0
$fs lxc image import "$container"image.tgz --alias "$container"image
$fs lxc launch "$container"image "$container" -s $fs
$fs lxc image delete "$container"image
```

The metadata properties are optional.
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

### Monitoring

The drbd-watcher script installed earlier should take care of most normal failover
situations.  It doesn't handle absolutely everything and cannot resolve a some
split-brain problems.

The watcher script is relatively slow compared to most HA setups.  Let's pair it with
something even slower: a script that send emails whenever the DRBD status changes.
This will run out of crontab.

```bash
sudo apt install libfile-slurper-perl libmail-sendmail-perl
curl -s https://raw.githubusercontent.com/muir/drbd-lxd/main/drbd-status-emailer.pl | sudo tee /usr/local/bin/drbd-status-emailer
sudo chmod +x /usr/local/bin/drbd-status-emailer

sudo echo -n; (sudo crontab -l; cat <<END) | sudo crontab -
*/4             *       * * * /usr/local/bin/drbd-status-emailer
59              0       * * * /usr/local/bin/drbd-status-emailer noisy
END
```

### What else is needed?

Other things that are needed to really complete the setup are:

- backups
- synchronization script between the two hosts
- monitoring/paging to let you know if something is down
- remote recovery (see PXEboot section below)

### Bonding ethernets for reliability and capacity

Often in a DRBD setup, there will be a private cross-over cable
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

### CARP

While we don't need an additional high-availability solution for DRBD/LXD
setup, there are other services that might need a solution.  For example,
it's probably better to run OpenVPN on the main servers rather than trying
to put it inside a container.

```bash
apt install ucarp
```

### PXE boot

PXE boot so that if one system goes down, you can use the other one to
help fix it.  There are many ways to do this.  The easiest is to use
tftp to serve a pxelinux that boots using a ramdisk loaded over http.

```bash
sudo apt install atftpd openbsd-inetd micro-httpd isc-dhcp-server
```

Turn off serving on port 80.  Why does anything think that installing an unconfigured
web server is a good idea?
Since nobody uses gopher anymore, that's a fine port for serving /tftpboot files

```bash
sudo perl -p -i -e 's/^(www\s)/#$1/' /etc/inetd.conf
sudo perl -p -i -e 'm/^tftp/ && s,\s/srv/tftp$, /tftpboot,' /etc/inetd.conf
sudo perl -p -i -e '/^tftp\s/ && print "gopher	stream	tcp	nowait	nobody	/usr/sbin/tcpd /usr/sbin/micro-httpd /tftpboot\n"' /etc/inetd.conf
sudo service openbsd-inetd restart
```

Build a /tftpboot

#### Base /tftpboot

```bash
sudo apt install pxelinux syslinux-common
sudo cp /usr/lib/PXELINUX/pxelinux.0 /tftpboot/
sudo mkdir -p /tftpboot/pxelinux.cfg /tftpboot/menus
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /tftpboot

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

sudo chmod -R a+r /tftpboot
```

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

You also need to [configure your DHCP server](https://help.ubuntu.com/community/DisklessUbuntuHowto).
Note: follow the instructions there just for DHCP setup.  You won't need NFS.

There are also decent DHCP server setup instructions in
`/usr/share/doc/syslinux-common/asciidoc/pxelinux.txt.gz`

## Other recipes

[Here](https://www.thomas-krenn.com/en/wiki/HA_Cluster_with_Linux_Containers_based_on_Heartbeat,_Pacemaker,_DRBD_and_LXC)
is a similar recipe.  The main difference is that it uses a java-based
graphical user interface to control things.

[Here](https://petrovs.info/2014/11/28/ha-cluster-with-linux-containers/) is a recipe that uses LXC,
DRBD, and btrfs.  This receipe doesn't include how to do failover.

[Here](https://stgraber.org/) is a recipe for three systems using Ceph.  Includes good hints about how
to use LXD.
