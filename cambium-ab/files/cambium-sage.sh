# Cambium Sage (IPQ4019) board table, shared by sysupgrade (platform.sh) and
# the cambium-sage-support helpers.
#
# Only the E410 and E410B layouts have been captured and tested. Keep this
# table deliberately closed: another Sage model must be verified before it
# can pass the A/B writer's board and SKU checks.

# cambium_sage_board [BOARD_NAME]
# Set the SAGE_* variables for a Sage board and return 0, or return 1 for any
# other board.
cambium_sage_board() {
	local board="${1:-$(board_name)}"

	SAGE_MODEL= SAGE_SKU= SAGE_FIT= SAGE_QUALIFIED=0
	case "$board" in
	cambium,e410|cambiumnetworks,e410)
		SAGE_MODEL=E410 SAGE_SKU=10 SAGE_FIT=config@5 SAGE_QUALIFIED=1 ;;
	cambiumnetworks,e410b)	SAGE_MODEL=E410B SAGE_SKU=21 SAGE_FIT=config@17 SAGE_QUALIFIED=1 ;;
	*) return 1 ;;
	esac

	# Layout captured on the E410/E410B: SPI NAND as U-Boot nand device 1,
	# holding one 128 MiB UBI partition "fs" with linuxN/rootfsN volume pairs
	# and 126,976-byte LEBs.
	SAGE_BOARD_DIR=sysupgrade-cambium_e410
	SAGE_NAND_DEV=1
	SAGE_NAND_MTDPARTS='mtdparts=nand1:0x8000000@0x0(fs)'
	SAGE_KERNEL_MTDPARTS='mtdparts=spi0.1:128M(fs)'
	SAGE_UBI_PART=fs
	SAGE_KERNEL_VOL=linux
	SAGE_ROOTFS_VOL=rootfs
	SAGE_LOADADDR=0x84000000
	SAGE_KERNEL_MAX=4317184
	SAGE_ROOTFS_MAX=47235072
	SAGE_RADIOS=2
	return 0
}

# cambium_sage_check_sku
# Fail if the running device tree records a board SKU other than the table's.
cambium_sage_check_sku() {
	local node="${SAGE_DT_SKU:-/proc/device-tree/cambium-platform/board-sku}"
	local hex

	[ -r "$node" ] || return 0
	hex=$(hexdump -v -e '1/1 "%02x"' "$node")
	[ -n "$hex" ] && [ "$(printf '%d' "0x$hex")" = "$SAGE_SKU" ]
}

# cambium_sage_boot_command SLOT
# U-Boot command that boots slot SLOT (0 or 1) on the current board.
cambium_sage_boot_command() {
	local slot="$1" rootargs

	case "${SAGE_ROOT_TYPE:-ubifs}" in
	ubifs)
		rootargs="root=ubi0:$SAGE_ROOTFS_VOL$slot rootfstype=ubifs rootwait"
		;;
	squashfs)
		# The captured E410 layout keeps rootfs0 at ID 1 and rootfs1 at ID 3.
		# Resizing these volumes must never change their IDs.
		case "$slot" in 0) rootargs='root=/dev/ubiblock0_1' ;; 1) rootargs='root=/dev/ubiblock0_3' ;; *) return 1 ;; esac
		rootargs="ubi.block=0,$SAGE_ROOTFS_VOL$slot $rootargs rootfstype=squashfs ro rootwait fstools_overlay_name=rootfs_data$slot cambium_sage_slot=$slot"
		;;
	*) return 1 ;;
	esac

	printf '%s' "setenv image $slot; setenv bootargs \"$SAGE_KERNEL_MTDPARTS ubi.mtd=$SAGE_UBI_PART $rootargs\"; nand device $SAGE_NAND_DEV && setenv mtdids nand$SAGE_NAND_DEV=nand$SAGE_NAND_DEV && setenv mtdparts \"$SAGE_NAND_MTDPARTS\" && ubi part $SAGE_UBI_PART && ubi read $SAGE_LOADADDR $SAGE_KERNEL_VOL$slot && bootm $SAGE_LOADADDR#$SAGE_FIT"
}

# cambium_sage_running_slot
# Print the slot the running system booted from (0 or 1).
cambium_sage_running_slot() {
	local slot
	slot=$(sed -n 's/.*cambium_sage_slot=\([01]\).*/\1/p' "${CAMBIUM_CMDLINE:-/proc/cmdline}")
	[ -n "$slot" ] || slot=$(sed -n "s/.*root=ubi0:$SAGE_ROOTFS_VOL\([01]\).*/\1/p" "${CAMBIUM_CMDLINE:-/proc/cmdline}")
	[ -n "$slot" ] && echo "$slot"
}
