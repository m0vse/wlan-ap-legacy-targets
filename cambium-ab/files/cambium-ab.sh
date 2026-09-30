#!/bin/sh
# Cambium A/B core: identity preflight, U-Boot environment access and the
# stable/trial boot commands shared by every Cambium family with two
# OpenWrt firmware banks. Family modules (/lib/functions/cambium-ab-*.sh)
# describe their boards and U-Boot commands; callers provide board_name().
#
# A family module registers itself in AB_FAMILIES and defines:
#   ab_<family>_board BOARD   set the board table values below, or fail
#   ab_<family>_boot_command SLOT      U-Boot command booting that slot
#   ab_<family>_guarded_command SLOT   one-shot for the one-OEM/one-OpenWrt
#                                      state, restoring the stock default
# and sets for a matching board: AB_NAME, AB_MODEL, AB_SKU (8 hex digits as
# in the device tree), AB_FIT, AB_QUALIFIED (hardware-tested), AB_ENV (the
# prefix of its U-Boot variables, e.g. jaguar_boot0), AB_IMAGE_DIR (the
# sysupgrade tar directory), AB_STOCK_BOOTCMD, AB_VAULT (1: keep a
# device-data vault), and the bank layout: AB_BANK_SIZE (as in /proc/mtd),
# AB_SLOT1_OFFSET, AB_BANK_LEBS (usable LEBs: the bank's PEBs less UBI's
# bad-block reserve of 20 per 1024 PEBs of the whole NAND and 4 PEBs for the
# volume table and wear levelling) and AB_PROTECTED (partitions that must
# stay read-only). Optional: AB_LAN (candidate LAN interfaces for the boot
# guard's DHCP check, first present wins; default br-lan), AB_RADIOS
# (Wi-Fi phys that must be up before a boot counts as healthy; default 0)
# and AB_RADIO_DEVICE (count only the phys of this device, the end of its
# /sys/devices path; default: every phy),
# AB_HEALTH_TRIES (5-second health checks before a boot counts as failed;
# default 60), AB_MARKER (0: this U-Boot needs no changing_bootcmd marker)
# and AB_ROOT_MAGIC (the root image's first four bytes as hex, or hsqs).
#
# A family whose slots are not two MTD banks (Sage: volume pairs in one UBI
# device, AB_LAYOUT=pair) also defines ab_<family>_identity (sets the slot
# values below after the shared board and SKU checks), and may define
# ab_<family>_running_slot, ab_<family>_image_fits KERNEL ROOT,
# ab_<family>_write_target (writes, verifies and carries the configuration
# into the target slot), ab_<family>_root_healthy, ab_<family>_healthy_extra
# and ab_<family>_takeover (adopts an earlier A/B state on first boot:
# returns 0 handled, 1 failed, 2 nothing to adopt).
#
# Test hooks: AB_PROC_MTD, AB_CMDLINE, AB_DT, AB_UBI_SYS, AB_MTD_SYS, AB_SYS_MODULE,
# AB_DEV, CAMBIUM_AB_MODULES.

AB_BANK_ERASE=00020000
AB_LEB=126976

for _ab_module in "${CAMBIUM_AB_MODULES:-/lib/functions}"/cambium-ab-*.sh; do
	[ -f "$_ab_module" ] && . "$_ab_module"
done
unset _ab_module

# ab_board BOARD: find the family module that knows BOARD. Sets AB_FAMILY.
ab_board() {
	local family
	for family in ${AB_FAMILIES:-}; do
		AB_QUALIFIED=0 AB_VAULT=0 AB_STOCK_BOOTCMD=bootipq AB_LAN=br-lan AB_RADIOS=0 AB_RADIO_DEVICE=
		AB_LAYOUT=banks AB_MARKER=1 AB_ROOT_MAGIC=hsqs AB_HEALTH_TRIES=60
		if "ab_${family}_board" "$1"; then
			AB_FAMILY=$family
			return 0
		fi
	done
	return 1
}

# True when this system runs a Cambium image of a family with an A/B
# module. Upstream images of the same boards (e.g. upstream's
# cambiumnetworks,xe3-4) have no cambium-platform node and keep their own
# upgrade path.
ab_family() {
	ab_board "$(board_name)" &&
		[ -e "${AB_DT:-/proc/device-tree}/cambium-platform/board-sku" ]
}

ab_dt_sku() {
	hexdump -v -e '1/1 "%02x"' "${AB_DT:-/proc/device-tree}/cambium-platform/board-sku"
}

ab_mtd_index() {
	awk -v wanted="\"$1\"" '$4 == wanted { sub(/^mtd/, "", $1); sub(/:$/, "", $1); print $1 }' \
		"${AB_PROC_MTD:-/proc/mtd}"
}

ab_mtd_geometry() {
	awk -v wanted="\"$1\"" '$4 == wanted { print $2, $3 }' "${AB_PROC_MTD:-/proc/mtd}"
}

ab_mtd_writable() {
	local flags
	flags=$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$1/flags") || return 1
	[ $(( flags & 0x400 )) -ne 0 ]
}

ab_bank_name() {
	case "$1" in
	0) echo rootfs ;;
	1) echo rootfs_1 ;;
	*) return 1 ;;
	esac
}

# ab_hook NAME: true when the family module defines ab_<family>_NAME.
ab_hook() {
	[ -n "${AB_FAMILY:-}" ] && command -v "ab_${AB_FAMILY}_$1" >/dev/null 2>&1
}

# The slot named by ubi.mtd= on the kernel command line.
ab_running_slot() {
	local arg found slot=
	if ab_hook running_slot; then
		"ab_${AB_FAMILY}_running_slot"
		return
	fi
	for arg in $(cat "${AB_CMDLINE:-/proc/cmdline}"); do
		case "$arg" in
		ubi.mtd=rootfs) found=0 ;;
		ubi.mtd=rootfs_1) found=1 ;;
		ubi.mtd=*) echo "cambium-ab: unexpected $arg" >&2; return 1 ;;
		*) continue ;;
		esac
		[ -z "$slot" ] || [ "$slot" = "$found" ] || {
			echo 'cambium-ab: conflicting ubi.mtd arguments' >&2
			return 1
		}
		slot=$found
	done
	[ -n "$slot" ] || { echo 'cambium-ab: no ubi.mtd slot' >&2; return 1; }
	echo "$slot"
}

# The UBI device attached to MTD number $1.
ab_ubi_for_mtd() {
	local dev
	for dev in "${AB_UBI_SYS:-/sys/class/ubi}"/ubi[0-9]*; do
		case "${dev##*/}" in *_*) continue ;; esac
		[ -f "$dev/mtd_num" ] || continue
		[ "$(cat "$dev/mtd_num")" = "$1" ] && { echo "${dev##*/}"; return 0; }
	done
	return 1
}

# Make sure /dev/$1 exists for a UBI device or volume (ubiN or ubiN_M).
# Sysupgrade stage 2 runs without procd's hotplug handling, so a device
# attached or a volume created there gets no node by itself (nand.sh's
# ubi_mknod exists for the same reason).
ab_ubi_node() {
	local node=${AB_DEV:-/dev}/$1 devid
	[ -e "$node" ] && return 0
	devid=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$1/dev") || return 1
	mknod "$node" c "${devid%%:*}" "${devid##*:}"
}

# The volume node (ubiN_M) named $2 on UBI device $1.
ab_ubi_volume() {
	local vol
	for vol in "${AB_UBI_SYS:-/sys/class/ubi}/$1"_*; do
		[ -f "$vol/name" ] || continue
		[ "$(cat "$vol/name")" = "$2" ] && { echo "${vol##*/}"; return 0; }
	done
	return 1
}

# Read-only preflight. On success sets AB_BOARD and the board table
# values, AB_ACTIVE / AB_TARGET (slots), AB_ACTIVE_MTD /
# AB_TARGET_MTD, AB_TARGET_PART and AB_ACTIVE_UBI. Refuses an
# unknown board or SKU, a changed bank layout, a command line that disagrees
# with the attached UBI device, and any writable calibration or log partition.
ab_identity() {
	local board sku name idx slot flags
	board=$(board_name)
	ab_board "$board" || { echo "cambium-ab: $board has no A/B support" >&2; return 1; }
	sku=$(ab_dt_sku) || { echo 'cambium-ab: no board-sku in the device tree' >&2; return 1; }
	[ "$sku" = "$AB_SKU" ] || {
		echo "cambium-ab: $board has board-sku $sku, expected $AB_SKU" >&2
		return 1
	}
	if ab_hook identity; then
		"ab_${AB_FAMILY}_identity" || return 1
		AB_BOARD=$board
		return 0
	fi
	for slot in 0 1; do
		name=$(ab_bank_name "$slot")
		idx=$(ab_mtd_index "$name")
		case "$idx" in
		''|*[!0-9]*) echo "cambium-ab: missing or duplicate $name" >&2; return 1 ;;
		esac
		[ "$(ab_mtd_geometry "$name")" = "$AB_BANK_SIZE $AB_BANK_ERASE" ] || {
			echo "cambium-ab: unexpected $name geometry: $(ab_mtd_geometry "$name")" >&2
			return 1
		}
		eval "AB_MTD$slot=$idx"
	done
	slot=$(ab_running_slot) || return 1
	AB_ACTIVE=$slot
	AB_TARGET=$((1 - slot))
	eval "AB_ACTIVE_MTD=\$AB_MTD$AB_ACTIVE"
	eval "AB_TARGET_MTD=\$AB_MTD$AB_TARGET"
	AB_TARGET_PART=$(ab_bank_name "$AB_TARGET")
	AB_ACTIVE_UBI=$(ab_ubi_for_mtd "$AB_ACTIVE_MTD") || {
		echo 'cambium-ab: no UBI device is attached to the command-line active slot' >&2
		return 1
	}
	ab_ubi_volume "$AB_ACTIVE_UBI" kernel >/dev/null &&
		ab_ubi_volume "$AB_ACTIVE_UBI" rootfs >/dev/null || {
		echo 'cambium-ab: the active slot lacks kernel/rootfs volumes' >&2
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
	AB_BOARD=$board
}

# The bank size as U-Boot writes it, e.g. 0x6000000.
ab_bank_hex() {
	printf '0x%x\n' $((0x$AB_BANK_SIZE))
}

# U-Boot commands for the family: booting slot $1, and the guarded one-shot
# of the one-OEM/one-OpenWrt state.
ab_boot_command() {
	[ -n "${AB_FIT:-}" ] || { echo 'cambium-ab: FIT configuration not selected' >&2; return 1; }
	"ab_${AB_FAMILY}_boot_command" "$@"
}
ab_guarded_command() {
	"ab_${AB_FAMILY}_guarded_command" "$@"
}

# Stable boot: slot $1, then slot $2 if bootm returns.
ab_stable_command() {
	case "$1:$2" in
	0:1|1:0) echo "run ${AB_ENV}_boot$1; run ${AB_ENV}_boot$2" ;;
	*) echo 'cambium-ab: a stable command needs distinct slots 0 and 1' >&2; return 1 ;;
	esac
}

# One-shot trial of slot $2 from confirmed slot $1. Its first durable step
# restores the stable old-bank default, so a hung new kernel returns to the
# old bank on the next power cycle; bootm returning tries the old bank now.
# Only named variables are used, so no nested quoting reaches U-Boot.
ab_trial_command() {
	ab_stable_command "$1" "$2" >/dev/null || return 1
	echo "setenv bootcmd run ${AB_ENV}_stable$1; setenv image $1; setenv ${AB_ENV}_ab_state trial-started; saveenv; run ${AB_ENV}_boot$2; run ${AB_ENV}_boot$1"
}

# fw_printenv/fw_setenv against the verified 64 KiB 0:APPSBLENV mapping.
ab_env_config() {
	local idx
	[ -z "${AB_ENV_CONFIG:-}" ] || return 0
	idx=$(ab_mtd_index 0:APPSBLENV)
	[ -n "$idx" ] || { echo 'cambium-ab: no 0:APPSBLENV partition' >&2; return 1; }
	[ "$(ab_mtd_geometry 0:APPSBLENV | cut -d' ' -f1)" = 00010000 ] || {
		echo 'cambium-ab: unexpected 0:APPSBLENV size' >&2
		return 1
	}
	AB_ENV_CONFIG=/tmp/cambium-ab-fw_env.config
	printf '/dev/mtd%s 0x0 0x00010000 0x00010000 1\n' "$idx" > "$AB_ENV_CONFIG"
}

ab_getenv() {
	ab_env_config && fw_printenv -c "$AB_ENV_CONFIG" -n "$1" 2>/dev/null
}

# ab_setenv NAME [VALUE]: write one variable and read it back.
ab_setenv() {
	ab_env_config || return 1
	if [ $# -ge 2 ]; then
		fw_setenv -c "$AB_ENV_CONFIG" "$1" "$2" || return 1
		[ "$(ab_getenv "$1")" = "$2" ]
	else
		fw_setenv -c "$AB_ENV_CONFIG" "$1" || return 1
		[ -z "$(ab_getenv "$1")" ]
	fi
}

# ab_setenv_batch FILE: one environment write from "name value" lines,
# then read every value back.
ab_setenv_batch() {
	local name value
	ab_env_config || return 1
	fw_setenv -c "$AB_ENV_CONFIG" -s "$1" || return 1
	while read -r name value; do
		[ "$(ab_getenv "$name")" = "$value" ] || {
			echo "cambium-ab: environment readback failed for $name" >&2
			return 1
		}
	done < "$1"
}

# True once cambium-ab-convert has made both banks OpenWrt banks.
ab_converted() {
	[ "$(ab_getenv ${AB_ENV}_ab_version)" = 1 ]
}

# Install the boot commands for both slots. changing_bootcmd must already be
# saved as its own write: this U-Boot discards an environment whose bootcmd
# differs from the default while the marker is absent.
ab_write_boot_vars() {
	local batch=/tmp/cambium-ab-env.$$ rc=0
	[ "$AB_MARKER" != 1 ] || [ "$(ab_getenv changing_bootcmd)" = 1 ] || {
		echo 'cambium-ab: changing_bootcmd is not saved' >&2
		return 1
	}
	{
		echo "${AB_ENV}_boot0 $(ab_boot_command 0)"
		echo "${AB_ENV}_boot1 $(ab_boot_command 1)"
		echo "${AB_ENV}_stable0 $(ab_stable_command 0 1)"
		echo "${AB_ENV}_stable1 $(ab_stable_command 1 0)"
	} > "$batch" || rc=1
	[ "$rc" = 0 ] && { ab_setenv_batch "$batch" || rc=1; }
	rm -f "$batch"
	return "$rc"
}
