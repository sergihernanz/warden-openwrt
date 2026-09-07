# Uninstalling (manual-copy install)

Since the [manual install](DEBUG_INSTALL.md) didn't go through opkg, there's
no `opkg remove` for it — this reverses it by hand. See
[DEBUG_AUDIT.md](DEBUG_AUDIT.md) for exactly what each of these steps is
undoing and how to double-check it worked.

```sh
ROUTER=root@192.168.1.1   # your router's LAN IP
```

## 1. Stop and disable the service

This removes the live nftables table and the boot-enablement symlinks
(Categories 3 and 4 in DEBUG_AUDIT.md):

```sh
ssh "$ROUTER" <<'REMOTE'
/etc/init.d/kidsfirewall stop
/etc/init.d/kidsfirewall disable
REMOTE
```

Verify the firewall table and rc.d symlinks are actually gone:

```sh
ssh "$ROUTER" "nft list table inet kidsfirewall"   # should error: No such file or directory
ssh "$ROUTER" "ls /etc/rc.d/ | grep kidsfirewall"  # should print nothing
```

## 2. Clean up dnsmasq

`stop_service` already removes `/tmp/dnsmasq.d/kidsfirewall.conf` and
reloads dnsmasq, but a full restart is a safer way to guarantee nothing
from it lingers in dnsmasq's running memory:

```sh
ssh "$ROUTER" <<'REMOTE'
rm -f /tmp/dnsmasq.d/kidsfirewall.conf
/etc/init.d/dnsmasq restart
REMOTE
```

## 3. Remove the installed files

```sh
ssh "$ROUTER" <<'REMOTE'
rm -f  /etc/init.d/kidsfirewall
rm -f  /etc/uci-defaults/95-kidsfirewall
rm -f  /usr/sbin/kidsfirewall-genrules
rm -f  /usr/sbin/kidsfirewall-monitor
rm -rf /usr/share/kidsfirewall
rm -f  /usr/share/luci/menu.d/luci-app-kidsfirewall.json
rm -f  /usr/share/rpcd/acl.d/luci-app-kidsfirewall.json
rm -f  /usr/share/ucitrack/kidsfirewall.json
rm -rf /www/luci-static/resources/view/kidsfirewall
rm -rf /var/run/kidsfirewall
REMOTE
```

**Your configuration is not deleted by the above** — `/etc/config/kidsfirewall`
(your devices/services/rules) is left in place on purpose, in case you want
to reinstall later and pick up where you left off. If you want it gone too:

```sh
ssh "$ROUTER" "rm -f /etc/config/kidsfirewall"
```

## 4. Decide about the dnsmasq `confdir` setting

This package may have set `option confdir '/tmp/dnsmasq.d'` on
`dhcp.@dnsmasq[0]` if it wasn't already set (see DEBUG_AUDIT.md Category 2).
This is not removed automatically because:

- it's a generically useful, widely-used setting (other packages rely on
  the same directory), so removing it could be an unwanted side effect if
  you've installed anything else that also depends on it since, and
- there's no reliable way for a script to know whether *you* had already
  set it yourself before this package touched it.

Check it and remove it yourself only if you're confident nothing else
needs it:

```sh
ssh "$ROUTER" "uci get dhcp.@dnsmasq[0].confdir"
# if you want it gone:
ssh "$ROUTER" "uci delete dhcp.@dnsmasq[0].confdir; uci commit dhcp; /etc/init.d/dnsmasq restart"
```

## 5. Clear LuCI's cache

```sh
ssh "$ROUTER" "rm -f /tmp/luci-indexcache*; /etc/init.d/rpcd restart"
```

## 6. Final check

Re-run the `audit.sh` script from DEBUG_AUDIT.md and confirm everything
under "files", "nft table", and "rc.d boot symlinks" is now absent:

```sh
ssh "$ROUTER" 'sh -s' < audit.sh
```

A reboot is optional but is the most thorough final sanity check — it
guarantees no leftover state in tmpfs (`/var/run`, `/tmp`) survives, since
none of it is written anywhere persistent.
