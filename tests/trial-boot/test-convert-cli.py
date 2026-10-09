#!/usr/bin/env python3
"""Run the actual CLI with inert library/tool sentinels; never access a device."""
from pathlib import Path
import os
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
CLI = REPO / 'cambium-ab/files/cambium-ab-convert'
with tempfile.TemporaryDirectory(prefix='convert-cli-') as directory:
    root = Path(directory)
    trace = root / 'trace'
    library = root / 'library.sh'
    library.write_text('echo library >> "$TRACE"\nexit 97\n')
    env = dict(os.environ, TRACE=str(trace),
               CAMBIUM_SYSTEM_FUNCTIONS=str(library),
               CAMBIUM_AB_LIB=str(library),
               CAMBIUM_AB_UPGRADE_LIB=str(library))
    count = 0
    for args in (
        ['--allow-untested'],
        ['--yes', '--allow-untested'],
        ['--resume', '--yes', '--allow-untested'],
        ['--allow-untested', '--oem-sha256', 'a' * 64, '--yes'],
        ['--oem-sha256', 'a' * 64, '--yes', '--allow-untested'],
        ['--unknown', '--allow-untested'],
        ['--allow-untested=1', '--yes'],
    ):
        result = subprocess.run(['sh', str(CLI), *args], env=env,
                                capture_output=True, text=True)
        assert result.returncode == 2, (args, result.stderr)
        assert 'validated model' in result.stderr
        assert not trace.exists(), 'library ran before retired-option refusal'
        count += 1
    library.write_text('''
ab_family() { return 0; }
ab_identity() { AB_LAYOUT=bank; AB_MODEL=fixture; AB_QUALIFIED=$QUALIFIED; }
ab_converted() { return 1; }
ab_mtd_writable() { echo qualified-boundary >> "$TRACE"; return 1; }
logger() { :; }
''')
    for args in (['--oem-sha256', 'a' * 64, '--yes'], ['--resume', '--yes']):
        for qualified in ('0', '1'):
            trace.unlink(missing_ok=True)
            result = subprocess.run(['sh', str(CLI), *args],
                                    env=dict(env, QUALIFIED=qualified),
                                    capture_output=True, text=True)
            assert result.returncode == 1, result.stderr
            if qualified == '0':
                assert 'no validated A/B conversion' in result.stderr
                assert not trace.exists(), 'unqualified model reached storage boundary'
            else:
                assert trace.read_text() == 'qualified-boundary\n'
                assert 'read-only' in result.stderr
            count += 1
print(f'PASS: {count} actual conversion CLI cases; libraries/storage mocked, no device writes')
