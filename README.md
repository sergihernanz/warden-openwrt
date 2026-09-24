# social-firewall

A parental-control firewall for OpenWRT (`fw4`/nftables). Configure, per **MAC
address**, whether a device:

- has a named service (Instagram, TikTok, YouTube, ...) **blocked** outright,
- gets a **daily/weekly time budget** for a service (e.g. 30 min/day of
  YouTube), or
- is restricted to a **schedule** (e.g. only 08:00-20:00) for internet access
  as a whole.

Configured through a LuCI page (**Network > Kids Firewall**) backed by UCI.
See [ARCHITECTURE.md](ARCHITECTURE.md) for how it actually enforces this and
the tradeoffs/limitations involved — read it before deploying, especially
the "known limitations" section.

## Packages

- **`kidsfirewall`** — the backend: UCI schema, nftables ruleset generator,
  the schedule/budget enforcement daemon, dnsmasq integration.
- **`luci-app-kidsfirewall`** — the web UI, depends on `kidsfirewall`.

## Requirements

- OpenWRT 22.03+ with `fw4` (nftables) — this targets nftables directly, not
  iptables/fw3.
- Default flat `br-lan` bridge for your LAN (MAC-address matching needs the
  ethernet frame to survive to the `forward` hook — true for the common
  single-bridge setup, not guaranteed if kids' devices are on a separate
  routed VLAN/subnet).
- **`dnsmasq-full`**, not the minimal `dnsmasq` package OpenWRT ships by
  default — the default build is compiled *without* `nftset=`/`ipset=`
  support, and **both block and budget rules depend on it** (enforcement is
  nft-only, keyed off destination IPs dnsmasq populates via `nftset=`; there
  is no DNS-level fallback — see ARCHITECTURE.md for why). Check with
  `dnsmasq --version` (look for `nftset` vs `no-nftset` in "compile time
  options"); swap with `opkg remove dnsmasq && opkg install dnsmasq-full`.
  Without it, rules do nothing unless you manually populate a static CIDR
  per service. `kidsfirewall-genrules` detects support automatically and
  skips `nftset=` generation rather than writing something dnsmasq can't
  parse (an unparseable directive here previously took down DNS for the
  whole LAN, not just kidsfirewall-managed devices — fixed).

## Building

This is laid out as an OpenWRT package feed (`package/kidsfirewall`,
`package/luci-app-kidsfirewall`). Two ways to build it:

**As a custom feed**, alongside the official OpenWRT/LuCI source in an
OpenWRT buildroot:

```sh
# from your openwrt buildroot checkout
echo "src-link socialfirewall /path/to/social-firewall/package" >> feeds.conf.default
./scripts/feeds update socialfirewall
./scripts/feeds install kidsfirewall luci-app-kidsfirewall
make menuconfig   # enable Network > kidsfirewall, LuCI > Applications > luci-app-kidsfirewall
make package/kidsfirewall/compile package/luci-app-kidsfirewall/compile V=s
```

**Using the SDK** (faster than a full buildroot if you're not changing
kernel/base packages): download the SDK matching your router's target from
the OpenWRT downloads page, then point its own `package/` feed setup at
this repo's `package/` directory the same way (symlink or `src-link`), and
run the same `feeds`/`make package/.../compile` steps inside the SDK tree.

Either way, the resulting `.ipk` files land under
`bin/packages/<arch>/socialfirewall/`. Copy them to the router and install:

```sh
scp -O kidsfirewall_*.ipk luci-app-kidsfirewall_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/kidsfirewall_*.ipk /tmp/luci-app-kidsfirewall_*.ipk'
```

(`-O` forces the legacy scp protocol — modern OpenSSH defaults to SFTP, which
OpenWRT's dropbear SSH daemon doesn't support; see DEBUG_INSTALL.md if this
still fails.)

Since both packages are `PKGARCH:=all` (no compiled code), you don't
actually need the SDK just to try this on one router — see
[DEBUG_INSTALL.md](DEBUG_INSTALL.md) for a copy-the-files-over-SSH
shortcut, [DEBUG_UNINSTALL.md](DEBUG_UNINSTALL.md) to reverse it, and
[DEBUG_AUDIT.md](DEBUG_AUDIT.md) for the exhaustive list (+ commands) of
everything this package changes on the router, useful for verifying the
install or tracking down unexpected behavior.

## Usage

1. Open **Network > Kids Firewall** in LuCI.
2. Add a **Device**: a friendly name + MAC address. The MAC field suggests
   devices the router already knows about (hostname/IP shown alongside) —
   click one, or type a MAC manually if yours isn't listed (can happen for
   an IPv6-only device the router hasn't resolved a link-layer address
   for yet; check `ip -6 neighbor show` on the router, or look for the
   same device's IPv4 lease instead). Note some phones/laptops use a
   randomized "Private Wi-Fi Address" per network by default, which is
   what actually needs to go here, not necessarily the hardware MAC
   printed on the device — and it can rotate over time.
3. (Optional) Add/edit **Services** — a handful of common ones ship by
   default (Instagram, TikTok, YouTube, Facebook, Snapchat, Roblox, Twitch,
   Netflix), each just a name + list of domains.
4. Add a **Rule**: pick the device, a mode, and the relevant fields:
   - `Block`: pick a service. Always blocked for that device.
   - `Time budget`: pick a service + a minute limit + daily/weekly reset.
   - `Schedule`: pick allowed hours (`start`/`stop`) and, optionally, which
     days it applies to (empty = every day). Applies to the whole device,
     not a single service.
5. (Optional) **Safe DNS**: pick a filtered upstream DNS provider
   (CleanBrowsing, OpenDNS FamilyShield, Cloudflare for Families, or a
   custom resolver) to filter adult content for the *whole network*,
   independent of the per-device rules above. If the page shows a warning
   that it's drifted from what's actually configured (e.g. someone edited
   DHCP/DNS settings directly), use the "Reapply now" button.
6. **Save & Apply**.

Command-line equivalent: edit `/etc/config/kidsfirewall` directly, then
`/etc/init.d/kidsfirewall reload` (or just `uci commit kidsfirewall` if
you're going through LuCI/ucitrack).

Debugging: `logread | grep kidsfirewall` for the ruleset generator and
monitor daemon's own log lines, `nft list table inet kidsfirewall` to
inspect the live ruleset/sets/counters, `nft list counter inet kidsfirewall
usage_<device>_<service>` to see raw traffic counts feeding a budget,
`cat /var/run/kidsfirewall/safe_dns_status` for the Safe DNS drift check.

## What this deliberately does not do yet

- True SNI/TLS-hostname (DPI) matching — see ARCHITECTURE.md's "Why not
  real SNI/DPI matching yet" section for the reasoning and the planned
  `kidsfirewall-snisniff` follow-up.
- Any protection against a technically-savvy kid who changes their device's
  MAC address, or points it at an external DNS-over-HTTPS resolver, unless
  you populate the optional static-CIDR backstop per service.
