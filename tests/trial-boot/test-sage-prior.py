#!/usr/bin/env python3
"""Actual Sage renderers, mocked source filesystem-format boundary only."""
from pathlib import Path
import os
import subprocess
import tempfile
REPO=Path(__file__).resolve().parents[2]
CORE=REPO/'cambium-ab/files/cambium-ab.sh'
MODULE=REPO/'cambium-ab/files/cambium-ab-sage.sh'
BOARD=REPO/'cambium-ab/files/cambium-sage.sh'
with tempfile.TemporaryDirectory(prefix='sage-prior-') as td:
 root=Path(td); (root/'dev').mkdir()
 (root/'mtd').write_text('mtd8: 00010000 00010000 "mfginfo"\n')
 total=0
 for board in ('cambiumnetworks,e410','cambiumnetworks,e410b','legacy-b'):
  (root/'dev/mtd8ro').write_bytes(b'\0PL-E410XXXB-EU\0' if board=='legacy-b' else b'\0PL-E410XXXA-EU\0')
  for slot in (0,1):
   script=r'''
. "$CORE"; . "$MODULE"
ab_sage_root_format(){ echo squashfs; }
ab_board "$CASE_BOARD" || exit 1
AB_ACTIVE=$SLOT
expected=$(ab_boot_command "$AB_ACTIVE") || exit 1
fit=$AB_FIT; [ "$AB_SAGE_LEGACY_B" != 1 ] || fit=config@ap.dk01.1-c2
args="mtdparts=spi0.1:128M(fs) ubi.mtd=fs ubi.block=0,rootfs$SLOT root=/dev/ubiblock0_$((2*SLOT+1)) rootfstype=squashfs ro rootwait fstools_overlay_name=rootfs_data$SLOT cambium_sage_slot=$SLOT clk_ignore_unused"
for quote in yes no; do
 if [ "$quote" = yes ]; then
 stored="setenv image $SLOT; setenv bootargs \"$args\"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts \"mtdparts=nand1:0x8000000@0x0(fs)\" && ubi part fs && ubi read 0x84000000 linux$SLOT && bootm 0x84000000#$fit"
 else
 stored="setenv image $SLOT; setenv bootargs $args; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts mtdparts=nand1:0x8000000@0x0(fs) && ubi part fs && ubi read 0x84000000 linux$SLOT && bootm 0x84000000#$fit"
 fi
 ab_sage_prior_boot_valid "$stored" "$expected" || exit 1
 ! ab_sage_prior_boot_valid "$stored; nand erase identity" "$expected" || exit 1
 ! ab_sage_prior_boot_valid "$stored" "$expected altered" || exit 1
done
'''
   env=dict(os.environ,CORE=str(CORE),MODULE=str(MODULE),CAMBIUM_SAGE_LIB=str(BOARD),CAMBIUM_AB_MODULES=str(root/'none'),AB_PROC_MTD=str(root/'mtd'),AB_DEV=str(root/'dev'),SLOT=str(slot),CASE_BOARD='cambiumnetworks,e410' if board=='legacy-b' else board)
   result=subprocess.run(['sh','-c',script],env=env,capture_output=True,text=True)
   assert result.returncode==0,(board,slot,result.stderr)
   total+=6
print(f'PASS: {total} actual Sage prior-command compatibility/refusal cases')
print('Only readonly format lookup mocked; no source boot function is rewritten')
