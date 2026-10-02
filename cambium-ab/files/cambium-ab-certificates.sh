# OpenWiFi bank-local certificate retention. No raw UBIFS copying.
# platform_pre_upgrade must call ab_certificate_export after services stop.
# The archive and descriptor must be included in RAMFS_COPY_DATA.
AB_CERTIFICATE_CONTENT_VERSION=1
AB_CERTIFICATE_ARCHIVE=${AB_CERTIFICATE_ARCHIVE:-/tmp/cambium-ab-certificates.tar}
AB_CERTIFICATE_DESCRIPTOR=${AB_CERTIFICATE_DESCRIPTOR:-/tmp/cambium-ab-certificates.descriptor}

ab_certificate_binding() {
	local boot
	boot=$(cat "${AB_BOOT_ID:-/proc/sys/kernel/random/boot_id}") || return 1
	printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$boot" "$AB_FAMILY" "$AB_MODEL" "$AB_SKU" \
		"$AB_ACTIVE" "$AB_TARGET" "$AB_ACTIVE_MTD" "$AB_TARGET_MTD"
}

ab_certificate_private_file() {
	[ -f "$1" ] && [ ! -L "$1" ] &&
		LC_ALL=C ls -ldn "$1" | awk -v owner="${AB_CERTIFICATE_OWNER:-0}" \
			'$1=="-rw-------" && $3==owner { good=1 } END { exit !good }'
}

ab_certificate_tree_safe() {
	# The supported identity store contains only ordinary files/directories.
	# Reject links, devices and unsafe archive names before copying/extraction.
	[ -z "$(find "$1" ! -type f ! -type d -print)" ] || return 1
	(cd "$1" && find . -print) | LC_ALL=C awk '
		/[^A-Za-z0-9_.\/-]/ { bad=1 }
		END { exit bad }'
}

ab_certificate_export() {
	local work source volume mounted=0 runtime=${AB_CERTIFICATE_RUNTIME:-/etc/ucentral}
	local store=${AB_CERTIFICATE_STORE:-/certificates} hash binding rc=0 file magic
	[ "$(ab_certificate_lebs)" = 20 ] || return 0
	ab_identity || return 1
	[ "$AB_LAYOUT" = banks ] || return 0 # Sage's store is shared, not bank-local.
	[ "$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$AB_ACTIVE_UBI/mtd_num")" = "$AB_ACTIVE_MTD" ] ||
		{ ab_fail 'certificate source is not the active bank'; return 1; }
	umask 077
	work=$(mktemp -d /tmp/cambium-ab-certificate-export.XXXXXX) || return 1
	mkdir "$work/tree" "$work/source" || return 1
	volume=$(ab_ubi_volume "$AB_ACTIVE_UBI" certificates) || volume=
	if awk -v path="$store" '$2==path { found=1 } END { exit !found }' "${AB_PROC_MOUNTS:-/proc/mounts}"; then
		[ -n "$volume" ] && awk -v path="$store" -v dev="${AB_DEV:-/dev}/$volume" -v named="$AB_ACTIVE_UBI:certificates" \
			'$2==path && ($1==dev || $1==named) { good=1 } END { exit !good }' "${AB_PROC_MOUNTS:-/proc/mounts}" ||
			{ ab_fail 'mounted certificate store belongs to a different bank'; return 1; }
		source=$store
	elif [ -n "$volume" ]; then
		magic=$(head -c 4 "${AB_DEV:-/dev}/$volume" | hexdump -v -e '4/1 "%02x"') || return 1
		case "$magic" in
		31181006)
			mount -t ubifs -o ro "${AB_DEV:-/dev}/$volume" "$work/source" || return 1
			source=$work/source; mounted=1 ;;
		ffffffff) : ;; # An allocated but never formatted store has no files.
		*) ab_fail 'active certificate volume is not a recognized UBIFS store'; return 1 ;;
		esac
	fi
	if [ -n "${source:-}" ]; then
		ab_certificate_tree_safe "$source" && cp -a "$source/." "$work/tree/" || rc=1
	fi
	if [ "$mounted" = 1 ]; then umount "$work/source" || rc=1; fi
	[ "$rc" = 0 ] || { ab_fail 'cannot safely snapshot the active certificate store'; return 1; }
	# Current runtime credentials and authoritative endpoint policy win over
	# an older persistent copy. This applies independently of SAVE_CONFIG.
	for file in "$runtime/"*.pem "$runtime/"*.ca "$runtime/gateway.json" \
		"$runtime/gateway.flash" "$runtime/discovery-policy.json" "$runtime/restrictions.json" \
		"$runtime/ucentral.defaults"; do
		[ -e "$file" ] || [ -L "$file" ] || continue
		[ -f "$file" ] && [ ! -L "$file" ] && cp "$file" "$work/tree/" || return 1
	done
	if [ -f "$work/tree/key.pem" ] || [ -f "$work/tree/cert.pem" ]; then
		command -v openssl >/dev/null 2>&1 ||
			{ ab_fail 'openssl is required to validate outgoing credentials'; return 1; }
		[ -f "$work/tree/key.pem" ] && [ -f "$work/tree/cert.pem" ] ||
			{ ab_fail 'incomplete bootstrap credential pair'; return 1; }
		# Verify key match without exposing private material in output/logs.
		openssl x509 -in "$work/tree/cert.pem" -pubkey -noout > "$work/cert-public" 2>/dev/null &&
			openssl pkey -in "$work/tree/key.pem" -pubout > "$work/key-public" 2>/dev/null &&
			cmp -s "$work/cert-public" "$work/key-public" ||
			{ ab_fail 'bootstrap certificate and key do not match'; return 1; }
	fi
	ab_certificate_tree_safe "$work/tree" || return 1
	# Normalize privacy regardless of source modes; source is not modified.
	find "$work/tree" -type d -exec chmod 0700 {} \;
	find "$work/tree" -type f -exec chmod 0600 {} \;
	(cd "$work/tree" && find . -type f ! -name .cambium-ab-manifest -exec sha256sum {} \; > .cambium-ab-manifest &&
		tar cf "$work/archive" .) || return 1
	[ "$(wc -c < "$work/archive")" -le $((20 * AB_LEB)) ] ||
		{ ab_fail 'certificate snapshot exceeds reserved volume capacity'; return 1; }
	hash=$(sha256sum "$work/archive"); hash=${hash%% *}
	binding=$(ab_certificate_binding) || return 1
	printf '%s\n%s\n' "$binding" "$hash" > "$work/descriptor" || return 1
	chmod 0600 "$work/archive" "$work/descriptor" || return 1
	mv -f "$work/archive" "$AB_CERTIFICATE_ARCHIVE" &&
		mv -f "$work/descriptor" "$AB_CERTIFICATE_DESCRIPTOR" || return 1
	RAMFS_COPY_DATA="${RAMFS_COPY_DATA:-} $AB_CERTIFICATE_ARCHIVE $AB_CERTIFICATE_DESCRIPTOR"
	RAMFS_COPY_BIN="${RAMFS_COPY_BIN:-} cmp mktemp sha256sum"
	# Temporary source copies intentionally remain private on error for diagnosis.
	rm -rf "$work"
}

ab_certificate_validate_snapshot() {
	local hash expected binding
	[ "$(ab_certificate_lebs)" = 20 ] || return 0
	[ "$AB_LAYOUT" = banks ] || return 0
	ab_certificate_private_file "$AB_CERTIFICATE_ARCHIVE" &&
		ab_certificate_private_file "$AB_CERTIFICATE_DESCRIPTOR" ||
		{ ab_fail 'missing or unsafe RAM-stage certificate snapshot'; return 1; }
	binding=$(ab_certificate_binding) || return 1
	[ "$(sed -n '1p' "$AB_CERTIFICATE_DESCRIPTOR")" = "$binding" ] ||
		{ ab_fail 'certificate snapshot belongs to another boot or bank'; return 1; }
	hash=$(sha256sum "$AB_CERTIFICATE_ARCHIVE"); hash=${hash%% *}
	expected=$(sed -n '2p' "$AB_CERTIFICATE_DESCRIPTOR")
	[ "$hash" = "$expected" ] || { ab_fail 'certificate snapshot checksum failed'; return 1; }
	# Bound the archive again after the RAM copy, and reject special entries.
	[ "$(wc -c < "$AB_CERTIFICATE_ARCHIVE")" -le $((20 * AB_LEB)) ] || return 1
	tar tf "$AB_CERTIFICATE_ARCHIVE" | LC_ALL=C awk '
		/^\// || /(^|\/)\.\.(\/|$)/ || /[^A-Za-z0-9_.\/-]/ { bad=1 }
		END { exit bad }' || return 1
	tar tvf "$AB_CERTIFICATE_ARCHIVE" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { bad=1 } END { exit bad }' || return 1
}

ab_certificate_restore() {
	local work rc=0
	[ "$(ab_certificate_lebs)" = 20 ] || return 0
	[ "$AB_LAYOUT" = banks ] || return 0
	ab_certificate_validate_snapshot || return 1
	[ "$(cat "${AB_UBI_SYS:-/sys/class/ubi}/$AB_TARGET_UBI/mtd_num")" = "$AB_TARGET_MTD" ] &&
		[ "$AB_TARGET_MTD" != "$AB_ACTIVE_MTD" ] || return 1
	umask 077
	work=$(mktemp -d /tmp/cambium-ab-certificate-restore.XXXXXX) || return 1
	mount -t ubifs "${AB_DEV:-/dev}/$(ab_ubi_volume "$AB_TARGET_UBI" certificates)" "$work" || return 1
	tar xf "$AB_CERTIFICATE_ARCHIVE" -C "$work" &&
		(cd "$work" && { [ ! -s .cambium-ab-manifest ] || sha256sum -c .cambium-ab-manifest >/dev/null 2>&1; }) &&
		ab_certificate_tree_safe "$work" || rc=1
	sync
	umount "$work" || rc=1
	rmdir "$work" || rc=1
	[ "$rc" = 0 ] || ab_fail 'inactive certificate store restore or verification failed'
}
