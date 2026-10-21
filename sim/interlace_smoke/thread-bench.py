#!/usr/bin/env python3
"""Measure the video-enabled MD model and compare every local capture byte."""
import argparse
import filecmp
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('rom', type=Path)
p.add_argument('output', type=Path, help='new local output directory; never upload it')
p.add_argument('--variant', choices=('standard', 'hz120'), default='standard')
p.add_argument('--frames', type=int, default=120)
a = p.parse_args()
rom, out = a.rom.resolve(), a.output.resolve()
if not rom.is_file() or a.frames < 60:
    p.error('supply a local ROM and at least 60 frames')
here = Path(__file__).resolve().parent
root = here.parent.parent
out.mkdir(parents=True, exist_ok=False)
image = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', 'verilator/verilator:latest'], text=True).strip()
(out / 'image.txt').write_text(image + '\n')
runner = shlex.split(os.environ.get('DOCKER_RUN', 'simrun' if shutil.which('simrun') else 'docker run --rm'))
cache = [] if any('simrun' in x for x in runner) else ['-e', 'CCACHE_DISABLE=1']
rows = []
baseline = None
for threads in (1, 2, 4, 8):
    tag = 'threads' + str(threads)
    env = os.environ.copy()
    env['VERILATOR_THREADS'] = str(threads)
    env['MD_CAPTURE_HDMI'] = '1'
    # The harness tests presence, so HZ120=0 also selects the hz120 clock.
    env.pop('HZ120', None)
    if a.variant == 'hz120':
        env['HZ120'] = '1'
    prefix = env.get('SIM_PREFIX', 'sim' + str(os.getpid()))
    start = time.monotonic()
    with (out / (tag + '-build.log')).open('w') as log:
        subprocess.run(runner + cache + ['--name', prefix + '_mdvideo_' + tag, '--user', f'{os.getuid()}:{os.getgid()}',
                       '-v', str(root) + ':' + str(root) + ':ro', '-v', str(out) + ':' + str(out),
                       '-w', str(here), '-e', 'SMOKE_BUILD=' + str(out / 'models'),
                       '-e', 'VARIANT=' + a.variant, '-e', 'VERILATOR_THREADS=' + str(threads),
                       '--entrypoint', 'sh', image, 'build.sh', tag, str(root)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    model_dir = out / 'models/md' / tag / 'obj/obj'
    compiled = [int(m.group(1)) for f in model_dir.glob('*.cpp')
                for m in re.finditer(r'::threads\(\) const \{ return (\d+);', f.read_text())]
    if compiled != [threads]:
        raise RuntimeError(f'generated model thread count {compiled}, expected {threads}')
    build = time.monotonic() - start
    captures = out / tag
    captures.mkdir()
    for microcode in (root / 'src/fx68k').glob('*.mem'):
        shutil.copy2(microcode, captures)
    start = time.monotonic()
    with (captures / 'game.stdout').open('w') as stdout, (captures / 'game.stderr').open('w') as stderr:
        subprocess.run([str(model_dir / 'Vmdtang_smoke'), str(rom), str(a.frames), 'game',
                        str(here / 'sonic2-2p.txt'), str(a.frames // 2)],
                       cwd=captures, env=env, stdout=stdout, stderr=stderr, check=True)
    elapsed = time.monotonic() - start
    runtime = re.search(r'model threads: (\d+)', (captures / 'game.stderr').read_text())
    if not runtime or int(runtime.group(1)) != threads:
        raise RuntimeError('runtime thread pool does not match compiled model')
    files = sorted(x.name for x in captures.glob('game*') if x.suffix in ('.ppm', '.aud', '.bin', '.log'))
    if not any(f.startswith('game_hdmi_') and f.endswith('.ppm') for f in files):
        raise RuntimeError('missing HDMI framebuffer captures')
    if not all(any(f.endswith(suffix) for f in files) for suffix in ('.ppm', '.aud', '.bin', '.log')):
        raise RuntimeError('missing frame/audio/RAM/log captures')
    if threads == 1:
        baseline = files
        identical = True
    else:
        identical = files == baseline and all(filecmp.cmp(out / 'threads1' / f, captures / f, shallow=False) for f in files)
    row = dict(threads=threads, variant=a.variant, build_seconds=round(build, 2), run_seconds=round(elapsed, 2),
               identical=identical, captured_files=len(files), frames=sum(f.endswith('.ppm') for f in files),
               ram=sum(f.endswith('.bin') for f in files), audio=sum(f.endswith('.aud') for f in files),
               speedup=round(rows[0]['run_seconds'] / elapsed, 3) if rows else 1.0)
    rows.append(row)
    (out / 'measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(row), flush=True)
if any(not row['identical'] for row in rows):
    raise RuntimeError('capture bytes changed; leave model threading disabled')
