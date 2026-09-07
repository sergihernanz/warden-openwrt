# Architecture

## Goal

An OpenWRT package pair (`kidsfirewall` + `luci-app-kidsfirewall`) that lets a
parent, per **MAC address**, configure:

1. **Block** — a named service (Instagram, TikTok, ...) is always blocked.
2. **Budget** — a named service is allowed for up to N minutes per day (or week),
   then blocked until the period resets.
3. **Schedule** — the device may reach the internet only during allowed
   time windows (e.g. 08:00-20:00), any day-of-week subset.

Target: OpenWRT 22.03+ with the `fw4`/nftables firewall (per user choice).
Configuration: LuCI web UI (per user choice), backed by UCI.
Enforcement: nftables, keyed off destination IPs dnsmasq populates from DNS
lookups (`nftset=`) as the primary path, with an optional static-CIDR
backstop (per user choice — see "Why not real SNI/DPI yet" below).

## Why a separate nftables table instead of fw4 includes

`fw4` owns a single table (`inet fw4`) that it fully regenerates on every
`fw4 reload` / `/etc/init.d/firewall reload`. Piggybacking on fw4's
`config include` mechanism (which differs across firewall4 versions, and
whose only well-documented extension points are the `input_rule` /
`forward_rule` / ... user chains) is fragile to depend on for a third-party
package.

Instead, `kidsfirewall` creates and owns its **own nftables table**,
`inet kidsfirewall`, with base chains hooked into `forward` at a priority
*below* fw4's (`filter - 5`, i.e. it runs first). This is safe because of how
netfilter evaluates multiple base chains at the same hook: chains run in
priority order, and an `accept`/no-match "falls through" to the next chain at
that hook — only an explicit `drop` stops the packet. So:

- `kidsfirewall`'s chain only ever issues `drop` for traffic it wants to
  block; everything else silently falls through into fw4's own `inet fw4`
  forward chain and is evaluated exactly as it would be today.
- `fw4 reload` does not touch our table at all — it only manages its own.
- We can `nft -f` our own ruleset independently, at our own cadence, without
  restarting or interfering with the rest of the firewall.

## Why MAC-address matching works here

`ether saddr` is only guaranteed to survive to the `forward` hook when the
ingress device is an actual bridged L2 segment — which is exactly OpenWRT's
default single `br-lan` setup. This is documented as a constraint: if a
household splits kids' devices onto a separate routed VLAN/subnet with no
shared bridge, MAC matching in `forward` will not see the original frame's
source MAC reliably. This is called out in the README as a deployment
requirement (default flat `br-lan` LAN).

## Why there's no in-kernel "time of day" rule

nftables has no built-in equivalent of iptables' `xt_time` (`-m time
--timestart --timestop --weekdays`). Rather than depend on a matcher that
doesn't exist in stock nftables, **all time-based logic (schedule windows
and budget accounting) lives in a small userspace daemon**
(`kidsfirewall-monitor`) that runs once per `check_interval` (default 60s)
and only *toggles set membership* — the actual packet-path rules stay dumb
static set lookups. This also means budget accounting (which inherently
needs to accumulate state over time) and schedule enforcement share one
daemon and one state model instead of two different mechanisms.

## Correlating "traffic to service X" with actual packets

We never hardcode IP ranges for a service as the primary mechanism — those
go stale and are easy to get wrong. Instead we lean on a real, existing
dnsmasq feature: **`nftset=`** (the nftables-native equivalent of the older
`ipset=` option). For every service, dnsmasq is told:

```
nftset=/instagram.com/4#inet#kidsfirewall#dest_instagram
nftset=/instagram.com/6#inet#kidsfirewall#dest_instagram6
```

Every time a LAN client resolves `instagram.com` (or any configured
subdomain) through the router, dnsmasq adds the resulting A/AAAA record
directly into our nftables set, with an element timeout matching the DNS
record's own TTL — no polling, no stale entries, no maintenance. Our
firewall rules then just match `ip daddr @dest_instagram`.

This single mechanism backs *both* enforcement modes:

- **Block mode**: `ether saddr @block_instagram ip daddr @dest_instagram drop`
- **Budget accounting**: a `counter` object on a rule matched by
  `ether saddr <device-mac> ip daddr @dest_instagram`, sampled every tick by
  the monitor daemon to accumulate "minutes with observed traffic"

There is deliberately **no per-device DNS-level block** (e.g. answering
`address=/instagram.com/` with NXDOMAIN only for a specific device). An
earlier version tried exactly that, scoped with a dnsmasq `tag:`, and it
took down an actual router: dnsmasq's `address=` directive has **no
tag/client-scoping support at all** (confirmed against the dnsmasq source
and man page) — it can only ever apply globally, to every client, which is
not what "block this service for this kid" means. Using it anyway produced
a config dnsmasq's parser rejected outright, causing it to refuse to start
and crash-loop, breaking DNS resolution for the entire LAN. Enforcement is
now nft-only for both modes — no weaker for it, since the nft rule already
scopes correctly by `ether saddr`, dnsmasq's only job is keeping
`dest_<service>` populated via `nftset=`.

### Why not real SNI/DPI matching yet

The user asked for "both" DNS and SNI-based enforcement. True SNI/DPI
matching in nftables isn't a builtin expression — the realistic way to do it
is `queue` a first-data TCP segment to a small userspace daemon over
`libnetfilter_queue`, parse the TLS ClientHello for SNI, and admit/drop
accordingly (optionally caching the resulting IP into a short-TTL nft set so
subsequent packets on that flow skip re-inspection). That's a real,
buildable design, but it's a meaningfully sized C component with its own
failure modes (TCP segmentation/fragmentation of the ClientHello, ESNI/ECH
where the hostname is encrypted and can't be read at all, etc.), and I did
not want to ship guessed/half-tested C here.

**What ships in v1 as the "backstop" layer instead:** an optional,
admin-populated **static CIDR set** per service (`config service` → `list
cidr`), empty by default, that layers on top of the DNS mechanism for
devices that bypass the router's DNS (e.g. hardcoded DNS-over-HTTPS). It's
not a hallucinated list of "known Instagram IP ranges" — it ships empty, and
the README explains how to populate it from a provider's own published
ranges if you need it.

**Path to real SNI/DPI (v2, not built yet)**: a small package
`kidsfirewall-snisniff` (C, `libnetfilter_queue`), fed by an nftables rule
that queues first-packet TCP/443 traffic from monitored MACs
(`ether saddr @monitored_macs tcp dport 443 ct original packets 0 queue num
100 bypass`), parsing ClientHello SNI extension, and adding matched
destination IPs into the same `dest_<service>` sets nftset already
populates — meaning the rest of the system (block/budget/schedule) needs
zero changes to benefit from it later.

## Components

```
package/
  kidsfirewall/                      backend package
    files/etc/config/kidsfirewall    UCI: global, device, service, rule sections
    files/etc/init.d/kidsfirewall    procd service: generates + loads ruleset,
                                      supervises the monitor daemon
    files/etc/uci-defaults/95-*      first-boot defaults (enables dnsmasq confdir)
    files/usr/sbin/kidsfirewall-genrules   UCI -> nft ruleset + dnsmasq snippet
    files/usr/sbin/kidsfirewall-monitor    schedule + budget enforcement loop
    files/usr/share/kidsfirewall/functions.sh   shared shell helpers
  luci-app-kidsfirewall/             LuCI web UI (JS form.js view over the same UCI config;
                                      no Lua/ucode runtime required — runs client-side, talks
                                      to the router only via ubus/rpcd)
```

## Data model (UCI, config file `kidsfirewall`)

```
config global 'global'
	option enabled '1'
	option check_interval '60'      # seconds between monitor daemon ticks

config device 'kid_tablet'
	option name 'Kid Tablet'
	option mac 'AA:BB:CC:DD:EE:FF'
	option enabled '1'

config service 'instagram'
	option name 'Instagram'
	list domain 'instagram.com'
	list domain 'cdninstagram.com'
	# list cidr '0.0.0.0/0'   # optional static backstop, empty by default

config rule
	option device 'kid_tablet'
	option service 'instagram'       # ignored/must be '' for mode=schedule
	option mode 'budget'              # block | budget | schedule
	option limit_minutes '30'         # mode=budget
	option period 'daily'             # mode=budget: daily | weekly
	option start_time '08:00'         # mode=schedule
	option stop_time '20:00'          # mode=schedule
	list days 'mon' 'tue' 'wed' 'thu' 'fri'   # mode=schedule, default = all days
```

## Known limitations (documented, not silently hidden)

- Requires the flat default `br-lan` bridge; routed/VLAN-isolated kid
  devices won't be caught by `ether saddr` matching.
- DNS-based blocking/accounting only sees traffic whose *DNS lookup* went
  through this router's dnsmasq. A device manually configured with an
  external DoH/DoT resolver bypasses it unless the static CIDR backstop is
  populated, or a device changes its own MAC address.
- Budget accounting has a resolution of `check_interval` (default: 60s) —
  usage is credited in whole-tick increments, not exact seconds.
- No true SNI/DPI matching in v1 (see above) — planned as a follow-up
  package that plugs into the same `dest_<service>` sets.
- **The `nftset=` mechanism requires `dnsmasq-full`, not the minimal
  `dnsmasq` package OpenWRT ships by default** (the default build is
  compiled `no-nftset no-ipset`; feeding it an `nftset=` line it doesn't
  understand makes it refuse to start outright — confirmed by rebuilding
  dnsmasq 2.93 both with and without `-DHAVE_NFTSET` and running `--test`
  against it). `kidsfirewall-genrules` detects support via `dnsmasq
  --version` and skips `nftset=` generation entirely rather than writing a
  directive dnsmasq can't parse. Without it, block/budget rules have
  nothing to match against unless you manually populate a static CIDR per
  service; install `dnsmasq-full` for real functionality.
- **A now-removed earlier version also tried to scope `address=` (DNS
  NXDOMAIN) per device using a dnsmasq `tag:` prefix, for a belt-and-braces
  DNS-level block on top of the nft one.** This doesn't work at all —
  `address=` has no tag/client-scoping support in dnsmasq (confirmed
  against the source and man page); it's a global-only directive. dnsmasq
  rejects the resulting config outright (`bad option at line N`,
  independent of nftset support — reproduced locally against a real
  nftset-enabled dnsmasq 2.93 build) and refuses to start, again taking
  down DNS for the entire LAN. This is now removed entirely; enforcement is
  nft-only for both `block` and `budget` modes, which was always
  sufficient on its own since the nft rule already scopes correctly by
  `ether saddr`.
