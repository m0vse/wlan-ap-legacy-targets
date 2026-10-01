include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-ab
PKG_RELEASE:=11
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-ab
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium access point A/B firmware banks
  DEPENDS:=+uboot-envtools +ubi-utils
  PKGARCH:=all
endef

define Package/cambium-ab/description
  Two OpenWrt firmware banks with automatic rollback for Cambium access
  points: sysupgrade writes the inactive bank and trial-boots it, a boot
  guard commits it only after health checks, cambium-ab-convert replaces the
  stock firmware bank once, and cambium-ab-status reports the state. Each
  family's board table and U-Boot commands come from its own module
  (/lib/functions/cambium-ab-<family>.sh).
endef

define Build/Compile
endef

define Package/cambium-ab/install
	$(INSTALL_DIR) $(1)/lib/functions $(1)/lib/upgrade $(1)/usr/sbin \
		$(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/ucentral
	$(INSTALL_DATA) ./files/cambium-ab.sh $(1)/lib/functions/cambium-ab.sh
	$(INSTALL_DATA) ./files/cambium-ab-sage.sh $(1)/lib/functions/cambium-ab-sage.sh
	$(INSTALL_DATA) ./files/cambium-sage.sh $(1)/lib/functions/cambium-sage.sh
	$(INSTALL_DATA) ./files/cambium-ab-upgrade.sh $(1)/lib/upgrade/cambium-ab.sh
	$(INSTALL_BIN) ./files/cambium-ab-guard $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cambium-ab-convert $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cambium-ab-status $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cambium-ab-guard.init $(1)/etc/init.d/cambium-ab-guard
	$(INSTALL_BIN) ./files/18_cambium_ab_guard $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/19_cambium_openwifi_identity $(1)/etc/uci-defaults/
	$(INSTALL_DATA) ./files/ucentral-platform $(1)/etc/ucentral/platform
endef

$(eval $(call BuildPackage,cambium-ab))
