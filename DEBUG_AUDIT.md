# Auditing what this package changes on your router

This is the exhaustive list of everything `kidsfirewall` /
`luci-app-kidsfirewall` touch on an OpenWRT router, plus the exact command
to inspect each one. Use it to verify the install did what it should, or to
figure out exactly what to revert if something looks wrong.

**Most reliable method — diff a before/after snapshot.** Don't just trust
the list below (docs drift, code doesn't always match what's written about
it). The `audit.sh` script at the bottom dumps every category in one go.
Run it once **before** installing and once **after**, then diff:

```sh
ssh "$ROUTER" 'sh -s' < audit.sh > before.txt   # run before install
# ... install ...
ssh "$ROUTER" 'sh -s' < audit.sh > after.txt    # run after install
diff -u before.txt after.txt
```

That diff is ground truth for "what did this actually change" — safer than
relying on any document, including this one.

## Category 1 — new files this package installs

Nothing here should have existed before install. Full list:

```
/etc/config/kidsfirewall
/etc/init.d/kidsfirewall
/usr/sbin/kidsfirewall-genrules
/usr/sbin/kidsfirewall-monitor
/usr/share/kidsfirewall/functions.sh
/usr/share/luci/menu.d/luci-app-kidsfirewall.json
/usr/share/rpcd/acl.d/luci-app-kidsfirewall.json
/usr/share/ucitrack/kidsfirewall.json
/www/luci-static/resources/view/kidsfirewall/overview.js
```

(`/etc/uci-defaults/95-kidsfirewall` is also installed but deletes itself
the first time it runs — see Category 3.)

Check they're all present and look at them directly:

```sh
ssh "$ROUTER" 'for f in /etc/config/kidsfirewall /etc/init.d/kidsfirewall \
  /usr/sbin/kidsfirewall-genrules /usr/sbin/kidsfirewall-monitor \
  /usr/share/kidsfirewall/functions.sh \
  /usr/share/luci/menu.d/luci-app-kidsfirewall.json \
  /usr/share/rpcd/acl.d/luci-app-kidsfirewall.json \
  /usr/share/ucitrack/kidsfirewall.json \
  /www/luci-static/resources/view/kidsfirewall/overview.js; do
    ls -la "$f" 2>&1
done'
```

## Category 2 — the one existing config file this package *modifies*

`/etc/config/dhcp`: if the `dnsmasq` section didn't already have a
`confdir` option set, `95-kidsfirewall` (uci-defaults, run once) and
`kidsfirewall-genrules` (every time it runs, as a safety net) both set:

```
option confdir '/tmp/dnsmasq.d'
```

This is the *only* pre-existing config file touched. Check it:

```sh
ssh "$ROUTER" "uci get dhcp.@dnsmasq[0].confdir"
```

If that prints `/tmp/dnsmasq.d` and you don't remember it being there
before, this package set it. It's a fairly benign, commonly-used setting
(other packages like adblock/simple-adblock rely on the same option), but
if you want it gone: `uci delete dhcp.@dnsmasq[0].confdir; uci commit dhcp;
/etc/init.d/dnsmasq restart` — only do this if nothing else on your router
now depends on `/tmp/dnsmasq.d` too.

**Nothing else is modified.** In particular, `/etc/config/firewall` is
never touched — confirm that directly:

```sh
ssh "$ROUTER" "uci show firewall | grep -i kidsfirewall"   # should print nothing
```

**Is your dnsmasq the full-featured build?** Worth checking regardless of
whether anything looks broken — the minimal `dnsmasq` package (OpenWRT's
default) lacks `nftset=` support, which degrades budget-mode accounting and
the nft-level block backstop (block-mode DNS blocking still works fine
either way):

```sh
ssh "$ROUTER" "dnsmasq --version | grep 'compile time options'"
# look for "nftset" (supported) vs "no-nftset" (not supported, install dnsmasq-full)
```

## Category 3 — boot-enablement (init script symlinks)

`/etc/init.d/kidsfirewall enable` creates symlinks under `/etc/rc.d/` (this
is how OpenWRT decides what starts at boot — same mechanism every other
`/etc/init.d/*` service uses):

```sh
ssh "$ROUTER" "ls -la /etc/rc.d/ | grep kidsfirewall"
```

Expect something like `S95kidsfirewall -> ../init.d/kidsfirewall` (and
possibly a `K10kidsfirewall`). `/etc/init.d/kidsfirewall disable` removes
these.

## Category 4 — live kernel/firewall state (not a file at all)

The actual blocking rules live in the kernel's nftables state, loaded by
`kidsfirewall-genrules` and mutated by `kidsfirewall-monitor`. This
disappears entirely on `/etc/init.d/kidsfirewall stop` (or a reboot) — it's
not persisted anywhere on disk as a ruleset.

```sh
ssh "$ROUTER" "nft list table inet kidsfirewall"
```

To confirm it's fully separate from your existing firewall and not
touching it:

```sh
ssh "$ROUTER" "nft list ruleset | grep -A2 'table inet '"   # shows every table's header; you should see both 'inet fw4' and 'inet kidsfirewall' as independent tables
```

## Category 5 — ephemeral/runtime files (tmpfs, gone on reboot anyway)

None of these are meant to be permanent, but worth knowing they exist:

```sh
ssh "$ROUTER" "ls -la /var/run/kidsfirewall/ /var/run/kidsfirewall/usage/ 2>&1"
ssh "$ROUTER" "cat /tmp/dnsmasq.d/kidsfirewall.conf 2>&1"
ssh "$ROUTER" "ls /tmp/luci-indexcache* 2>&1"
```

- `/var/run/kidsfirewall/ruleset.nft` — the last-generated nft ruleset (for
  your own debugging; not re-read on boot, regenerated fresh each start)
- `/var/run/kidsfirewall/usage/*.state` — per-device/service time-budget
  tally (`period_stamp seconds_used last_packet_count`)
- `/tmp/dnsmasq.d/kidsfirewall.conf` — `nftset=` lines that keep the
  `dest_<service>` nft sets populated from DNS lookups (not per-device;
  device-level scoping happens entirely in the nft rules, not in dnsmasq)
- `/tmp/luci-indexcache*` — LuCI's own menu cache, unrelated to this
  package's data but cleared by its install/uninstall steps

## Category 6 — logs

Everything this package logs goes through `logger -t kidsfirewall`:

```sh
ssh "$ROUTER" "logread | grep kidsfirewall"
```

## audit.sh — dump everything in one go

Save this locally and run it as shown at the top of this doc
(`ssh "$ROUTER" 'sh -s' < audit.sh`):

```sh
#!/bin/sh
echo "== files =="
for f in /etc/config/kidsfirewall /etc/init.d/kidsfirewall \
  /etc/uci-defaults/95-kidsfirewall \
  /usr/sbin/kidsfirewall-genrules /usr/sbin/kidsfirewall-monitor \
  /usr/share/kidsfirewall/functions.sh \
  /usr/share/luci/menu.d/luci-app-kidsfirewall.json \
  /usr/share/rpcd/acl.d/luci-app-kidsfirewall.json \
  /usr/share/ucitrack/kidsfirewall.json \
  /www/luci-static/resources/view/kidsfirewall/overview.js; do
    ls -la "$f" 2>&1
done

echo "== dhcp confdir =="
uci get dhcp.@dnsmasq[0].confdir 2>&1

echo "== dnsmasq nftset support =="
dnsmasq --version 2>&1 | grep 'compile time options'

echo "== firewall config mentions of kidsfirewall (expect none) =="
uci show firewall 2>/dev/null | grep -i kidsfirewall

echo "== rc.d boot symlinks =="
ls -la /etc/rc.d/ 2>/dev/null | grep kidsfirewall

echo "== nft table =="
nft list table inet kidsfirewall 2>&1

echo "== nft ruleset table headers =="
nft list ruleset 2>/dev/null | grep '^table'

echo "== runtime state =="
ls -la /var/run/kidsfirewall/ 2>&1
ls -la /var/run/kidsfirewall/usage/ 2>&1
cat /tmp/dnsmasq.d/kidsfirewall.conf 2>&1

echo "== recent logs =="
logread 2>/dev/null | grep kidsfirewall | tail -50
```
