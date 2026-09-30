# Cambium A/B sysupgrade: write only the inactive firmware bank, verify it, then arm a one-shot trial whose first durable
# step restores the old bank as the default. The boot guard commits the new
# bank only after its health checks pass. Nothing here falls back to the
# generic nand_do_upgrade/default_do_upgrade paths.
#
# Test hooks: CAMBIUM_AB_LIB, AB_DEV and the hooks listed in
# /lib/functions/cambium-ab.sh.

. "${CAMBIUM_AB_LIB:-/lib/functions/cambium-ab.sh}"

# The image directory (AB_IMAGE_DIR) and the bank's usable LEBs
# (AB_BANK_LEBS) come from the family module's board table.
AB_VAULT_LEBS=8
# Smallest writable overlay a new bank may get (8 MiB).
AB_MIN_DATA_LEBS=67

ab_lebs() {
	echo $(( ($1 + AB_LEB - 1) / AB_LEB ))
}

# LEBs the device-data vault takes in a bank: none for a family without one.
ab_vault_lebs() {
	if [ "$AB_VAULT" = 1 ]; then echo "$AB_VAULT_LEBS"; else echo 0; fi
}

ab_fail() {
	echo "A/B sysupgrade: $*" >&2
	return 1
}

# ab_step DESCRIPTION COMMAND...: run one write step. Its output goes to
# $AB_LOG; on failure AB_STEP_ERROR names the step, its exit status
# and last error line, and is what the environment records as the failure,
# since stage 2's own output is lost when it reboots.
ab_step() {
	local desc=$1 rc err log=${AB_LOG:-/tmp/cambium-ab-upgrade.log}
	shift
	"$@" >>"$log" 2>"$log.err"; rc=$?
	cat "$log.err" >>"$log"
	[ "$rc" = 0 ] && return 0
	err=$(grep . "$log.err" | tail -n 1 | tr -d '\r' | cut -c1-120)
	AB_STEP_ERROR="$desc: exit $rc${err:+: $err}"
	echo "A/B sysupgrade: $AB_STEP_ERROR" >&2
	return "$rc"
}

# Extract and check the image's kernel FIT and root filesystem into
# $AB_WORK. Sets AB_KERNEL_SIZE and AB_ROOT_SIZE.
ab_image_extract() {
	local image="$1" magic
	AB_WORK=${AB_WORK:-/tmp/cambium-ab-upgrade}
	rm -rf "$AB_WORK" && mkdir -p "$AB_WORK" || return 1
	tar -xf "$image" -C "$AB_WORK" "$AB_IMAGE_DIR/kernel" "$AB_IMAGE_DIR/root" 2>/dev/null ||
		ab_fail "image has no $AB_IMAGE_DIR/kernel and root" || return 1
	AB_KERNEL=$AB_WORK/$AB_IMAGE_DIR/kernel
	AB_ROOT=$AB_WORK/$AB_IMAGE_DIR/root
	magic=$(hexdump -n 4 -v -e '4/1 "%02x"' "$AB_KERNEL")
	[ "$magic" = d00dfeed ] || ab_fail "kernel is not a FIT image" || return 1
	# A FIT node name follows the FDT_BEGIN_NODE token, which ends in 0x01.
	tr '\000' '\n' < "$AB_KERNEL" | grep -q "^$(printf '\001')$AB_FIT\$" ||
		ab_fail "FIT lacks $AB_FIT for $AB_MODEL" || return 1
	if [ "$AB_ROOT_MAGIC" = hsqs ]; then
		[ "$(head -c 4 "$AB_ROOT")" = hsqs ] || ab_fail "root is not SquashFS" || return 1
	else
		[ "$(hexdump -n 4 -v -e '4/1 "%02x"' "$AB_ROOT")" = "$AB_ROOT_MAGIC" ] ||
			ab_fail "root is not the $AB_NAME root filesystem type" || return 1
	fi
	AB_KERNEL_SIZE=$(wc -c < "$AB_KERNEL")
	AB_ROOT_SIZE=$(wc -c < "$AB_ROOT")
	if ab_hook image_fits; then
		"ab_${AB_FAMILY}_image_fits" "$AB_KERNEL_SIZE" "$AB_ROOT_SIZE" || return 1
		return 0
	fi
	[ $(( $(ab_lebs "$AB_KERNEL_SIZE") + $(ab_lebs "$AB_ROOT_SIZE") + \
		$(ab_vault_lebs) + AB_MIN_DATA_LEBS )) -le "$AB_BANK_LEBS" ] ||
		ab_fail "image does not fit this $AB_MODEL bank ($AB_BANK_LEBS LEBs) with the vault and overlay" || return 1
}

# Everything a normal A/B upgrade requires of the running system.
ab_upgrade_preflight() {
	local state
	ab_identity || return 1
	# A pair-layout family (Sage) has no conversion step: writing the other
	# slot replaces whatever it held, as its first upgrade always has.
	[ "$AB_LAYOUT" = pair ] || ab_converted ||
		ab_fail "this AP still has one OEM slot; run cambium-ab-convert first" || return 1
	ab_mtd_writable "$AB_TARGET_MTD" ||
		ab_fail "target bank $AB_TARGET_PART is read-only (not an A/B image)" || return 1
	[ "$AB_MARKER" != 1 ] || [ "$(ab_getenv changing_bootcmd)" = 1 ] ||
		ab_fail "changing_bootcmd is not saved" || return 1
	state=$(ab_getenv ${AB_ENV}_ab_state)
	case "$state" in
	trial-started|armed)
		ab_fail "a trial of slot $(ab_getenv ${AB_ENV}_ab_target) is not confirmed yet" || return 1
		;;
	esac
	[ "$AB_VAULT" != 1 ] || ab_ubi_volume "$AB_ACTIVE_UBI" cambium_device_data >/dev/null ||
		ab_fail "the running bank has no device-data vault" || return 1
}

cambium_ab_check_image() {
	ab_upgrade_preflight || return 1
	[ "$AB_VAULT" != 1 ] || ${AB_BOARD_DATA:-/usr/sbin/cambium-board-data} --check-vault ||
		ab_fail "the device-data vault is missing or does not match this AP" || return 1
	ab_image_extract "$1" || return 1
	rm -rf "$AB_WORK"
}

# ab_record_failure STATE MESSAGE: the failing step's own error, if one
# was captured, replaces MESSAGE.
ab_record_failure() {
	local batch=/tmp/cambium-ab-env-fail.$$ msg=${AB_STEP_ERROR:-$2}
	printf "${AB_ENV}_ab_state %s\n${AB_ENV}_ab_last_failure %s\n" "$1" "$msg" > "$batch"
	ab_setenv_batch "$batch" >/dev/null 2>&1
	rm -f "$batch"
	ab_fail "$msg"
}

# Readback: the first $3 bytes of volume $1 must hash like file $2.
ab_verify_volume() {
	[ "$(head -c "$3" "$1" | sha256sum | cut -d' ' -f1)" = \
		"$(sha256sum < "$2" | cut -d' ' -f1)" ]
}

# Format the inactive bank and create kernel (0), rootfs (1), the vault (3)
# if the family keeps one, and rootfs_data (2) from the remaining space. Sets AB_TARGET_UBI.
ab_prepare_bank() {
	local kernel_size="$1" root_size="$2" dev=${AB_DEV:-/dev} data ubi
	if ab_ubi_for_mtd "$AB_TARGET_MTD" >/dev/null; then
		ab_step "ubidetach mtd$AB_TARGET_MTD" ubidetach -m "$AB_TARGET_MTD" || return 1
	fi
	ab_step "ubiformat mtd$AB_TARGET_MTD" ubiformat "$dev/mtd$AB_TARGET_MTD" -y -q || return 1
	ab_step "ubiattach mtd$AB_TARGET_MTD" ubiattach -m "$AB_TARGET_MTD" || return 1
	ubi=$(ab_ubi_for_mtd "$AB_TARGET_MTD") || {
		AB_STEP_ERROR="no UBI device for mtd$AB_TARGET_MTD after ubiattach"
		return 1
	}
	AB_TARGET_UBI=$ubi
	ab_step "mknod $ubi" ab_ubi_node "$ubi" &&
		ab_step "ubimkvol $ubi kernel" ubimkvol "$dev/$ubi" -n 0 -N kernel -s "$kernel_size" &&
		ab_step "mknod ${ubi}_0" ab_ubi_node "${ubi}_0" &&
		ab_step "ubimkvol $ubi rootfs" ubimkvol "$dev/$ubi" -n 1 -N rootfs -s "$root_size" &&
		ab_step "mknod ${ubi}_1" ab_ubi_node "${ubi}_1" || return 1
	if [ "$AB_VAULT" = 1 ]; then
		ab_step "ubimkvol $ubi vault" ubimkvol "$dev/$ubi" -n 3 -N cambium_device_data \
			-s $((AB_VAULT_LEBS * AB_LEB)) &&
			ab_step "mknod ${ubi}_3" ab_ubi_node "${ubi}_3" || return 1
	fi
	ab_step "ubimkvol $ubi rootfs_data" ubimkvol "$dev/$ubi" -n 2 -N rootfs_data -m &&
		ab_step "mknod ${ubi}_2" ab_ubi_node "${ubi}_2" || return 1
	data=$(cat "${AB_UBI_SYS:-/sys/class/ubi}/${ubi}_2/data_bytes") || return 1
	[ "$data" -ge $((AB_MIN_DATA_LEBS * AB_LEB)) ] || {
		AB_STEP_ERROR="only $data bytes left for rootfs_data"
		ab_fail "$AB_STEP_ERROR"
	}
}

# Copy the running bank's vault to the target bank and compare it.
ab_copy_vault() {
	local dev=${AB_DEV:-/dev} src dst copy=/tmp/cambium-ab-vault.$$
	src=$dev/$(ab_ubi_volume "$AB_ACTIVE_UBI" cambium_device_data) || return 1
	dst=$dev/${AB_TARGET_UBI}_3
	cat "$src" > "$copy" && ab_step "ubiupdatevol vault" ubiupdatevol "$dst" "$copy" &&
		ab_verify_volume "$dst" "$copy" "$(wc -c < "$copy")"
	local rc=$?
	rm -f "$copy"
	return "$rc"
}

# Arm the one-shot trial of the written bank. bootcmd is the last write.
ab_arm_trial() {
	local batch=/tmp/cambium-ab-env-arm.$$ trial rc=0
	trial=$(ab_trial_command "$AB_ACTIVE" "$AB_TARGET") || return 1
	ab_write_boot_vars || return 1
	printf "${AB_ENV}_ab_state armed\n${AB_ENV}_ab_target %s\n" "$AB_TARGET" > "$batch"
	ab_setenv_batch "$batch" || rc=1
	rm -f "$batch"
	[ "$rc" = 0 ] && ab_setenv bootcmd "$trial"
}

cambium_ab_do_upgrade() {
	local dev=${AB_DEV:-/dev} batch=/tmp/cambium-ab-env-write.$$
	AB_STEP_ERROR=
	ab_upgrade_preflight || return 1
	ab_image_extract "$1" || return 1

	# Record the write before touching the bank. bootcmd still boots the
	# running bank first, so an interrupted write never loses it.
	printf "${AB_ENV}_ab_state writing\n${AB_ENV}_ab_target %s\n" "$AB_TARGET" > "$batch"
	ab_setenv_batch "$batch" || { rm -f "$batch"; ab_fail "cannot record the upgrade"; return 1; }
	rm -f "$batch"

	echo "cambium-ab: writing slot $AB_TARGET ($AB_TARGET_PART) from slot $AB_ACTIVE"
	if ab_hook write_target; then
		"ab_${AB_FAMILY}_write_target" || return 1
		sync
		ab_arm_trial ||
			{ ab_record_failure write-failed "cannot arm the trial of slot $AB_TARGET"; return 1; }
		echo "cambium-ab: slot $AB_TARGET armed for one trial boot; slot $AB_ACTIVE stays the default until it is confirmed"
		return 0
	fi
	ab_prepare_bank "$AB_KERNEL_SIZE" "$AB_ROOT_SIZE" ||
		{ ab_record_failure write-failed "cannot format slot $AB_TARGET"; return 1; }
	ab_step "ubiupdatevol kernel" ubiupdatevol "$dev/${AB_TARGET_UBI}_0" "$AB_KERNEL" &&
		ab_step "ubiupdatevol rootfs" ubiupdatevol "$dev/${AB_TARGET_UBI}_1" "$AB_ROOT" ||
		{ ab_record_failure write-failed "cannot write slot $AB_TARGET"; return 1; }
	ab_verify_volume "$dev/${AB_TARGET_UBI}_0" "$AB_KERNEL" "$AB_KERNEL_SIZE" &&
		ab_verify_volume "$dev/${AB_TARGET_UBI}_1" "$AB_ROOT" "$AB_ROOT_SIZE" ||
		{ AB_STEP_ERROR=; ab_record_failure write-failed "slot $AB_TARGET readback mismatch"; return 1; }
	[ "$AB_VAULT" != 1 ] || ab_copy_vault ||
		{ ab_record_failure write-failed "cannot copy the device-data vault"; return 1; }

	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		CI_UBIPART=$AB_TARGET_PART nand_restore_config "$UPGRADE_BACKUP" ||
			{ ab_record_failure write-failed "cannot save the configuration"; return 1; }
	fi
	sync

	ab_arm_trial ||
		{ ab_record_failure write-failed "cannot arm the trial of slot $AB_TARGET"; return 1; }
	echo "cambium-ab: slot $AB_TARGET armed for one trial boot; slot $AB_ACTIVE stays the default until it is confirmed"
}
