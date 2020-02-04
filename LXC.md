
WORK IN PROGRESS, NOT COMPLETE !!

[January 2020]

## Two-node HA cluster with Ubuntu, DRBD, LXC and CARP

This documents my HA setup.

### Ubuntu

There are really basic choice for your host OS.  Do you use a standard 
distribution or do you use a specialized container distribution?  My goal
here is a choice that will remain valid for the next 15 years.  Since
I was previously burned by openvz on Debian, I'm shying away from specialty
distributions.

Of the mainstream distributions, I have a personal preference for Ubuntu.
I'm pretty sure it will be around for a while.

### LXC instead of LXD

LXD is a daemon that manages LXC.  The command line for LXD is much
nicer than the LXC command lines (`lxc-utils`).  Further LXD adds
extra security in the form of Apparmour.

Some peole say [LXD is safer](https://github.com/lxc/lxd/issues/2771#issuecomment-269926348).
However others state,
[With such container, the use of SELinux, AppArmor, Seccomp and capabilities isn't necessary for security](https://linuxcontainers.org/lxc/security/#unprivileged-containers)

When using DRBD, the container image and configuration can't be in the default
location.  With LXD, moving the container to a new directory and replacing it with
a symlink did not work. With LXC, it did.

LXD keeps its configuration in a database that makes it much harder to have the
configuration change when filesystems are mounted/unmounted.

RANT:ON

Dispite choosing LXC, I have to say: lxc is awful.  You need recipes to do anything.
The commands are inconsistent.  Nobody's recipes work because they all expect
things to be slightly different.  The LXC official site documents the current LXC
version but there doesn't seem to be any resources for people running the stable
version of LXC. Everything seems to be opinionated but with crappy opinions.  For
example, the defaults all expect containers to get their IP addresses via DHCP and
to be NAT'ed. If I wanted unreachable containers, I would use docker.  Openvz 
configuration is simpler and the commands are nicer.

RANT:OFF

### DRBD

There aren't a lot of choices for a shared-nothing HA setup.  
(DRDB)[https://help.ubuntu.com/lts/serverguide/drbd.html] provides over-the-network
mirroring of raw devices.  It can be used as the block device for most filesytems.

Alternatively, there are a few distributed filesystems: 
- [BeeGFS](https://www.beegfs.io/content/) - free but not open source;
- [Ceph](https://docs.ceph.com/docs/mimic/) - [requires an odd number of monitor nodes](https://technologyadvice.com/blog/information-technology/ceph-vs-gluster/);
- [Gluster](https://www.gluster.org/) - "Step 1 – Have at least three nodes";
- [XtreeemFS](http://www.xtreemfs.org/) - [poor performance](https://www.slideshare.net/azilian/performance-comparison).

None of those are performant, open source, and support a two-node configuration.

I used DRBD in my previous setup and while it's a bit complicated to set up,
it proved itself to be quite reliable.  And quick.

### CARP

There are a couple of alternatives:
- [VRRP (keepalived)](https://www.keepalived.org/);
- [Heartbeat/Pacemaker](http://linux-ha.org/wiki/Pacemaker).

Heartbeat is quite complicated.  I may try keepalived in the future.  Carp
(`ucarp`) is simple.  The issue I have with it is that it switches too easily
and does not have a command line for manual switchover.

### Container storage

LXC supports many ways to configure the storage for your containers.
If you want snapshotting capability then you need to run on top of LVM
or use ZFS or btrfs.  That's useful.

[ZFS doesn't seem to play well with DRBD](http://cedric.dufour.name/blah/IT/ZfsOnTopOfDrbd.html)
so that's out.

[At least one person](https://petrovs.info/2014/11/28/ha-cluster-with-linux-containers/)
uses btrfs with DRBD and doesn't think it's a terrible idea.

In the past, I used ext4 directly on top of drbd.  For this build, I'll use LVM on
top of DRBD because that will provide flexibility to change my mind later.

We'll also give btrfs a try (on top of LVM, on top of DRBD.)

## Recipe

After install Ubuntu 18.04 Server...

```bash
sudo apt update
sudo apt upgrade
sudo apt install lxc-utils 
sudo dpkg --purge lxd
sudo dpkg --purge lxd-client
sudo apt install drbd-utils 
```

This will ask configuration questions for `postfix` so be prepared to answer about
your mail setup.

LXC defaults to priviledged containers even though they're not secure.
The [documentation](https://www.cyberciti.biz/faq/how-to-create-unprivileged-linux-containers-on-ubuntu-linux/)
shows how to allow non-priviledged users to run LXC containers.

We'll put the home directory of the LXC user on the DRBD volume(s) so first
we have to set up DRBD.


We'll create a user for each DRBD volume to run all the containers.  Kinda ugly.
Anyone got a better solution?

```bash
FS=/x
for dir in 0; do 
	U=vc$dir
	sudo adduser --disabled-password --system --group $U -b $FS --shell /bin/bash $U
	sudo usermod --add-subgids `awk -F : '{print $2 + 65536 "-" $2 + 131071}' /etc/subgid | sort -rn | head -1` $U
	sudo usermod --add-subuids `awk -F : '{print $2 + 65536 "-" $2 + 131071}' /etc/subuid | sort -rn | head -1` $U
	echo "$U veth lxcbr0 200" | sudo tee -a /etc/lxc/lxc-usernet
	sudo -u $U mkdir -p $FS$dir/$U/.config/lxc
	sudo -u $U ln -s .config/lxc $FS$dir/$U/config
	sudo -u $U ln -s .local/share/lxc $FS$dir/$U/containers
	sudo -u $U cp /etc/lxc/default.conf $FS$dir/$U/.config/lxc
	(
		echo lxc.include = /etc/lxc/default.conf
		awk -F : "/^$U"':/{print "lxc.idmap = u 0 " $2 " 65536"}' /etc/subuid 
		awk -F : "/^$U"':/{print "lxc.idmap = g 0 " $2 " 65536"}' /etc/subgid
	) | sudo -u $U tee $FS$dir/$U/.config/lxc/default.conf
done
```

Let's double check some things.   Learned from [here](https://myles.sh/configuring-lxc-unprivileged-containers-in-debian-jessie/)
```bash
sysctl -a|&grep userns_clone
```

This should respond with: `kernel.unprivileged_userns_clone = 1`.  If it doesn't then add
that line to `/etc/sysctl.d/80-lxc-userns.conf`.

## Add-ons

These are recommended extras

### PXE boot 

PXE boot so that if one system goes down, you can use the other one to
help fix it.

```bash
apt install dnsmasq
```

### distrobuilder

If you don't trust pre-built images made by strangers, you can use
a Go program made by strangers, [distrobuilder](https://github.com/lxc/distrobuilder)
to build your container images.

### Convert openvz containers

### KVM

## Other resources

[Here](https://www.thomas-krenn.com/en/wiki/HA_Cluster_with_Linux_Containers_based_on_Heartbeat,_Pacemaker,_DRBD_and_LXC)
is a similar recipe.  The main difference is that it uses a java-based
graphical user interface to control things.  That's not my cup of tea.

[Here](https://petrovs.info/2014/11/28/ha-cluster-with-linux-containers/) is a recipe that uses LXC,
DRBD, and btrfs.  This receipe doesn't include how to do failover.

## Docker

## Routable addresses for containers

Make sure that forwarding is turned on:

```bash
sysctl -a  |& grep forwarding|grep -v mc_forward | grep -v 'forwarding = 1'
```

Turn off LXC normal bridge:

```bash
sudo perl -p -i -e 's/^[^#]/##/' /etc/default/lxc-net
sudo perl -p -i -e 's/^USE_LXC_BRIDGE="false"/USE_LXC_BRIDGE="false"/' /etc/default/lxc
```

Switch back to `/etc/network/interfaces` (optional)

```bash
sudo apt install ifupdown
```

Set up a bridge interface.  
There are many different sets of instructions for doing this.  The
instructions 
[here](https://wiki.debian.org/LXC/SimpleBridge) gave good hints.
The instructions 
[here](https://askubuntu.com/questions/231666/how-do-i-setup-an-lxc-guest-so-that-it-gets-a-dhcp-address-so-i-can-access-it-on) did not.

For example (requires customization to your situation):

```bash
cat <<END | sudo tee /etc/network/interfaces
auto lo
iface lo inet loopback

auto enp0s3
iface enp0s3 inet dhcp

auto lxcbr0
iface lxcbr0 inet static
	address 172.20.10.2/24
	bridge_ports enp0s8
	bridge_fd 0
	bridge_maxwait 0

END
```

Add to your LXC configuration file:

```
# Network configuration
lxc.net.0.type = veth
lxc.net.0.ipv4.address = 172.20.10.33/24
lxc.net.0.ipv4.gateway = 172.20.10.2
lxc.net.0.link = lxcbr0
lxc.net.0.name = eth0
```

Inside the container, change the network configuration for `eth0` to be `manual`.

### Easier import of root trees

curl https://raw.githubusercontent.com/muir/drbd-lxc-carp/master/lxc-directory | \
	sudo tee /usr/share/lxc/templates/lxc-directory

## Install these tools

```bash
sudo add-apt-repository ppa:gophers/archive
sudo apt-get update
sudo apt-get install golang-1.13-go
```

