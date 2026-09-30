#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Write a FIT image source holding one kernel and several board device trees.
# Cambium's OEM U-Boot boots a named configuration (for example config@5 or
# config@hk02), so each board keeps the configuration name used by the OEM
# family image. Several configurations may share one device tree.
#
# Usage: cambium-family-its.sh -k KERNEL -A ARCH -C COMP -a LOAD -e ENTRY \
#          -d DESCRIPTION [-D DEFAULT] CONFIG:FDT:DTB...
# DEFAULT names the default configuration; it defaults to the first CONFIG.

set -eu

usage() {
	echo "Usage: $0 -k kernel -A arch -C compression -a load -e entry -d description [-D default] config:fdt:dtb..." >&2
	exit 2
}

kernel= arch= comp= load= entry= desc= default=
while getopts "k:A:C:a:e:d:D:" opt; do
	case "$opt" in
	k) kernel=$OPTARG ;;
	A) arch=$OPTARG ;;
	C) comp=$OPTARG ;;
	a) load=$OPTARG ;;
	e) entry=$OPTARG ;;
	d) desc=$OPTARG ;;
	D) default=${OPTARG#config@} ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ -n "$kernel" ] && [ -n "$arch" ] && [ -n "$comp" ] && [ -n "$load" ] && [ "$#" -gt 0 ] || usage
[ -n "$entry" ] || entry=$load
[ -n "$default" ] || default=$(echo "$1" | cut -d: -f1)
[ -s "$kernel" ] || { echo "$0: missing kernel $kernel" >&2; exit 1; }

hashes='      hash@1 { algo = "crc32"; };
      hash@2 { algo = "sha1"; };'

cat <<EOF
/dts-v1/;

/ {
  description = "$desc";
  #address-cells = <1>;

  images {
    kernel@1 {
      description = "$desc kernel";
      data = /incbin/("$kernel");
      type = "kernel";
      arch = "$arch";
      os = "linux";
      compression = "$comp";
      load = <$load>;
      entry = <$entry>;
$hashes
    };
EOF

seen=' '
for board in "$@"; do
	fdt=$(echo "$board" | cut -d: -f2)
	dtb=$(echo "$board" | cut -d: -f3-)
	case "$seen" in *" $fdt "*) continue ;; esac
	seen="$seen$fdt "
	[ -s "$dtb" ] || { echo "$0: missing device tree $dtb" >&2; exit 1; }
	cat <<EOF
    fdt@$fdt {
      description = "${dtb##*/}";
      data = /incbin/("$dtb");
      type = "flat_dt";
      arch = "$arch";
      compression = "none";
$hashes
    };
EOF
done

cat <<EOF
  };

  configurations {
    default = "config@$default";
EOF

for board in "$@"; do
	config=$(echo "$board" | cut -d: -f1)
	fdt=$(echo "$board" | cut -d: -f2)
	cat <<EOF
    config@$config {
      description = "$desc ($config)";
      kernel = "kernel@1";
      fdt = "fdt@$fdt";
    };
EOF
done

cat <<EOF
  };
};
EOF
