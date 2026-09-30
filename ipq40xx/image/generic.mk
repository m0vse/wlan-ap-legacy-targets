
DEVICE_VARS += NETGEAR_BOARD_ID NETGEAR_HW_ID
DEVICE_VARS += RAS_BOARD RAS_ROOTFS_SIZE RAS_VERSION
DEVICE_VARS += WRGG_DEVNAME WRGG_SIGNATURE
DEVICE_VARS += CAMBIUM_FIT_BOARDS

define Device/FitImage
	KERNEL_SUFFIX := -fit-uImage.itb
	KERNEL = kernel-bin | gzip | fit gzip $$(DTS_DIR)/$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
endef

define Device/FitImageLzma
	KERNEL_SUFFIX := -fit-uImage.itb
	KERNEL = kernel-bin | lzma | fit lzma $$(DTS_DIR)/$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
endef

define Device/FitzImage
	KERNEL_SUFFIX := -fit-zImage.itb
	KERNEL = kernel-bin | fit none $$(DTS_DIR)/$$(DEVICE_DTS).dtb
	KERNEL_NAME := zImage
endef

define Device/UbiFit
	KERNEL_IN_UBI := 1
	IMAGES := nand-factory.ubi nand-sysupgrade.bin
	IMAGE/nand-factory.ubi := append-ubi
	IMAGE/nand-sysupgrade.bin := sysupgrade-tar | append-metadata
endef

define Device/DniImage
	$(call Device/FitzImage)
	NETGEAR_BOARD_ID :=
	NETGEAR_HW_ID :=
	IMAGES += factory.img
	IMAGE/factory.img := append-kernel | pad-offset 64k 64 | append-uImage-fakehdr filesystem | append-rootfs | pad-rootfs | netgear-dni
	IMAGE/sysupgrade.bin := append-kernel | pad-offset 64k 64 | append-uImage-fakehdr filesystem | \
		append-rootfs | pad-rootfs | append-metadata | check-size
endef

define Build/append-rootfshdr
	mkimage -A $(LINUX_KARCH) \
		-O linux -T filesystem \
		-C lzma -a $(KERNEL_LOADADDR) -e $(if $(KERNEL_ENTRY),$(KERNEL_ENTRY),$(KERNEL_LOADADDR)) \
		-n root.squashfs -d $(IMAGE_ROOTFS) $@.new
	dd if=$@.new bs=64 count=1 >> $(IMAGE_KERNEL)
endef

define Build/mkmylofw_32m
	$(eval device_id=$(word 1,$(1)))
	$(eval revision=$(word 2,$(1)))

	let \
		size="$$(stat -c%s $@)" \
		pad="$(subst k,* 1024,$(BLOCKSIZE))" \
		pad="(pad - (size % pad)) % pad" \
		newsize='size + pad'; \
		$(STAGING_DIR_HOST)/bin/mkmylofw \
		-B WPE72 -i 0x11f6:$(device_id):0x11f6:$(device_id) -r $(revision) \
		-s 0x2000000 -p0x180000:$$newsize:al:0x80208000:"OpenWrt":$@ \
		$@.new
	@mv $@.new $@
endef

define Build/qsdk-ipq-factory-nand-askey
	$(TOPDIR)/scripts/mkits-qsdk-ipq-image.sh $@.its\
		askey_kernel $(IMAGE_KERNEL) \
		askey_fs $(IMAGE_ROOTFS) \
		ubifs $@
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $@.its $@.new
	@mv $@.new $@
endef

define Build/SenaoFW
	-$(STAGING_DIR_HOST)/bin/mksenaofw \
		-n $(BOARD_NAME) -r $(VENDOR_ID) -p $(1) \
		-c $(DATECODE) -w $(2) -x $(CW_VER) -t 0 \
		-e $@ \
		-o $@.new
	@cp $@.new $@
endef

define Build/wrgg-image
	mkwrggimg -i $@ \
	-o $@.new \
	-d "$(WRGG_DEVNAME)" \
	-s "$(WRGG_SIGNATURE)" \
	-v "" -m "" -B ""
	mv $@.new $@
endef

# Build one kernel FIT with the model-specific DTBs and OEM U-Boot
# configuration names used by the qualified Cambium Sage models.
define Build/cambium-family-fit
	sh $(PLATFORM_DIR)/image/cambium-family-its.sh \
		-k $@ -A $(LINUX_KARCH) -C $(word 1,$(1)) \
		-a $(KERNEL_LOADADDR) -e $(if $(KERNEL_ENTRY),$(KERNEL_ENTRY),$(KERNEL_LOADADDR)) \
		-d "$(DEVICE_VENDOR) $(DEVICE_MODEL)" \
		$(if $(DEVICE_DTS_CONFIG),-D $(DEVICE_DTS_CONFIG)) \
		$(foreach board,$(CAMBIUM_FIT_BOARDS),$(word 1,$(subst :, ,$(board))):$(word 2,$(subst :, ,$(board))):$(KDIR)/image-$(word 3,$(subst :, ,$(board))).dtb) \
		> $@.its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $@.its $@.new
	@mv $@.new $@
endef

define Device/cambium-sage
	$(call Device/FitzImage)
	DEVICE_VENDOR := Cambium Networks
	DEVICE_MODEL := Sage family
	DEVICE_VARIANT := E410/E410B qualified
	DEVICE_DTS := qcom-ipq4019-cambium-e410 qcom-ipq4019-cambium-e410b
	DEVICE_DTS_CONFIG := config@5
	KERNEL = kernel-bin | cambium-family-fit none
	CAMBIUM_FIT_BOARDS := 5:e410:qcom-ipq4019-cambium-e410 \
		17:e410b:qcom-ipq4019-cambium-e410b \
		ap.dk01.1-c2:e410:qcom-ipq4019-cambium-e410
	SOC := qcom-ipq4019
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4216k
	BOARD_NAME := cambium_e410
	SUPPORTED_DEVICES := cambium,e410 cambiumnetworks,e410 cambiumnetworks,e410b
	IMAGES := kernel.itb rootfs.squashfs sysupgrade.bin
	IMAGE/kernel.itb := append-kernel | check-size 4216k
	IMAGE/rootfs.squashfs := append-rootfs | check-size 37820k
	IMAGE/sysupgrade.bin := append-rootfs | check-size 37820k | sysupgrade-tar rootfs=$$$$@ | append-metadata
	DEVICE_PACKAGES := cambium-ab
endef
TARGET_DEVICES += cambium-sage

define Device/hfcl_ion4
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := HFCL
	DEVICE_MODEL := ION4
	SOC := qcom-ipq4019
	DEVICE_DTS := qcom-ipq4019-hfcl-ion4
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4048k
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	BOARD_NAME := hfcl-ion4
	IMAGES := nand-sysupgrade.bin
	IMAGE/nand-sysupgrade.bin := sysupgrade-tar | append-metadata
	DEVICE_PACKAGES := uboot-envtools
endef
TARGET_DEVICES += hfcl_ion4

define Device/um-325ac
	DEVICE_VENDOR := Indio Networks
	DEVICE_MODEL := UM-325AC
	BOARD_NAME := um-325ac
	SOC := qcom-ipq4019
	DEVICE_DTS := qcom-ipq4019-um-325ac
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4096k
	IMAGE_SIZE := 26624k
	$(call Device/FitImage)
	IMAGE/sysupgrade.bin := append-kernel | pad-to $$$$(KERNEL_SIZE) | append-rootfs | pad-rootfs | append-metadata
endef
TARGET_DEVICES += um-325ac

define Device/udaya_a5-id2
	$(call Device/FitImage)
	DEVICE_VENDOR := udaya
	DEVICE_MODEL := A5-ID2
	SOC := qcom-ipq4018
	DEVICE_DTS := qcom-ipq4018-udaya-a5-id2
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4096k
	IMAGE_SIZE := 26624k
	DEVICE_PACKAGES := ipq-wifi-udaya-a5-id2
	IMAGE/sysupgrade.bin := append-kernel | pad-to $$$$(KERNEL_SIZE) | append-rootfs | pad-rootfs | append-metadata
endef
TARGET_DEVICES += udaya_a5-id2

define Device/um-550ac
	DEVICE_VENDOR := Indio Networks
	DEVICE_MODEL := UM-550AC
	BOARD_NAME := um-550ac
	SOC := qcom-ipq4019
	DEVICE_DTS := qcom-ipq4019-um-550ac
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4096k
	IMAGE_SIZE := 26624k
	$(call Device/FitImage)
	IMAGE/sysupgrade.bin := append-kernel | pad-to $$$$(KERNEL_SIZE) | append-rootfs | pad-rootfs | append-metadata
endef
TARGET_DEVICES += um-550ac


define Device/um-510ac-v3
	DEVICE_VENDOR := Indio Networks
	DEVICE_MODEL := UM-510AC-V3
	BOARD_NAME := um-510ac-v3
	SOC := qcom-ipq4019
	DEVICE_DTS := qcom-ipq4019-um-510ac-v3
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 4096k
	IMAGE_SIZE := 26624k
	$(call Device/FitImage)
	IMAGE/sysupgrade.bin := append-kernel | pad-to $$$$(KERNEL_SIZE) | append-rootfs | pad-rootfs | append-metadata
endef
TARGET_DEVICES += um-510ac-v3

define Device/edgecore_ecw5211
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := Edgecore
	DEVICE_MODEL := ECW5211
	SOC := qcom-ipq4018
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	DEVICE_DTS_CONFIG := config@ap.dk01.1-c2
	DEVICE_PACKAGES := kmod-tpm-i2c-atmel kmod-usb-acm
endef
TARGET_DEVICES += edgecore_ecw5211

define Device/edgecore_spw2ac1200
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := Edgecore
	DEVICE_MODEL := SPW2AC1200
	SOC := qcom-ipq4018
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	DEVICE_DTS_CONFIG := config@ap.dk01.1-c2
	DEVICE_PACKAGES := kmod-tpm-i2c-atmel kmod-usb-acm uboot-envtools
endef
TARGET_DEVICES += edgecore_spw2ac1200
