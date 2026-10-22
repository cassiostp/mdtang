#!/usr/bin/env python3
"""Check the actual catalog's clock selection without launching an RTL model."""
import csv
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ClockEnvironmentTest(unittest.TestCase):
    def test_standard_unsets_hz120_and_hz120_sets_it(self):
        sim = Path(__file__).resolve().parent.parent
        state = sim / '.regress'
        state.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=state) as temp:
            root = Path(temp)
            fake_sim = root / 'sim'
            bench = fake_sim / 'interlace_smoke'
            bench.mkdir(parents=True)
            shutil.copy2(sim / 'regress.py', fake_sim / 'regress.py')
            with (sim / 'regress.tsv').open() as f:
                reader = csv.DictReader(f, delimiter='\t')
                fields = reader.fieldnames
                recipe = next(row for row in reader if row['bench'] == 'interlace_smoke')
            # Keep the real post command. Replace only the build and ROM lookup.
            recipe.update(runner='host', command='true', rom='', pre='')
            with (fake_sim / 'regress.tsv').open('w') as f:
                writer = csv.DictWriter(f, fieldnames=fields, delimiter='\t')
                writer.writeheader()
                writer.writerow(recipe)
            microcode = root / 'src/fx68k/test.mem'
            microcode.parent.mkdir(parents=True)
            microcode.write_text('0\n')
            for variant in ('standard', 'hz120'):
                model = bench / 'build/md' / variant / 'obj/obj/Vmdtang_smoke'
                model.parent.mkdir(parents=True)
                model.write_text('''#!/bin/sh
# Match the C++ harness's getenv("HZ120") presence contract.
if [ "${HZ120+x}" = x ]; then echo hz120; else echo standard; fi > clock-mode.txt
''')
                model.chmod(0o755)
            # An inherited zero must not accidentally enable the standard model.
            env = dict(os.environ, HZ120='0', REGRESS_JOBS='1')
            result = subprocess.run(['python3', str(fake_sim / 'regress.py'), 'full', 'both'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for variant in ('standard', 'hz120'):
                outputs = list((fake_sim / '.regress').glob('*/interlace_smoke-' + variant + '-output/clock-mode.txt'))
                self.assertEqual(len(outputs), 1)
                self.assertEqual(outputs[0].read_text().strip(), variant)


if __name__ == '__main__':
    unittest.main()
