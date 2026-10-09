#!/usr/bin/env python3
"""Actual legacy upgrade flow and Sage source renderer, fake storage/ENV only."""
from pathlib import Path
import os
import subprocess
import tempfile
REPO=Path(__file__).resolve().parents[2]
BASE=REPO/'cambium-ab/files'
count=0
with tempfile.TemporaryDirectory(prefix='legacy-prewrite-') as td:
 root=Path(td);(root/'none').mkdir();(root/'empty').write_text('')
 (root/'mtd').write_text('mtd8: 00010000 00010000 "mfginfo"\n');(root/'dev').mkdir()
 for board in ('cambiumnetworks,e410','cambiumnetworks,e410b','legacy-b'):
  (root/'dev/mtd8ro').write_bytes(b'\0PL-E410XXXB-EU\0' if board=='legacy-b' else b'\0PL-E410XXXA-EU\0')
  for slot in (0,1):
   for failure in ('preflight','admission','render','missing','wrong','bootcmd','image','sync','readback','changed','journal','target','arm',''):
    state=root/'state';state.mkdir(exist_ok=True)
    for p in state.iterdir():p.unlink()
    trace=root/'trace';trace.write_text('')
    (root/'target').write_bytes(b'old inactive image')
    script=r'''
. "$CORE"; . "$MODULE"
ab_sage_root_format(){ echo squashfs; }
ab_board "$BOARD" || exit 1
AB_ACTIVE=$PRIOR AB_TARGET=$((1-PRIOR)) AB_LAYOUT=pair
source=$(ab_boot_command "$PRIOR") || exit 1
printf '%s' "$source" > "$STATE/sage_boot$PRIOR"
printf 'run sage_stable%s' "$PRIOR" > "$STATE/bootcmd"
printf '%s' "$PRIOR" > "$STATE/image"
printf 'factory identity unchanged' > "$STATE/factory_id"
[ "$FAIL" != missing ] || rm "$STATE/sage_boot$PRIOR"
[ "$FAIL" != wrong ] || printf 'unknown boot vector' > "$STATE/sage_boot$PRIOR"
. "$UPGRADE"
ab_upgrade_preflight(){ [ "$FAIL" != preflight ]; }
ab_image_extract(){ [ "$FAIL" != admission ]; }
ab_certificate_lebs(){ echo 0; }
real_boot_command=$(ab_boot_command "$PRIOR")
ab_boot_command(){ [ "$FAIL" != render ] && printf '%s' "$real_boot_command"; }
ab_getenv(){
 if [ -s "$TRACE" ] && [ "$FAIL:$1" = readback:bootcmd ]; then echo changed;return;fi
 if [ -s "$TRACE" ] && [ "$FAIL:$1" = "changed:sage_boot$PRIOR" ];then echo changed;return;fi
 cat "$STATE/$1"
}
ab_setenv(){ echo "set:$1" >> "$TRACE";[ "$FAIL" != "$1" ] || return 1;printf '%s' "$2" > "$STATE/$1"; }
sync(){ echo sync >> "$TRACE";[ "$FAIL" != sync ]; }
ab_setenv_batch(){ echo journal >> "$TRACE";[ "$FAIL" != journal ]; }
ab_sage_write_target(){
 echo target >> "$TRACE"
 [ "$(cat "$STATE/bootcmd")" = "run sage_boot$PRIOR" ] && [ "$(cat "$STATE/image")" = "$PRIOR" ] || return 1
 [ "$FAIL" != target ] || return 1
 printf 'new verified image' > "$TARGET"
}
ab_arm_trial(){ echo arm >> "$TRACE";[ "$FAIL" != arm ] || return 1;printf 'armed trial' > "$STATE/bootcmd"; }
cambium_ab_do_upgrade already-local-image
'''
    env=dict(os.environ,CORE=str(BASE/'cambium-ab.sh'),MODULE=str(BASE/'cambium-ab-sage.sh'),CAMBIUM_SAGE_LIB=str(BASE/'cambium-sage.sh'),CAMBIUM_AB_MODULES=str(root/'none'),CAMBIUM_AB_LIB=str(root/'empty'),CAMBIUM_AB_CERTIFICATE_LIB=str(root/'absent'),AB_PROC_MTD=str(root/'mtd'),AB_DEV=str(root/'dev'),UPGRADE=str(BASE/'cambium-ab-upgrade.sh'),STATE=str(state),TRACE=str(trace),TARGET=str(root/'target'),PRIOR=str(slot),FAIL=failure,BOARD='cambiumnetworks,e410' if board=='legacy-b' else board)
    r=subprocess.run(['sh','-c',script],env=env,capture_output=True,text=True)
    calls=trace.read_text().splitlines()
    assert (state/'factory_id').read_text()=='factory identity unchanged'
    if failure not in ('missing','wrong'):
     assert (state/f'sage_boot{slot}').read_text() not in ('unknown boot vector','changed')
    if failure not in ('target','arm',''):
     assert r.returncode!=0 and 'target' not in calls and 'arm' not in calls,(board,slot,failure,calls,r.stderr)
     assert (root/'target').read_bytes()==b'old inactive image'
    else:
     assert calls.index('sync')<calls.index('target')
     assert (r.returncode==0)==(failure==''),(failure,r.stderr)
     if failure:assert (state/'bootcmd').read_text()==f'run sage_boot{slot}'
    count+=1
print(f'PASS: {count} actual legacy/Sage ordered upgrade fault cases, including journal refusal')
print('Storage/ENV/root-format boundaries mocked; not physical NOR, watchdog or power-cut proof')
