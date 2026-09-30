#!/bin/sh
# Cambium A/B module for the Sage family (IPQ4019). See cambium-ab.sh.
#
# Sage keeps two kernel/rootfs volume pairs in one SPI-NAND UBI device. The
# stock and transitional rootfs volumes are UBIFS; later upgrades convert
# each inactive pair to SquashFS with its own UBIFS rootfs_data overlay.
# U-Boot has no changing_bootcmd marker. Both formats use the same board
# table and guarded A/B trial mechanism.
#

. "${CAMBIUM_SAGE_LIB:-/lib/functions/cambium-sage.sh}"

case " ${AB_FAMILIES:-} " in
*" sage "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }sage" ;;
esac

# Factory product ID is read only. A legacy B-suffix unit trials config@17
# on its next upgrade while retaining the confirmed E410 boot command.
ab_sage_legacy_b() {
	local idx
	idx=$(ab_mtd_index mfginfo)
	case "$idx" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "${AB_DEV:-/dev}/mtd${idx}ro" ] || return 1
	tr '\000' '\n' < "${AB_DEV:-/dev}/mtd${idx}ro" | grep -Fq 'PL-E410XXXB-'
}

ab_sage_board() {
	cambium_sage_board "$1" || return 1
	AB_SAGE_LEGACY_B=0
	case "$1" in
	cambium,e410|cambiumnetworks,e410)
		if ab_sage_legacy_b; then
			AB_SAGE_LEGACY_B=1
			SAGE_MODEL=E410B
			SAGE_FIT=config@17
		fi
		;;
	esac
	AB_NAME=Sage
	AB_ENV=sage
	AB_LAYOUT=pair
	AB_MARKER=0
	AB_IMAGE_DIR=$SAGE_BOARD_DIR
	AB_ROOT_MAGIC=hsqs
	AB_MODEL=$SAGE_MODEL
	AB_SKU=$(printf '%08x' "$SAGE_SKU")
	AB_FIT=$SAGE_FIT
	AB_QUALIFIED=$SAGE_QUALIFIED
	AB_RADIOS=$SAGE_RADIOS
	# Stock OpenWiFi places management DHCP on VLAN 4090 over the up bridge.
	AB_LAN='up0v0 eth0 br-lan.1 br-lan'
	AB_PROTECTED='0:ART'
	AB_HEALTH_TRIES=60
}

ab_sage_boot_command() {
	local format slot="$1"
	case "$slot" in 0|1) ;; *) echo "cambium-ab: invalid slot $slot" >&2; return 1 ;; esac
	format=$(ab_sage_root_format "$slot") || return 1
	(
		SAGE_ROOT_TYPE=$format
		if [ "$AB_SAGE_LEGACY_B" = 1 ] && [ "$slot" = "${AB_ACTIVE:-}" ]; then
			# Preserve the proven E410 FIT on the confirmed legacy B pair.
			SAGE_FIT=config@ap.dk01.1-c2
		fi
		cambium_sage_boot_command "$slot"
	)
	echo
}

# Sage first installs and later upgrades use the shared A/B one-shot trial;
# a single OEM/OpenWrt guarded boot command is not applicable to this pair layout.
ab_sage_guarded_command() {
	return 1
}

ab_sage_running_slot() {
	local slot
	slot=$(CAMBIUM_CMDLINE=${AB_CMDLINE:-/proc/cmdline} cambium_sage_running_slot)
	case "$slot" in
	0|1) echo "$slot" ;;
	*) echo 'cambium-ab: no Sage slot marker or UBIFS root on the kernel command line' >&2; return 1 ;;
	esac
}

# Slot values for the pair layout: both slots live on the "fs" MTD.
ab_sage_identity() {
	local fs slot vol name idx flags root0 root1
	[ "$SAGE_QUALIFIED" = 1 ] || {
		echo "cambium-ab: the $AB_MODEL flash layout has not been captured" >&2
		return 1
	}
	fs=$(ab_mtd_index "$SAGE_UBI_PART")
	case "$fs" in
	''|*[!0-9]*) echo "cambium-ab: missing or duplicate $SAGE_UBI_PART partition" >&2; return 1 ;;
	esac
	slot=$(ab_running_slot) || return 1
	AB_ACTIVE=$slot
	AB_TARGET=$((1 - slot))
	AB_ACTIVE_MTD=$fs
	AB_TARGET_MTD=$fs
	AB_TARGET_PART="linux$AB_TARGET/rootfs$AB_TARGET"
	AB_ACTIVE_UBI=$(ab_ubi_for_mtd "$fs") || {
		echo "cambium-ab: no UBI device is attached to $SAGE_UBI_PART" >&2
		return 1
	}
	for vol in linux0 rootfs0 linux1 rootfs1; do
		ab_ubi_volume "$AB_ACTIVE_UBI" "$vol" >/dev/null || {
			echo "cambium-ab: no UBI volume $vol" >&2
			return 1
		}
	done
	root0=$(ab_ubi_volume "$AB_ACTIVE_UBI" rootfs0) || return 1
	root1=$(ab_ubi_volume "$AB_ACTIVE_UBI" rootfs1) || return 1
	[ "${root0#*_}:${root1#*_}" = "1:3" ] || {
		echo "cambium-ab: Sage rootfs volume IDs changed (expected 1:3)" >&2
		return 1
	}
	for name in $AB_PROTECTED; do
		idx=$(ab_mtd_index "$name")
		[ -n "$idx" ] || { echo "cambium-ab: missing protected $name" >&2; return 1; }
		flags=$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/flags") || return 1
		[ $(( flags & 0x400 )) -eq 0 ] || {
			echo "cambium-ab: protected $name is writable" >&2
			return 1
		}
	done
}

# The reserved capacity is stable even when recovery staging temporarily
# shrinks a dynamic rootfs volume's data_bytes to the FIT's length.
ab_sage_volume_bytes() {
	local vol base lebs lebsize
	vol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "$1") || return 1
	base=${AB_UBI_SYS:-/sys/class/ubi}/$vol
	lebs=$(cat "$base/reserved_ebs") || return 1
	lebsize=$(cat "$base/usable_eb_size") || return 1
	echo $((lebs * lebsize))
}

# Existing stock/transition installations have 372 rootfs LEBs per pair.
# Reserve 67 of those LEBs (about 8 MiB) for this pair's writable overlay.
# Shrink only the inactive volume; its UBI ID must remain 1 or 3.
AB_SAGE_ROOT_LEBS=305
AB_SAGE_DATA_LEBS=67

ab_sage_root_format() {
	local vol
	[ -n "${AB_ACTIVE_UBI:-}" ] || { echo ubifs; return 0; }
	vol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "rootfs$1") || return 1
	if [ "$(head -c 4 "${AB_DEV:-/dev}/$vol" 2>/dev/null)" = hsqs ]; then
		echo squashfs
	else
		echo ubifs
	fi
}

ab_sage_image_fits() {
	local root_lebs free data_lebs rootvol
	[ "$1" -le "$(ab_sage_volume_bytes "linux$AB_TARGET")" ] ||
		ab_fail "the kernel ($1 bytes) does not fit linux$AB_TARGET" || return 1
	rootvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "rootfs$AB_TARGET") || return 1
	root_lebs=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$rootvol/reserved_ebs") || return 1
	if [ "$(head -c 4 "$AB_ROOT")" != hsqs ]; then
		[ "$2" -le "$(ab_sage_volume_bytes "rootfs$AB_TARGET")" ] ||
			ab_fail "the transitional UBIFS root does not fit rootfs$AB_TARGET"
		return
	fi
	[ "$root_lebs" -ge "$AB_SAGE_ROOT_LEBS" ] &&
		[ "$2" -le $((AB_SAGE_ROOT_LEBS * AB_LEB)) ] ||
		ab_fail "SquashFS needs at most $AB_SAGE_ROOT_LEBS LEBs in rootfs$AB_TARGET" || return 1
	if data_lebs=$(ab_ubi_volume "$AB_ACTIVE_UBI" "rootfs_data$AB_TARGET"); then
		data_lebs=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$data_lebs/reserved_ebs") || return 1
		[ "$data_lebs" -ge "$AB_SAGE_DATA_LEBS" ] ||
			ab_fail "rootfs_data$AB_TARGET is smaller than $AB_SAGE_DATA_LEBS LEBs"
	else
		free=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$AB_ACTIVE_UBI/avail_eraseblocks") || return 1
		[ $((free + root_lebs - AB_SAGE_ROOT_LEBS)) -ge "$AB_SAGE_DATA_LEBS" ] ||
			ab_fail "not enough free UBI eraseblocks for rootfs_data$AB_TARGET"
	fi
}

ab_sage_prepare_overlay() {
	local dev=${AB_DEV:-/dev} ubi=$AB_ACTIVE_UBI slot=$AB_TARGET rootvol root_lebs datavol
	rootvol=$(ab_ubi_volume "$ubi" "rootfs$slot") || return 1
	root_lebs=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$rootvol/reserved_ebs") || return 1
	if [ "$root_lebs" -gt "$AB_SAGE_ROOT_LEBS" ]; then
		ab_step "shrink inactive rootfs$slot" ubirsvol "$dev/$ubi" -n "${rootvol##*_}" -s $((AB_SAGE_ROOT_LEBS * AB_LEB)) || return 1
		[ "$(ab_ubi_volume "$ubi" "rootfs$slot")" = "$rootvol" ] || {
			AB_STEP_ERROR="rootfs$slot changed UBI volume ID during resize"
			return 1
		}
	fi
	if ! datavol=$(ab_ubi_volume "$ubi" "rootfs_data$slot"); then
		ab_step "create rootfs_data$slot" ubimkvol "$dev/$ubi" -N "rootfs_data$slot" -s $((AB_SAGE_DATA_LEBS * AB_LEB)) || return 1
		datavol=$(ab_ubi_volume "$ubi" "rootfs_data$slot") || return 1
	fi
	AB_SAGE_DATA_VOL=$datavol
	ab_step "mknod $datavol" ab_ubi_node "$datavol"
}

# Write only the inactive pair. A UBIFS image remains accepted for the
# stock-to-transition install; normal upgrades write SquashFS plus this pair's
# fresh overlay. A failed resize or write never touches the running pair.
ab_sage_write_target() {
	local dev=${AB_DEV:-/dev} kvol rvol mnt=${AB_NEWROOT:-/tmp/cambium-ab-newroot} rc=0
	local batch=/tmp/cambium-ab-sage.$$ format=ubifs data_vol
	kvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "linux$AB_TARGET") &&
		rvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "rootfs$AB_TARGET") || {
		ab_record_failure write-failed "no linux$AB_TARGET/rootfs$AB_TARGET volumes"
		return 1
	}
	[ "$(head -c 4 "$AB_ROOT")" != hsqs ] || format=squashfs
	# A failed or interrupted write must not advertise a damaged OEM pair.
	if [ "$(ab_getenv sage_oem_fallback)" = "$AB_TARGET" ]; then
		ab_setenv sage_oem_fallback || {
			ab_record_failure write-failed "cannot retire OEM fallback marker"
			return 1
		}
	fi
	if [ "$format" = squashfs ]; then
		ab_sage_prepare_overlay || {
			ab_record_failure write-failed "cannot prepare the inactive pair's overlay"
			return 1
		}
	fi
	ab_step "mknod $kvol" ab_ubi_node "$kvol" &&
		ab_step "mknod $rvol" ab_ubi_node "$rvol" &&
		ab_step "ubiupdatevol linux$AB_TARGET" ubiupdatevol "$dev/$kvol" "$AB_KERNEL" &&
		ab_step "ubiupdatevol rootfs$AB_TARGET" ubiupdatevol "$dev/$rvol" "$AB_ROOT" || {
		ab_record_failure write-failed "cannot write pair $AB_TARGET"
		return 1
	}
	ab_verify_volume "$dev/$kvol" "$AB_KERNEL" "$AB_KERNEL_SIZE" &&
		ab_verify_volume "$dev/$rvol" "$AB_ROOT" "$AB_ROOT_SIZE" || {
		AB_STEP_ERROR=
		ab_record_failure write-failed "pair $AB_TARGET readback mismatch"
		return 1
	}
	data_vol=$rvol
	if [ "$format" = squashfs ]; then
		data_vol=$AB_SAGE_DATA_VOL
		ab_step "clear rootfs_data$AB_TARGET" ubiupdatevol -t "$dev/$data_vol" || {
			ab_record_failure write-failed "cannot reset rootfs_data$AB_TARGET"
			return 1
		}
	fi
	if [ "$format" = squashfs ] || [ -n "${UPGRADE_BACKUP:-}" ]; then
		mkdir -p "$mnt"
		ab_step "mount $data_vol" mount -t ubifs "$dev/$data_vol" "$mnt" || {
			ab_record_failure write-failed "cannot initialize the new writable root"
			return 1
		}
		if [ -n "${UPGRADE_BACKUP:-}" ]; then
			ab_step "keep the configuration" cp "$UPGRADE_BACKUP" "$mnt/${BACKUP_FILE:-sysupgrade.tgz}" || rc=1
		fi
		sync
		umount "$mnt" || rc=1
		rmdir "$mnt" 2>/dev/null
		[ "$rc" = 0 ] || {
			ab_record_failure write-failed "cannot keep the configuration in pair $AB_TARGET"
			return 1
		}
	fi
	{ echo 'sage_ab_version 1'; echo "sage_ab_confirmed $AB_ACTIVE"; } > "$batch"
	ab_setenv_batch "$batch" || rc=1
	rm -f "$batch"
	[ "$rc" = 0 ] || ab_record_failure write-failed "cannot record the A/B state"
}

# During transition either UBIFS is the root, or SquashFS is /rom with a
# writable UBIFS overlay. Never commit a trial running on a temporary overlay.
ab_sage_root_healthy() {
	awk '
		$2 == "/" && $3 == "ubifs" && $4 ~ /^rw/ { legacy = 1 }
		$2 == "/" && $3 == "overlay" && $4 ~ /^rw/ { merged = 1 }
		$2 == "/rom" && $3 == "squashfs" { rom = 1 }
		$2 == "/overlay" && $3 == "ubifs" && $4 ~ /^rw/ { data = 1 }
		END { exit !(legacy || (merged && rom && data)) }
	' "${AB_PROC_MOUNTS:-/proc/mounts}"
}
