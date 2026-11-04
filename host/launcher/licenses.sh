#!/usr/bin/env bash
# Generate the app's complete host and guest third-party license inventory from the
# pinned source trees, binary Go build metadata and target-specific Cargo graphs.
# Rebuild work/out/licenses atomically; Go downloads are cached outside the bundle.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
export STEAMAC_ROOT="$ROOT"
python3 - <<'PY'
import atexit
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(os.environ['STEAMAC_ROOT'])
out = root / 'work/out/licenses'
cache = root / 'work/cache/licenses/go-modcache'
cache.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix='.licenses.', dir=out.parent))
atexit.register(lambda: shutil.rmtree(stage) if stage.exists() else None)
entries = []
counts = {}

def run(*args, env=None, cwd=None):
    return subprocess.check_output(args, text=True, env=env, cwd=cwd).strip()

def require(path):
    if not path.is_file():
        raise RuntimeError(f'missing license input: {path}')
    return path
def pinned_text(filename, url):
    path = root / 'work/cache/licenses' / filename
    if not path.is_file():
        path.write_bytes(subprocess.check_output(['curl', '-fsSL', '--retry', '3', url]))
    return require(path).read_bytes()


def spdx(text):
    lower = text.lower()
    if 'cc0 1.0 universal' in lower:
        return 'CC0-1.0'
    if 'gnu general public license' in lower:
        return 'GPL-3.0-or-later' if 'version 3' in lower else 'GPL-2.0-only'
    if 'apache license' in lower or 'apache software license' in lower:
        return 'Apache-2.0'
    if 'redistribution and use in source and binary forms' in lower:
        return 'BSD-3-Clause' if 'neither the name' in lower or 'names of its contributors' in lower else 'BSD-2-Clause'
    if 'permission is hereby granted, free of charge' in lower:
        return 'MIT'
    if 'mozilla public license' in lower:
        return 'MPL-2.0'
    if 'isc license' in lower or 'permission to use, copy, modify, and/or distribute' in lower:
        return 'ISC'
    return 'LicenseRef-See-Included-Text'

def add(name, version, license_id, location, url, documents):
    # documents: sequence of (relative output filename, bytes). Missing notices are fatal.
    if not documents or any(not data or not data.strip() for _, data in documents):
        raise RuntimeError(f'{name} {version}: missing or empty license text')
    dest = stage / name
    dest.mkdir(parents=True)
    for filename, data in documents:
        target = dest / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    entries.append((name, version, license_id or 'LicenseRef-See-Included-Text', location, url))

def top_docs(path):
    return [(f.name, f.read_bytes()) for f in sorted(path.iterdir())
            if f.is_file() and re.match(r'(?i)^(LICENSE|LICENCE|COPYING|NOTICE)([.\-_].*)?$', f.name)]

def source(name, version, license_id, location, url, path, extra=()):
    docs = top_docs(path)
    docs += [(str(p), require(path / p).read_bytes()) for p in extra]
    add(name, version, license_id or spdx(b'\n'.join(data for _, data in docs).decode('utf-8', 'replace')), location, url, docs)

def archive(name, version, license_id, location, url, filename, prefixes):
    docs = []
    with tarfile.open(require(filename), 'r:*') as tar:
        for member in tar:
            parts = Path(member.name).parts
            if not member.isfile() or len(parts) < 2:
                continue
            relative = '/'.join(parts[1:])
            if any(relative == p or relative.startswith(p + '/') for p in prefixes):
                data = tar.extractfile(member).read()
                if data:
                    docs.append((relative, data))
    add(name, version, license_id, location, url, docs)

host = 'Contents/Frameworks'
res = 'Contents/Resources'
launcher = 'Contents/MacOS/steamac-vm'
krun = root / 'work/build/host-libkrun/src'
source('libkrun', '1.19.6', 'Apache-2.0', host + '/libkrun.1.dylib',
       'https://github.com/libkrun/libkrun/tree/v1.19.6', krun)
source('libkrun-rutabaga-gfx', '1.19.6', 'BSD-3-Clause', host + '/libkrun.1.dylib',
       'https://github.com/google/crosvm/tree/main/rutabaga_gfx',
       krun / 'src/rutabaga_gfx', ('ffi/LICENSE',))
source('virglrenderer', '5d26f605+aafa9bd2', 'MIT', host + '/libvirglrenderer.1.dylib',
       'https://github.com/utmapp/virglrenderer', root / 'work/build/host-virglrenderer/src')
mvk = root / 'work/build/host-moltenvk/src'
source('MoltenVK', '05604465', 'Apache-2.0', host + '/libMoltenVK.dylib',
       'https://github.com/utmapp/MoltenVK', mvk)
revisions = mvk / 'ExternalRevisions'
external = mvk / 'External'
for name in ('SPIRV-Cross', 'Vulkan-Headers', 'SPIRV-Tools', 'cereal', 'Volk'):
    path = root / 'work/build/host-moltenvk/SPIRV-Cross' if name == 'SPIRV-Cross' else external / name
    version = require(revisions / (name + '_repo_revision')).read_text().strip()
    extras = [str(p.relative_to(path)) for p in (path / 'LICENSES').rglob('*') if p.is_file()]
    source('MoltenVK-' + name, version, 'Apache-2.0 OR MIT' if name == 'Vulkan-Headers' else None,
           host + '/libMoltenVK.dylib',
           'https://github.com/' + ('utmapp' if name == 'SPIRV-Cross' else 'KhronosGroup' if name != 'cereal' else 'USCiLab') + '/' + name,
           path, extras)
# SPIRV-Headers is checked out within SPIRV-Tools rather than External's top level.
spv_headers = external / 'SPIRV-Tools/external/spirv-headers'
source('MoltenVK-SPIRV-Headers', require(revisions / 'SPIRV-Headers_repo_revision').read_text().strip(),
       'Apache-2.0', host + '/libMoltenVK.dylib', 'https://github.com/KhronosGroup/SPIRV-Headers', spv_headers,
       [str(p.relative_to(spv_headers)) for p in (spv_headers / 'LICENSES').rglob('*') if p.is_file()])
# Vulkan-Tools is fetched by MoltenVK for SDK tooling, not linked into the dylib.
# KosmicKrisp (Mesa), bundled when host/kosmickrisp built it (macOS 26+ build hosts).
if (root / 'work/out/host/lib/libvulkan_kosmickrisp.dylib').is_file():
    mesa = root / 'work/build/host-kosmickrisp/src'
    mesa_commit = re.search(r'^MESA_COMMIT=([0-9a-f]{40})$', (root / 'host/kosmickrisp/build.sh').read_text(), re.M)
    if not mesa_commit:
        raise RuntimeError('missing pinned KosmicKrisp Mesa commit')
    source('KosmicKrisp-Mesa', mesa_commit.group(1)[:10], 'MIT', host + '/libvulkan_kosmickrisp.dylib',
           'https://gitlab.freedesktop.org/mesa/mesa/-/tree/' + mesa_commit.group(1), mesa,
           ['docs/license.rst'] + [str(p.relative_to(mesa)) for p in sorted((mesa / 'licenses').rglob('*')) if p.is_file()])
# DXMT also ships in the guest layer; do not key its inventory only on the host dylib.
wmtr_host = (root / 'work/out/host/lib/libwmtr_host.dylib').is_file()
dxmt_payload = root / 'work/out/dxmt'
dxmt_guest = (dxmt_payload / 'x86_64-unix/winemetal.so').is_file()
if wmtr_host or dxmt_guest:
    dxmt_pin = dict(re.findall(r'^([A-Z][A-Z0-9_]*)=(.*)$',
                              require(root / 'host/dxmt/pin.env').read_text(), re.M))
    dxmt_commit = dxmt_pin['DXMT_COMMIT']
    dxmt_tar = root / f'work/cache/dxmt/dxmt-{dxmt_commit}.tar.gz'
    dxmt_url = dxmt_pin['DXMT_REPO'] + '/tree/' + dxmt_commit
    wmtr_docs = [('LICENSE', require(root / 'LICENSES/BSD-3-Clause.txt').read_bytes()),
                 ('NOTICE', require(root / 'NOTICE').read_bytes())]
    if wmtr_host:
        archive('DXMT', dxmt_pin['DXMT_FORK_COMMIT'], 'LGPL-2.1-or-later',
                host + '/libwmtr_host.dylib', dxmt_url, dxmt_tar, ('COPYING.LIB', 'LICENSE', 'LICENSE.OLD'))
        add('LLVM', dxmt_pin['LLVM_VERSION'], 'Apache-2.0 WITH LLVM-exception',
            host + '/libwmtr_host.dylib', 'https://github.com/llvm/llvm-project/tree/llvmorg-' + dxmt_pin['LLVM_VERSION'],
            [('LICENSE', require(root / 'LICENSES/LLVM-15-Apache-2.0-WITH-LLVM-exception.txt').read_bytes())])
        add('wmtr', '2026', 'BSD-3-Clause', host + '/libwmtr_host.dylib',
            'https://github.com/StonkGuy/steamac/tree/fex-eac/wmtr', wmtr_docs)
epoxy_script = (root / 'host/libepoxy/build.sh').read_text()
epoxy_version = re.search(r'^VERSION=([0-9.]+)$', epoxy_script, re.M)
epoxy_url = re.search(r'^URL=(https://\S+)$', epoxy_script, re.M)
if not epoxy_version or not epoxy_url:
    raise RuntimeError('missing pinned libepoxy version or source URL')
source('libepoxy', epoxy_version.group(1), 'MIT', host + '/libepoxy.0.dylib',
       epoxy_url.group(1), root / 'work/build/host-libepoxy/src')
sentry = root / 'host/launcher/.build/checkouts/sentry-cocoa'
source('sentry-cocoa', '9.30.0', None, launcher,
       'https://github.com/getsentry/sentry-cocoa/tree/9.30.0', sentry)
# MIT, plus the notices of the code it includes (bsdiff, sais-lite, ed25519, SUSignatureVerifier).
source('Sparkle', '2.10.1', 'MIT AND BSD-2-Clause AND Zlib', host + '/Sparkle.framework',
       'https://github.com/sparkle-project/Sparkle/tree/2.10.1', root / 'host/launcher/.build/checkouts/Sparkle')
zstd = root / 'host/launcher/Sources/CZstd/zstd'
zstd_version = require(zstd / 'VERSION').read_text().split()[0]
source('zstd', zstd_version, 'BSD-3-Clause', launcher,
       'https://github.com/facebook/zstd/tree/v' + zstd_version, zstd)
enet = root / 'host/launcher/Sources/CEnet/enet'
enet_commit = require(enet / 'VERSION').read_text().split()[0]
source('enet', enet_commit[:10], 'MIT', launcher,
       'https://github.com/cgutman/enet/tree/' + enet_commit, enet)
nanors = root / 'host/launcher/Sources/CNanors/nanors'
nanors_commit = require(nanors / 'VERSION').read_text().split()[0]
source('nanors', nanors_commit[:10], 'MIT', launcher,
       'https://github.com/sleepybishop/nanors/tree/' + nanors_commit, nanors)

# Only resolved target-specific packages count; build dependencies and proc macros are
# included since their license conditions may apply to generated/embedded code.
def rust_graph(manifest, features, target, prefix, location):
    env = dict(os.environ, CARGO_HOME=str(root / 'work/cache/cargo-home')) if prefix == 'progress-agent-crate-' else None
    metadata = json.loads(run('cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
                              '--manifest-path', str(manifest), '--filter-platform', target,
                              *(['--features', features] if features else []), env=env))
    resolved = {node['id'] for node in metadata['resolve']['nodes']}
    packages = [p for p in metadata['packages'] if p['id'] in resolved and (p.get('source') or '').startswith('registry+')]
    for pkg in sorted(packages, key=lambda p: (p['name'], p['version'])):
        path = Path(pkg['manifest_path']).parent
        source(prefix + pkg['name'] + '-' + pkg['version'], pkg['version'], pkg.get('license'), location,
               pkg['homepage'] or pkg['repository'] or f"https://crates.io/crates/{pkg['name']}/{pkg['version']}", path)
    counts[prefix] = len(packages)
    print(f'{prefix}: {len(packages)} registry crates / {len(packages)} resolved registry crates')

rust_graph(krun / 'Cargo.toml', 'blk,net,gpu,input,snd', 'aarch64-apple-darwin', 'libkrun-crate-', host + '/libkrun.1.dylib')
rust_graph(root / 'guest/progress-agent/Cargo.toml', '', 'aarch64-unknown-linux-musl',
           'progress-agent-crate-', res + '/steamac-layer.img:/usr/bin/fx-progress-agent')

# go version -m describes the exact binary (including versions other than the current
# module graph). Download each module to an isolated, persistent cache, never a guess.
goenv = dict(os.environ, GOMODCACHE=str(cache), GOWORK='off')
for binary in ('gvproxy', 'desync'):
    location = res + '/' + binary
    lines = run('go', 'version', '-m', str(root / 'work/out/host/bin' / binary)).splitlines()
    go_version = lines[0].split()[-1]
    if not re.fullmatch(r'go[0-9]+\.[0-9]+(?:\.[0-9]+)?', go_version):
        raise RuntimeError(f'{binary}: unknown embedded Go toolchain version: {go_version}')
    add('go-runtime-' + binary, go_version, 'BSD-3-Clause', location,
        'https://github.com/golang/go/tree/' + go_version,
        [('LICENSE', pinned_text('go-' + go_version + '-LICENSE',
          'https://raw.githubusercontent.com/golang/go/' + go_version + '/LICENSE'))])
    modules = [line.strip().split() for line in lines if line.strip().startswith(('mod\t', 'dep\t'))]
    for kind, module, version, *remainder in modules:
        info = json.loads(run('go', 'mod', 'download', '-json', module + '@' + version, env=goenv, cwd=root))
        if info.get('Error'):
            raise RuntimeError(f'{module}@{version}: {info["Error"]}')
        path = Path(info['Dir'])
        docs = top_docs(path)
        # Some Go submodules inherit the parent repository's license. Go modules
        # omit parent files from their zip, so fetch the repository at the same
        # revision using the module source origin when there is no root license.
        if not docs:
            candidate = path.parent / 'LICENSE'
            if candidate.is_file():
                docs = [('LICENSE', candidate.read_bytes())]
        add('go-' + binary + '-' + module.replace('/', '__') + '-' + version,
            version, spdx(b'\n'.join(data for _, data in docs).decode('utf-8', 'replace')),
            location, (info.get('Origin') or {}).get('URL', 'https://' + module) +
            '/tree/' + (info.get('Origin') or {}).get('Hash', version), docs)
    counts[binary] = len(modules)
    print(f'{binary}: {len(modules)} modules / {len(modules)} go version -m modules')

config = {}
for line in (root / 'scripts/config.env').read_text().splitlines():
    match = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line)
    if match:
        config[match[1]] = match[2]
host_rust = re.search(r'^RUST_TOOLCHAIN=\$\{RUST_TOOLCHAIN:-([0-9.]+)\}',
                      (root / 'host/libkrun/build.sh').read_text(), re.M)
if not host_rust:
    raise RuntimeError('missing pinned host libkrun Rust toolchain')
guest_rust = run('docker', 'run', '--rm', '--platform', 'linux/arm64',
                 config['RUST_IMAGE'], 'rustc', '--version').split()[1]
for kind, version, location in (
    ('host', host_rust.group(1), host + '/libkrun.1.dylib'),
    ('guest', guest_rust, res + '/steamac-layer.img:/usr/bin/fx-progress-agent')):
    url = 'https://github.com/rust-lang/rust/tree/' + version
    add('rust-runtime-' + kind, version, 'Apache-2.0 OR MIT', location, url,
        [(license, pinned_text('rust-' + version + '-' + license,
          'https://raw.githubusercontent.com/rust-lang/rust/' + version + '/' + license))
         for license in ('LICENSE-APACHE', 'LICENSE-MIT')])
image = res + '/Image'
init = res + '/initramfs.cpio.gz'
layer = res + '/steamac-layer.img'
kernel_version = '7.2.9'
archive('linux-kernel', kernel_version, 'GPL-2.0-only WITH Linux-syscall-note', image,
        'https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-' + kernel_version + '.tar.xz',
        root / f'work/cache/kernel/linux-{kernel_version}.tar.xz', ('COPYING', 'LICENSES/exceptions/Linux-syscall-note', 'LICENSES/preferred/GPL-2.0'))
# busybox is the Debian snapshot's busybox-static; retrieve the matching installed
# package copyright instead of pretending a GPL text from another release is sufficient.
builder = config['BUILDER_IMAGE']
builder_hash = run('docker', 'image', 'inspect', '-f', '{{.Id}}', builder).split(':')[-1][:16]
busybox_version = run('docker', 'run', '--rm', '--platform', 'linux/arm64', builder,
                      'dpkg-query', '-W', '-f=${Version}', 'busybox-static')
busybox_copyright = root / 'work/cache/licenses' / ('busybox-' + builder_hash + '-copyright')
if not busybox_copyright.is_file():
    data = subprocess.check_output(['docker', 'run', '--rm', '--platform', 'linux/arm64',
                                    builder, 'cat', '/usr/share/doc/busybox-static/copyright'])
    busybox_copyright.parent.mkdir(parents=True, exist_ok=True)
    busybox_copyright.write_bytes(data)
add('busybox-static', busybox_version, 'GPL-2.0-only', init + ':/bin/busybox',
    'https://sources.debian.org/src/busybox/',
    [('copyright', require(busybox_copyright).read_bytes()),
     ('GPL-2.0', require(stage / 'linux-kernel/LICENSES/preferred/GPL-2.0').read_bytes())])
archive('dosfstools', config['DOSFSTOOLS_VERSION'], 'GPL-3.0-or-later', init + ':/bin/{fsck.fat,mkfs.fat}',
        config['DOSFSTOOLS_URL'], root / f"work/cache/dosfstools/{config['DOSFSTOOLS_VERSION']}/dosfstools-{config['DOSFSTOOLS_VERSION']}.tar.gz",
        ('COPYING', 'LICENSE'))
archive('e2fsprogs', config['E2FSPROGS_VERSION'], 'GPL-2.0-only AND LGPL-2.0-only AND BSD-3-Clause AND LicenseRef-MIT-SIPB',
        init + ':/bin/mke2fs (static libext2fs/libuuid/libblkid/libcom_err)', config['E2FSPROGS_URL'],
        root / f"work/cache/e2fsprogs/{config['E2FSPROGS_VERSION']}/e2fsprogs-{config['E2FSPROGS_VERSION']}.tar.xz",
        ('NOTICE', 'debian/copyright', 'lib/uuid/COPYING'))
archive('btrfs-progs', config['BTRFSPROGS_VERSION'], 'GPL-2.0-only', init + ':/bin/btrfstune',
        config['BTRFSPROGS_URL'], root / f"work/cache/btrfs-progs/{config['BTRFSPROGS_VERSION']}/btrfs-progs-v{config['BTRFSPROGS_VERSION']}.tar.xz",
        ('COPYING', 'LICENSE'))
versions = {}
for line in (root / 'guest/mesa/versions.env').read_text().splitlines():
    match = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line)
    if match:
        versions[match[1]] = match[2]
add('Mesa', versions['MESA_COMMIT'], 'MIT', layer + ':/usr/lib and /usr/share/guestos/fex-mesa',
    versions['MESA_URL'], [('license.rst', pinned_text(
        'mesa-' + versions['MESA_COMMIT'] + '-license.rst',
        'https://gitlab.freedesktop.org/mesa/mesa/-/raw/' + versions['MESA_COMMIT'] + '/docs/license.rst'))])
if dxmt_guest:
    dxmt_location = layer + ':/usr/lib/steamac/dxmt/'
    for dll in ('d3d11', 'dxgi', 'd3d10core', 'winemetal'):
        require(dxmt_payload / 'x86_64-windows' / (dll + '.dll'))
    archive('DXMT-guest', dxmt_pin['DXMT_FORK_COMMIT'], 'LGPL-2.1-or-later',
            dxmt_location + 'x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll',
            dxmt_url, dxmt_tar, ('COPYING.LIB', 'LICENSE', 'LICENSE.OLD'))
    add('wmtr-guest', '2026', 'BSD-3-Clause AND LGPL-2.1-or-later',
        dxmt_location + 'x86_64-unix/winemetal.so',
        'https://github.com/StonkGuy/steamac/tree/fex-eac/wmtr',
        wmtr_docs + [('COPYING.LIB', require(root / 'LICENSES/LGPL-2.1-only.txt').read_bytes())])
    dxmt_build = require(root / 'host/dxmt/build.sh').read_text()
    headers_commit = re.search(r'^DXHEADERS_COMMIT=([0-9a-f]{40})$', dxmt_build, re.M).group(1)
    archive('DXMT-mingw-directx-headers', headers_commit, 'LGPL-2.1-or-later',
            dxmt_location + 'x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll',
            'https://github.com/misyltoad/mingw-directx-headers/tree/' + headers_commit,
            root / f'work/cache/dxmt/mingw-directx-headers-{headers_commit}.tar.gz',
            ('COPYING.MinGW-w64.txt',))
own_docs = []
for filename in ('LICENSE', 'NOTICE'):
    path = root / filename
    if path.is_file():
        own_docs.append((filename, path.read_bytes()))
    else:
        print(f'warning: {path} not yet present; skipping', file=sys.stderr)
if own_docs:
    add('steamac', '2026', 'Apache-2.0', res + '/licenses',
        'https://github.com/fxgl/steamac', own_docs)

index = ['Third-party license notices for FX Steam Launcher',
         'Each listed directory contains the upstream license, copyright and notice files for this component.',
         'The SteamOS root filesystem acquired by the launcher is distributed separately by Valve.', '']
for name, version, license_id, location, url in sorted(entries):
    index += [f'{name} | {version} | {license_id}', f'  In bundle: {location}', f'  Source: {url}', f'  License texts: {name}/', '']
index += [f"Totals: {len(entries)} components; " + ', '.join(f'{k}{v}' for k, v in sorted(counts.items())), '']
(stage / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(index))
old = out.with_name(out.name + '.previous')
if old.exists():
    shutil.rmtree(old)
if out.exists():
    out.rename(old)
stage.rename(out)
if old.exists():
    shutil.rmtree(old)
print(f'licenses: {len(entries)} components -> {out}')
PY
