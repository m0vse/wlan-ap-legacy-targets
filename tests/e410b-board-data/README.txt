E410B 5 GHz board-data candidate (offline preparation only)
========================================================

Qualified baseline: legacy d406aede5e5a0f9582208d294a6c77baab04f070,
wlan-ap Sage850b600a44f3a6435343a7ed2f9728ebd54956b7.
Retain the existing qualified SDK, private inputs, driver/header fixes,
calibration loader, A/B, credentials, health and RRM changes. Do not rebase.

Only E410B wifi1 gets qcom,ath10k-calibration-variant=Cambium-E410B-5G.
Only one ID17 variant is appended to the qualified public QCA4019 archive.
All original bytes/entries, E410B2G/ID16, E41020/21 and executable firmware
remain unchanged. Existing per-device factory ART/pre-cal processing stays.

Private input is NOT in this repository. An authorised builder must supply
CAMBIUM_E410B_5G_BDF=/absolute/private/path/to/reviewed-5g-data.bin
when packaging the Sage target. Missing, changed or structurally invalid
input fails packaging; do not release existing staging output after failure.
Input SHA256 is ad5358d27065bba71fa9269634221ca47eefc827ccf39d0e9bc141e4141e8854.
Provenance: retained OEM4.2.3.3-r10 content.bin SHA256
9d07c48c8443949a4c6ea7ec5ca45452949c25c779cb285e30b63de2e06694c8,
XZ tar member lib/firmware/IPQ4019/hw.1/boardData_1_0_IPQ4019_Y9803_wifi1.bin.
No implicit download, data redistribution licence, or permission is inferred.
Do not push the asset, generated archive or candidate firmware to public Git.
Distribution rights must be resolved before publishing an image containing it.

Offline checks (private asset is only read into disposable temporary fixtures):
 python3 tests/e410b-board-data/test-offline.py --base PUBLIC_BOARD2 \
   --oem-content PRIVATE_RETAINED_CONTENT --core QUALIFIED_ATH10K_5_7_CORE_C
 python3 tests/e410b-board-data/test-fit.py --sdk EXISTING_QUALIFIED_SDK \
   --candidate-dts ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-cambium-e410b.dts \
   --its-script ipq40xx/image/cambium-family-its.sh --qualified-fit QUALIFIED_FIT
The latter compiles only device trees and assembles a disposable test FIT
around the existing kernel; it does not run a full firmware build.

Normal upgrade handoff, AFTER main review and explicit build approval:
apply this additive legacy commit to the existing qualified source set, retain
all existing inputs, provide the authorised private asset, rebuild only the
affected package/device-tree outputs plus normal image assembly, and assign
a fresh normal Sage release. Check the final image's actual package, variant,
FIT/model mappings, firmware/pre-cal hashes, permissions and protected files.
Do not reuse offline test FITs as release images. Use the standard sysupgrade
archive and controller publication workflow, not an AP live patch. No updater,
FIT configuration name, supported-model list or archive format is changed.

The candidate is not yet RF-proven. No AP flash, reboot, scan, radio reset,
HIF read, config change, full firmware build or publication is authorised by
this source-preparation task. Keep remote production APs unchanged.
Phil selected PHIL-STUDIO (E410B) for the first future hardware trial, using
the normal controller upgrade after review/build/publication approval. This
does not authorise an automatic flash or any current AP action.
