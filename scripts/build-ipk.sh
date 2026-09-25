#!/bin/sh
# Builds real, installable .ipk files for kidsfirewall and
# luci-app-kidsfirewall WITHOUT the OpenWRT SDK/buildroot.
#
# Both packages are PKGARCH:=all (no compiled code), and their files/
# trees already mirror the target root filesystem exactly -- so an .ipk
# is just a gzip-compressed tar of three members (debian-binary,
# control.tar.gz, data.tar.gz), buildable with plain tar/gzip. Note this
# is NOT the same container format as a Debian .deb (which really is an
# `ar` archive) despite looking similar on paper -- confirmed by reading
# opkg-lede's own deb_extract()/get_header_tar() and by a real opkg-cl
# install test; an earlier version of this script built a .deb-style ar
# archive and opkg-cl rejected it as "Malformed package file". This
# intentionally does NOT try to be a generic OpenWRT Makefile interpreter:
# package metadata
# below is kept in sync BY HAND with package/*/Makefile (each field is
# commented with where it came from) rather than parsed, since these are
# two small, known packages and a hand-rolled Makefile parser would be
# more fragile than just keeping two things in sync deliberately.
#
# Usage: scripts/build-ipk.sh [output-dir]   (default: dist/)

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="${1:-$ROOT_DIR/dist}"
MAINTAINER="Sergi Hernanz <sergi.hernanz@teameeng.com>"
LICENSE="GPL-2.0-or-later"

mkdir -p "$OUT_DIR"

# extract_define <makefile> <name> -- prints the content of a
# `define <name> ... endef` block (OpenWRT Makefile convention), with
# Make's "$$" escaping undone (Make expands "$$" to a literal "$" when
# these blocks are embedded into generated shell scripts; a real shell
# script needs plain "$", e.g. "$IPKG_INSTROOT" not "$$IPKG_INSTROOT").
extract_define() {
	awk -v name="$2" '
		$0 ~ ("^define[ \t]+" name "$") { found=1; next }
		found && /^endef/ { found=0; next }
		found { print }
	' "$1" | sed 's/\$\$/$/g'
}

# pkg_version <makefile> -- prints "PKG_VERSION-PKG_RELEASE"
pkg_version() {
	ver=$(sed -n 's/^PKG_VERSION:=//p' "$1")
	rel=$(sed -n 's/^PKG_RELEASE:=//p' "$1")
	echo "${ver}-${rel}"
}

# build_ipk <name> <version> <depends> <data_staging_dir> <description_file> [conffiles_file] [postinst_file] [prerm_file]
build_ipk() {
	name="$1" version="$2" depends="$3" datadir="$4" descfile="$5"
	conffiles="${6:-}" postinst="${7:-}" prerm="${8:-}"

	work=$(mktemp -d)
	mkdir -p "$work/control"

	{
		echo "Package: $name"
		echo "Version: $version"
		echo "Architecture: all"
		echo "Maintainer: $MAINTAINER"
		echo "License: $LICENSE"
		[ -n "$depends" ] && echo "Depends: $depends"
		echo "Description: $(sed -n '1p' "$descfile")"
		sed -n '2,$p' "$descfile"
	} > "$work/control/control"

	[ -n "$conffiles" ] && cp "$conffiles" "$work/control/conffiles"
	if [ -n "$postinst" ]; then
		cp "$postinst" "$work/control/postinst"
		chmod 755 "$work/control/postinst"
	fi
	if [ -n "$prerm" ]; then
		cp "$prerm" "$work/control/prerm"
		chmod 755 "$work/control/prerm"
	fi

	( cd "$work/control" && tar --format ustar -czf "$work/control.tar.gz" . )
	( cd "$datadir" && tar --format ustar -czf "$work/data.tar.gz" . )
	echo "2.0" > "$work/debian-binary"

	outfile="$OUT_DIR/${name}_${version}_all.ipk"
	# Real opkg .ipk files are NOT an ar archive (that's .deb) -- opkg-lede's
	# own deb_extract() gunzips the whole file and walks it as a plain tar
	# containing these three members (confirmed by reading libbb/unarchive.c
	# and reproducing "Malformed package file" against a real opkg-cl build
	# with the ar-archive version first).
	( cd "$work" && tar --format ustar -czf "$outfile" debian-binary control.tar.gz data.tar.gz )

	rm -rf "$work"
	echo "built $outfile"
}

# --------------------------------------------------------------- kidsfirewall
KFW_MK="$ROOT_DIR/package/kidsfirewall/Makefile"
KFW_VERSION=$(pkg_version "$KFW_MK")

# Stage a throwaway copy of files/ so we can fix exec bits without
# touching the actual repo working tree (none of these are executable on
# disk here -- macOS/git doesn't preserve that reliably across the
# manual-copy workflow this project has mostly used instead of opkg).
kfw_stage=$(mktemp -d)
cp -a "$ROOT_DIR/package/kidsfirewall/files/." "$kfw_stage/"
chmod 755 \
	"$kfw_stage/etc/init.d/kidsfirewall" \
	"$kfw_stage/etc/uci-defaults/95-kidsfirewall" \
	"$kfw_stage/usr/sbin/kidsfirewall-genrules" \
	"$kfw_stage/usr/sbin/kidsfirewall-monitor" \
	"$kfw_stage/usr/sbin/kidsfirewall-safe-dns-reapply"

kfw_desc=$(mktemp)
KFW_BLOCK=$(extract_define "$KFW_MK" "Package/kidsfirewall")
KFW_TITLE=$(echo "$KFW_BLOCK" | sed -n 's/^ *TITLE:=//p')
KFW_DEPENDS=$(echo "$KFW_BLOCK" | sed -n 's/^ *DEPENDS:=//p' | tr -d '+')
{
	echo "$KFW_TITLE"
	extract_define "$KFW_MK" "Package/kidsfirewall/description"
} > "$kfw_desc"

kfw_conffiles=$(mktemp)
extract_define "$KFW_MK" "Package/kidsfirewall/conffiles" > "$kfw_conffiles"

kfw_postinst=$(mktemp)
extract_define "$KFW_MK" "Package/kidsfirewall/postinst" > "$kfw_postinst"

kfw_prerm=$(mktemp)
extract_define "$KFW_MK" "Package/kidsfirewall/prerm" > "$kfw_prerm"

build_ipk kidsfirewall "$KFW_VERSION" "$KFW_DEPENDS" "$kfw_stage" "$kfw_desc" \
	"$kfw_conffiles" "$kfw_postinst" "$kfw_prerm"

rm -rf "$kfw_stage" "$kfw_desc" "$kfw_conffiles" "$kfw_postinst" "$kfw_prerm"

# ------------------------------------------------------- luci-app-kidsfirewall
# luci.mk (from the official luci feed) isn't present in this standalone
# repo, so its conventions (htdocs/ -> /www/, root/ -> /, an automatic
# +luci-base dependency and a cache-clearing postinst) are replicated by
# hand here rather than parsed -- there's no Makefile block to extract
# from for these, unlike kidsfirewall above.
LUCI_MK="$ROOT_DIR/package/luci-app-kidsfirewall/Makefile"
LUCI_VERSION=$(pkg_version "$LUCI_MK")
LUCI_SRC="$ROOT_DIR/package/luci-app-kidsfirewall"

luci_stage=$(mktemp -d)
mkdir -p "$luci_stage/www"
cp -a "$LUCI_SRC/htdocs/." "$luci_stage/www/"
cp -a "$LUCI_SRC/root/." "$luci_stage/"

luci_desc=$(mktemp)
cat > "$luci_desc" <<'EOF'
LuCI support for Kids Firewall
 Web UI (Network > Kids Firewall) for the kidsfirewall package:
 per-device block / time-budget / schedule rules, Safe DNS, and
 force_dns bypass protection.
EOF

luci_postinst=$(mktemp)
cat > "$luci_postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || {
	rm -f /tmp/luci-indexcache*
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
}
exit 0
EOF

build_ipk luci-app-kidsfirewall "$LUCI_VERSION" "kidsfirewall luci-base" \
	"$luci_stage" "$luci_desc" "" "$luci_postinst" ""

rm -rf "$luci_stage" "$luci_desc" "$luci_postinst"

echo "Done. Artifacts in $OUT_DIR:"
ls -la "$OUT_DIR"
