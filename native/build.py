#!/usr/bin/env python3
"""Build an arm64 iPadOS device executable with an iPhoneOS SDK (17 or later)."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
source = Path(__file__).resolve().parent
object_dir = Path(os.environ.get('OBJDIR', 'build/obj')).resolve()
object_dir.mkdir(parents=True, exist_ok=True)

if sys.platform == 'darwin':
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', 'clang'], text=True).strip()
    linker_options = []
else:
    sdk = os.environ['IPHONEOS_SDK']
    compiler = os.environ['ATLAS_CLANG']
    linker_options = ['-mlinker-version=711', '-fuse-ld=' + os.environ['ATLAS_LINKER']]

flags = [
    '-target', 'arm64-apple-ios17.0', '-isysroot', sdk, '-O2', '-DNDEBUG',
    '-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES', '-fvisibility=hidden', '-I' + str(source / 'miniz'),
]
flags.extend('-I' + str(folder) for folder in (source / 'HTTP').iterdir() if folder.is_dir())
sources = sorted(source.glob('*.m')) + sorted(source.glob('*.c'))
sources += sorted((source / 'miniz').glob('*.c')) + sorted((source / 'HTTP').rglob('*.m'))


def compile_source(path):
    result = object_dir / (path.stem + '.o')
    language_flags = []
    if path.suffix == '.m':
        language_flags = ['-fobjc-arc', '-fblocks', '-Wno-deprecated-declarations']
        if source / 'HTTP' in path.parents:
            language_flags.append('-Wno-incompatible-pointer-types')
    subprocess.run([compiler, *flags, *language_flags, '-c', path, '-o', result], check=True)
    return str(result)


with ThreadPoolExecutor(max_workers=5) as pool:
    objects = list(pool.map(compile_source, sources))

frameworks = [
    'Foundation', 'UIKit', 'WebKit', 'CoreFoundation', 'CoreGraphics', 'QuartzCore',
    'UniformTypeIdentifiers', 'CFNetwork', 'SystemConfiguration', 'MobileCoreServices', 'Security',
]
command = [compiler, *flags, *linker_options, *objects, '-fobjc-arc', '-Wl,-dead_strip', '-lz', '-lobjc']
for framework in frameworks:
    command.extend(['-framework', framework])
command.extend(['-o', args.output.resolve()])
subprocess.run(command, check=True)
