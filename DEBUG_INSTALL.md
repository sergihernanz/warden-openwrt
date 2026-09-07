# Manual install (no SDK / no opkg)

Both packages here (`kidsfirewall`, `luci-app-kidsfirewall`) are pure
shell/UCI/JS — `PKGARCH:=all`, nothing gets compiled, and (deliberately)
nothing needs a Lua runtime on the router either. So instead of
building a real `.ipk` with the OpenWRT SDK, you can just copy the files
straight into place over SSH. This is the fast path for trying it out on
one router; see the SDK build steps in [README.md](README.md) if you want
a real, versioned, opkg-managed package instead.

Because this touches your live router's firewall and DNS resolver, **run
these commands yourself** in your own terminal rather than having an
assistant run them against your router directly.

**Before you start:** run through [DEBUG_AUDIT.md](DEBUG_AUDIT.md)'s audit
script once and save the output (`ssh $ROUTER '...' > before.txt`). That
gives you an exact baseline to diff against later if anything looks wrong.

## 1. Set your router's address

```sh
ROUTER=root@192.168.1.1   # change to your router's actual LAN IP
```

> **Does `scp -r .../etc "$ROUTER:/"` overwrite the router's whole `/etc`?**
> No. When the destination directory already exists, `scp -r` (like `cp -r`)
> nests the source into it by basename and *merges* — it creates new files,
> overwrites only files whose relative path also exists in the source, and
> leaves everything else in the destination untouched. Since our local dirs
> are named `etc`/`usr` to mirror the real root filesystem layout, this
> lands exactly at `/etc`, `/usr`, etc., touching only the specific
> `kidsfirewall`-named files listed in DEBUG_AUDIT.md. If you want to see
> exactly what would change before running it for real, preview with:
> ```sh
> rsync -a -n -i package/kidsfirewall/files/etc/ "$ROUTER:/etc/"
> ```
> (`-n` = dry run, `-i` = show what would be added/changed, one line per file)

> **Getting `ash: /usr/libexec/sftp-server: not found` / `scp: Connection
> closed`?** Since OpenSSH 9.0, `scp` defaults to the SFTP protocol, which
> needs an `sftp-server` binary on the remote — OpenWRT's default `dropbear`
> SSH daemon doesn't ship one. The `-O` flag on every `scp` command below
> forces the older SCP protocol instead, which dropbear does support. If
> `-O` *still* fails (some minimal dropbear builds omit that too), fall back
> to piping a `tar` over `ssh`, which only needs `tar` + `ssh` on both ends:
> ```sh
> tar -C package/kidsfirewall/files -cf - etc usr | ssh "$ROUTER" 'tar -C / -xf -'
> tar -C package/luci-app-kidsfirewall/root -cf - usr | ssh "$ROUTER" 'tar -C / -xf -'
> ssh "$ROUTER" 'mkdir -p /www/luci-static/resources/view/kidsfirewall'
> tar -C package/luci-app-kidsfirewall/htdocs/luci-static/resources/view/kidsfirewall -cf - overview.js \
>   | ssh "$ROUTER" 'tar -C /www/luci-static/resources/view/kidsfirewall -xf -'
> ```

## 2. Copy the backend package files

```sh
cd /path/to/social-firewall
scp -O -r package/kidsfirewall/files/etc "$ROUTER:/"
scp -O -r package/kidsfirewall/files/usr "$ROUTER:/"
```

## 3. Copy the LuCI app files

```sh
scp -O -r package/luci-app-kidsfirewall/root/usr "$ROUTER:/"
ssh "$ROUTER" 'mkdir -p /www/luci-static/resources/view/kidsfirewall'
scp -O package/luci-app-kidsfirewall/htdocs/luci-static/resources/view/kidsfirewall/overview.js \
    "$ROUTER:/www/luci-static/resources/view/kidsfirewall/overview.js"
```

## 4. Finish the install on the router

This mirrors what the package's `postinst`/`uci-defaults` would normally do
automatically on an `opkg install`:

```sh
ssh "$ROUTER" <<'REMOTE'
chmod +x /etc/init.d/kidsfirewall \
         /usr/sbin/kidsfirewall-genrules \
         /usr/sbin/kidsfirewall-monitor \
         /etc/uci-defaults/95-kidsfirewall

( . /etc/uci-defaults/95-kidsfirewall ) && rm -f /etc/uci-defaults/95-kidsfirewall

/etc/init.d/kidsfirewall enable
/etc/init.d/kidsfirewall start

rm -f /tmp/luci-indexcache*
/etc/init.d/rpcd restart
REMOTE
```

## 5. Verify

```sh
ssh "$ROUTER" 'nft list table inet kidsfirewall; echo ---; logread | grep kidsfirewall | tail -20'
```

Expect to see the `inet kidsfirewall` table (with `set schedule_blocked`
etc.) and a `monitor daemon starting` log line. Then open LuCI in your
browser → **Network → Kids Firewall**. If the menu entry doesn't show up,
hard-refresh or log out/in of LuCI — it's the indexcache we just cleared.

## What this actually changes on the router

See [DEBUG_AUDIT.md](DEBUG_AUDIT.md) for the exhaustive list and the
commands to inspect every single thing this install touches.

## Updating after editing the source

Re-run steps 2-4 (the `scp` commands overwrite the files in place;
`kidsfirewall-genrules` and the monitor daemon get restarted by `start` —
if the service is already running, use `restart` instead of `start`, or
just `reload` if you only changed `/etc/config/kidsfirewall`):

```sh
ssh "$ROUTER" '/etc/init.d/kidsfirewall restart'
```
