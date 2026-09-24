include $(TOPDIR)/rules.mk

PKG_NAME:=kidsfirewall
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Sergi Hernanz <sergi.hernanz@teameeng.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/kidsfirewall
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Per-device parental control firewall (block / time-budget / schedule)
  DEPENDS:=+firewall4 +dnsmasq
  PKGARCH:=all
endef

define Package/kidsfirewall/description
  Blocks, time-budgets, or schedules internet access for specific MAC
  addresses and named services (Instagram, TikTok, YouTube, ...) on top of
  fw4/nftables and dnsmasq. Configuration lives in UCI (/etc/config/kidsfirewall);
  see luci-app-kidsfirewall for a web UI.
  .
  Needs dnsmasq's nftset= support (nftables set) for block/budget rules to
  actually match traffic. The stock 'dnsmasq' package on most images is
  built without it (no-nftset) -- install 'dnsmasq-full' instead (opkg
  remove dnsmasq && opkg install dnsmasq-full) for full functionality.
  This is detected automatically at runtime; without it, rules need a
  manually-populated static CIDR per service to do anything.
endef

define Package/kidsfirewall/conffiles
/etc/config/kidsfirewall
endef

define Build/Compile
endef

define Package/kidsfirewall/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/kidsfirewall $(1)/etc/config/kidsfirewall

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/kidsfirewall $(1)/etc/init.d/kidsfirewall

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-kidsfirewall $(1)/etc/uci-defaults/95-kidsfirewall

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/kidsfirewall-genrules $(1)/usr/sbin/kidsfirewall-genrules
	$(INSTALL_BIN) ./files/usr/sbin/kidsfirewall-monitor $(1)/usr/sbin/kidsfirewall-monitor
	$(INSTALL_BIN) ./files/usr/sbin/kidsfirewall-safe-dns-reapply $(1)/usr/sbin/kidsfirewall-safe-dns-reapply

	$(INSTALL_DIR) $(1)/usr/share/kidsfirewall
	$(INSTALL_DATA) ./files/usr/share/kidsfirewall/functions.sh $(1)/usr/share/kidsfirewall/functions.sh
endef

define Package/kidsfirewall/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	( . /etc/uci-defaults/95-kidsfirewall ) && rm -f /etc/uci-defaults/95-kidsfirewall
	/etc/init.d/kidsfirewall enable
	if dnsmasq --version 2>&1 | grep -q no-nftset; then
		echo "kidsfirewall: WARNING - your dnsmasq lacks nftset= support (compiled no-nftset)." >&2
		echo "kidsfirewall: block/budget rules will not match any traffic without it." >&2
		echo "kidsfirewall: run: opkg remove dnsmasq && opkg install dnsmasq-full" >&2
	fi
}
exit 0
endef

define Package/kidsfirewall/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/kidsfirewall stop
	/etc/init.d/kidsfirewall disable
}
exit 0
endef

$(eval $(call BuildPackage,kidsfirewall))
