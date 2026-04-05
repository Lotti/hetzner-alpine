# Alpine Linux on Hetzner Cloud VPS

(x86_64 / IPv4 + IPv6 / Dokploy-ready)

This guide describes how to install Alpine Linux on a Hetzner Cloud x86_64 VPS that is not supported out of the box, bring up static IPv4 and IPv6 networking, and prepare the host for Dokploy on a single-node setup.

At the time of writing, the current Alpine stable release is `3.23.3` (released January 27, 2026). The commands below use the `x86_64` virtual ISO for that release.

![image](https://gist.github.com/assets/6292788/959b8293-4347-48af-a7a5-7e24ae281690)

**Table of contents:**
- [Introduction](#introduction)
- [Installation](#installation)
- [Post-installation](#post-installation)
  - [Packages](#packages)
  - [Network](#network)
  - [DNS](#dns)
  - [SSH](#ssh)
  - [Grub](#grub)
  - [NTP](#ntp)
  - [Bash](#bash)
  - [fail2ban](#fail2ban)
  - [Firewall](#firewall)
  - [Docker](#docker)
  - [Dokploy compatibility](#dokploy-compatibility)
  - [Validation](#validation)
- [Optional extras](#optional-extras)
  - [Build essentials](#build-essentials)
  - [Coreutils](#coreutils)

## Introduction

Hetzner Cloud boots in EFI mode, so a custom Alpine installation needs a small workaround. The reliable path is:

1. Boot the server into Hetzner Rescue.
2. Write the Alpine `virt` ISO directly to disk.
3. Boot the ISO from the local disk.
4. Move the modloop contents into place and run `setup-alpine`.
5. Configure Hetzner's dual-stack static network manually after installation.

This guide targets a public dual-stack server with:

- one primary public IPv4 address
- one routed `/64` IPv6 subnet
- one NIC (`eth0`)
- Docker and Traefik on the host
- a Dokploy-compatible deploy target, managed by Dokploy from another server

## Installation

Reboot the server into [Hetzner Rescue](https://docs.hetzner.com/cloud/servers/getting-started/rescue-system/).

Log into the Rescue system over either address family:

```bash
ssh root@YOUR_SERVER_IPV4
ssh root@[YOUR_SERVER_IPV6]
```

Write the current Alpine `virt` ISO to disk. Replace `/dev/sda` if your server uses a different disk name.

```bash
export ALPINE_BRANCH="v3.23"
export ALPINE_VERSION="3.23.3"
export DISK="/dev/sda"

wipefs -a "${DISK}"
wget "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso"
dd if="alpine-virt-${ALPINE_VERSION}-x86_64.iso" of="${DISK}" bs=4M status=progress oflag=sync
reboot
```

Open the Hetzner server console, log in as `root` with no password, and prepare the live system so `setup-alpine` can install to disk:

```bash
cp -r /.modloop /root
cp -r /media/sda /root
umount /.modloop /media/sda
rm -rf /lib/modules
mv /root/.modloop/modules /lib
mv /root/sda /media
setup-alpine
```

Suggested answers during `setup-alpine`:

- Keyboard layout: your preference
- Hostname: your preferred hostname
- Interface: `eth0`
- DHCP: `none`
- Manual network configuration: `yes`
- DNS domain: leave empty
- DNS server: temporarily use `1.1.1.1`
- SSH server: `openssh`
- Disk: `sda` or your actual disk
- Install mode: `sys` or `lvmsys`

After the installer finishes, reboot into the installed system and log in as `root`.

## Post-installation

Useful references:

- [Alpine post installation](https://wiki.alpinelinux.org/wiki/Post_installation)
- [Hetzner static IP configuration](https://docs.hetzner.com/cloud/servers/static-configuration/)
- [Dokploy manual installation](https://docs.dokploy.com/docs/core/manual-installation)

### Packages

Make sure both `main` and `community` are enabled for the installed Alpine branch. On Alpine `3.23.x`, `/etc/apk/repositories` should contain entries like:

```text
https://dl-cdn.alpinelinux.org/alpine/v3.23/main
https://dl-cdn.alpinelinux.org/alpine/v3.23/community
```

Update the system and install a useful baseline:

```bash
apk update
apk upgrade
apk add bash bash-completion bind-tools ca-certificates curl git htop jq lsof nano procps shadow sudo tcpdump unzip vim wget iptables ip6tables iproute2-minimal iproute2-ss
update-ca-certificates
```

### Network

Hetzner Cloud dual-stack servers work well with a static `ifupdown` configuration. Edit `/etc/network/interfaces`:

```text
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address YOUR_PUBLIC_IPV4/32
    gateway 172.31.1.1
    pointopoint 172.31.1.1

iface eth0 inet6 static
    address YOUR_SERVER_IPV6/64
    gateway fe80::1
```

Notes:

- `YOUR_PUBLIC_IPV4` is the primary public IPv4 assigned by Hetzner.
- `YOUR_SERVER_IPV6` is one usable address from your routed `/64`, for example `2001:db8:1234:5678::1`.
- Keep the IPv4 gateway exactly as `172.31.1.1`.
- Keep the IPv6 gateway exactly as `fe80::1`.

Restart networking and verify both stacks:

```bash
rc-service networking restart
ip -4 addr show dev eth0
ip -4 route
ip -6 addr show dev eth0
ip -6 route
```

### DNS

For a dual-stack host, use both IPv4 and IPv6 resolvers:

```bash
cat <<'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 2606:4700:4700::1111
nameserver 2606:4700:4700::1001
EOF
```

Quick checks:

```bash
ping -4 -c 1 1.1.1.1
ping -6 -c 1 2606:4700:4700::1111
getent hosts github.com
```

### SSH

OpenSSH on Alpine normally listens on both IPv4 and IPv6 by default, so no change is required unless you want to be explicit.

If you want to pin both listeners in `/etc/ssh/sshd_config`, add:

```text
ListenAddress 0.0.0.0
ListenAddress ::
```

Then restart SSH:

```bash
rc-service sshd restart
```

### Grub

If the Hetzner console is too quiet during boot, add `console=tty1` to the default kernel arguments.

Edit `/etc/default/grub`:

```text
GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 modules=sd-mod,usb-storage,ext4 rootfstype=ext4"
```

Then rebuild the boot config:

```bash
update-grub
```

### NTP

Install and enable `chrony`:

```bash
apk add chrony
rc-update add chronyd default
rc-service chronyd start
chronyc sources
```

### Bash

```bash
apk add bash bash-completion
chsh -s /bin/bash root
echo "PS1='[\u@\[\033[01;34m\]\h\[\033[00m\]:\w]\\$ '" > /root/.bash_profile
```

### fail2ban

Optional but recommended:

```bash
apk add fail2ban
sed -i 's/#allowipv6 = auto/allowipv6 = auto/' /etc/fail2ban/fail2ban.conf
rc-update add fail2ban default
rc-service fail2ban start
```

Default SSH jail location:

```text
/etc/fail2ban/jail.d/alpine-ssh.conf
```

### Firewall

For a single-node Dokploy deploy target, open only:

- `22/tcp` for SSH
- `80/tcp` for HTTP and ACME HTTP challenge
- `443/tcp` and `443/udp` for HTTPS and HTTP/3

Example host firewall rules:

```bash
iptables -F
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT

ip6tables -F
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p tcp -m multiport --dports 22,80,443 -j ACCEPT
ip6tables -A INPUT -p udp --dport 443 -j ACCEPT
```

Save and enable both services:

```bash
/etc/init.d/iptables save
/etc/init.d/ip6tables save
rc-update add iptables default
rc-update add ip6tables default
rc-service iptables start
rc-service ip6tables start
```

If you later turn this into a multi-node swarm, also allow:

- `2377/tcp`
- `7946/tcp`
- `7946/udp`
- `4789/udp`

### Docker

Install Docker with OpenRC integration:

```bash
apk add docker docker-cli-compose
rc-update add docker default
rc-service docker start
docker info
docker version
```

If `docker info` fails right after boot, wait a few seconds and run it again. Dokploy depends on a healthy local Docker daemon and an initialized swarm manager.

### Dokploy compatibility

This repository includes [`dokploy-script.sh`](./dokploy-script.sh), adapted for Alpine so the host can be prepared as a Dokploy deploy target on Hetzner.

Before running it:

- keep ports `80` and `443` free
- make sure the host already has working IPv4 and IPv6
- create both `A` and `AAAA` DNS records for any domains that Traefik should serve
- use the server's primary public IPv4 for `ADVERTISE_ADDR`

Export the advertise address and run the script as `root`:

```bash
chmod +x ./dokploy-script.sh
export ADVERTISE_ADDR="$(ip -4 -o addr show dev eth0 scope global | awk '{split($4,a,\"/\"); print a[1]; exit}')"
./dokploy-script.sh
```

What the script prepares:

- Docker dependencies on Alpine
- Docker daemon startup on OpenRC
- Docker Swarm manager initialization
- the `dokploy-network` overlay network
- Traefik and Dokploy filesystem layout under `/etc/dokploy`
- build tooling such as RClone, Nixpacks, Buildpacks, and Railpack

Keep in mind:

- the recommended default is still a public IPv4 `ADVERTISE_ADDR`
- published apps can be reached over both IPv4 and IPv6 as long as DNS points both records at the server
- this script does not install the Dokploy web UI or its backing services
- if you want Traefik to request Let's Encrypt certificates on this host, export `LETSENCRYPT_EMAIL=you@example.com` before running the script

### Validation

After the network and Docker setup, verify the host:

```bash
ip -4 route get 1.1.1.1
ip -6 route get 2606:4700:4700::1111
ping -4 -c 1 github.com
ping -6 -c 1 github.com
docker info
docker network ls | grep dokploy-network
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ss -tulpen | grep -E ':(80|443)\b'
```

On a healthy Dokploy-ready host you should see:

- IPv4 and IPv6 routes present
- SSH reachable on both families
- Docker running
- Swarm active
- `dokploy-network` created
- Traefik binding `80/tcp`, `443/tcp`, and `443/udp`

`3000/tcp` should stay free on this host unless you choose to run a separate service there.

Reboot once after everything is in place and re-run the same checks. Docker, networking, and Traefik should all survive a reboot cleanly.

## Optional extras

### Build essentials

```bash
apk add autoconf automake bison binutils build-base cargo cmake flex libtool m4 patch pkgconfig
```

### Coreutils

If you need GNU coreutils instead of the BusyBox-provided versions:

```bash
apk add coreutils utmps
setup-utmp
```

If you want a `w` replacement in Bash:

```bash
echo "alias w='uptime && who -a'" >> /root/.bash_profile
```
