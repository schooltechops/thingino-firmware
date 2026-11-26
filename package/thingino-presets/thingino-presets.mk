################################################################################
#
# thingino-presets
#
################################################################################

THINGINO_PRESETS_SITE_METHOD = local
THINGINO_PRESETS_SITE = $(THINGINO_PRESETS_PKGDIR)/files
THINGINO_PRESETS_LICENSE = MIT

define THINGINO_PRESETS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/thingino-preset $(TARGET_DIR)/usr/sbin/thingino-preset
	$(INSTALL) -d $(TARGET_DIR)/usr/share/thingino/presets
	$(INSTALL) -m 0644 $(@D)/presets/*.json $(TARGET_DIR)/usr/share/thingino/presets/
	$(INSTALL) -D -m 0644 $(@D)/presets.webui.json $(TARGET_DIR)/var/www/a/plugins/presets.webui.json
	$(INSTALL) -D -m 0644 $(@D)/www/config-presets.html $(TARGET_DIR)/var/www/config-presets.html
	$(INSTALL) -D -m 0644 $(@D)/www/a/config-presets.js $(TARGET_DIR)/var/www/a/config-presets.js
	$(INSTALL) -D -m 0755 $(@D)/www/x/json-config-presets.cgi $(TARGET_DIR)/var/www/x/json-config-presets.cgi
endef

ifeq ($(BR2_PACKAGE_THINGINO_PRESETS_UNIFI),y)
define THINGINO_PRESETS_INSTALL_UNIFI
	$(INSTALL) -D -m 0644 $(@D)/www/config-unifi.html $(TARGET_DIR)/var/www/config-unifi.html
	$(INSTALL) -D -m 0644 $(@D)/www/a/config-unifi.js $(TARGET_DIR)/var/www/a/config-unifi.js
	$(INSTALL) -D -m 0755 $(@D)/www/x/json-config-unifi.cgi $(TARGET_DIR)/var/www/x/json-config-unifi.cgi
	$(INSTALL) -D -m 0644 $(@D)/unifi.webui.json $(TARGET_DIR)/var/www/a/plugins/presets-unifi.webui.json
endef
THINGINO_PRESETS_POST_INSTALL_TARGET_HOOKS += THINGINO_PRESETS_INSTALL_UNIFI
endif

# Keep user presets and the undo point across firmware upgrades: sysupgrade -B saves the paths in
# /etc/cfg-backup.list to the backup partition and S37cfg-autorestore restores them on first boot.
# A ROOTFS_PRE_CMD_HOOK because cfg-backup.list comes from the rootfs overlay (see thingino-rhkd).
define THINGINO_PRESETS_CFG_BACKUP
	f=$(TARGET_DIR)/etc/cfg-backup.list; \
	if [ -f $$f ] && ! grep -qx '/etc/presets' $$f; then \
		printf '\n# Settings presets: user presets, active preset, undo point\n/etc/presets\n' >>$$f; \
	fi
endef
# Every package .mk is read whether selected or not, so register the global hook only when selected.
ifeq ($(BR2_PACKAGE_THINGINO_PRESETS),y)
ROOTFS_PRE_CMD_HOOKS += THINGINO_PRESETS_CFG_BACKUP
endif

$(eval $(generic-package))
