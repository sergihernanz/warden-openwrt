include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kidsfirewall
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Sergi Hernanz <sergi.hernanz@teameeng.com>

LUCI_TITLE:=LuCI support for Kids Firewall
LUCI_DESCRIPTION:=Web UI (Network > Kids Firewall) for the kidsfirewall package: \
	per-device block / time-budget / schedule rules.
LUCI_DEPENDS:=+kidsfirewall
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
