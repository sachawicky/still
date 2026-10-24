#!/usr/bin/env python3
"""Kill a disposable native assertion owner, never the installed Still app."""
import pathlib
import select
import subprocess
import sys
import time

binary = pathlib.Path(sys.argv[1]).resolve()
before = subprocess.check_output(['/usr/bin/pmset', '-g'], text=True)
child = subprocess.Popen([str(binary), '--power-assertion-probe'], stdout=subprocess.PIPE, text=True)
try:
    if not select.select([child.stdout], [], [], 5)[0]:
        raise AssertionError('Assertion probe did not become ready')
    reason = child.stdout.readline().strip()
    assert reason.startswith('StillCrashSafetyProbe-'), reason
    live = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True)
    assert reason in live, 'Native assertion was not visible in powerd'
    child.kill()
    child.wait(timeout=5)
    for _ in range(20):
        remaining = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True)
        if reason not in remaining:
            break
        time.sleep(0.1)
    assert reason not in remaining, 'Assertion survived owner SIGKILL'
    after = subprocess.check_output(['/usr/bin/pmset', '-g'], text=True)
    def flag(output):
        return [line.strip() for line in output.splitlines() if 'SleepDisabled' in line]
    assert flag(before) == flag(after), 'Global sleep flag changed during probe'
    print('PASS: native assertion observed in powerd; SIGKILL removed it; SleepDisabled unchanged; installed Still untouched')
finally:
    if child.poll() is None:
        child.kill()
        child.wait(timeout=5)
