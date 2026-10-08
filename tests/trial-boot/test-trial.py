#!/usr/bin/env python3
"""Real legacy renderer, isolated shell/save/load boundaries; never AP U-Boot."""
from pathlib import Path
import os
import subprocess
import tempfile

CORE = Path(__file__).resolve().parents[2] / 'cambium-ab/files/cambium-ab.sh'
count = 0
with tempfile.TemporaryDirectory(prefix='legacy-trial-') as td:
    root = Path(td)
    for prior in (0,1):
        env = dict(os.environ, CORE=str(CORE), AB_ENV='sage', PRIOR=str(prior),
                   CAMBIUM_AB_MODULES=str(root/'no-modules'))
        trial = subprocess.check_output(['sh','-c','. "$CORE"; ab_trial_command "$PRIOR" "$((1-PRIOR))"'], env=env, text=True).strip()
        for fault in ('bootcmd','image','sage_ab_state','save','load',''):
            trace = root/'trace'; saved = root/'saved'
            trace.unlink(missing_ok=True); saved.unlink(missing_ok=True)
            harness = r'''
setenv(){ key=$1;shift; echo "set:$key" >> "$TRACE";
 [ "$FAIL" != "$key" ] || return 1;
 case "$key" in bootcmd) bootcmd="$*";; image) image="$*";; esac; }
saveenv(){ echo save >> "$TRACE";[ "$FAIL" != save ] || return 1;
 printf '%s\n' "$bootcmd" "$image" > "$SAVED"; }
run(){ case "$1" in
 sage_boot"$PRIOR") echo prior >> "$TRACE";;
 sage_boot*) echo candidate >> "$TRACE";[ "$FAIL" != load ] || return 1;exit 0;;
 *) echo unexpected >> "$TRACE";return 1;; esac; }
'''
            runenv = dict(env, TRACE=str(trace), SAVED=str(saved), FAIL=fault)
            subprocess.run(['sh','-c',harness+'\n'+trial],env=runenv,check=True)
            calls=trace.read_text().splitlines()
            if fault in ('bootcmd','image','sage_ab_state','save'):
                assert 'candidate' not in calls and calls[-1]=='prior' and not saved.exists(),calls
            else:
                durable=saved.read_text().splitlines()
                assert durable==['run sage_boot'+str(prior),str(prior)],durable
                assert calls.index('save')<calls.index('candidate'),calls
                subprocess.run(['sh','-c',harness+'\n'+durable[0]],env=runenv,check=True)
                assert trace.read_text().splitlines()[len(calls):]==['prior']
                if fault=='load':assert calls[-1]=='prior',calls
            count+=1
    for slots in ('0 0','1 1','2 0','0 2'):
        r=subprocess.run(['sh','-c','. "$CORE"; ab_trial_command '+slots],env=env,capture_output=True)
        assert r.returncode!=0
print(f'PASS: {count} legacy trial cases and four invalid-slot refusals')
print('Not real U-Boot, watchdog, flash persistence or hardware power-cut qualification')
