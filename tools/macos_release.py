#!/usr/bin/env python3
"""Local Developer ID release pipeline; credentials stay in the macOS Keychain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = 'Drop & View Render.app'
EXT_ID = 'com.hildgyorgy.DropViewRender.SafariExtension'
APP_ID = 'com.hildgyorgy.DropViewRender'


def run(*args, capture=False):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None


def clean():
    if run('git', 'status', '--porcelain', capture=True):
        raise RuntimeError('Commit reviewed source changes before creating a distributable release.')


def identity(value):
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
    matches = re.findall(r'([A-F0-9]{40}) "(Developer ID Application: [^"]+)"', identities)
    selected = [(sha, name) for sha, name in matches if value in (sha, name)]
    if len(selected) != 1:
        raise RuntimeError('An exact valid Developer ID Application identity (with private key) is required.')
    return selected[0][0]


def signature(path):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True, check=True)
    text = result.stderr
    if 'Authority=Developer ID Application:' not in text or 'runtime' not in text or 'Timestamp=' not in text:
        raise RuntimeError(f'Missing Developer ID, hardened runtime or secure timestamp: {path}')
    team = re.search(r'^TeamIdentifier=(.+)$', text, re.M)
    if not team:
        raise RuntimeError(f'Missing signing team: {path}')
    ent = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True)
    if ent.stdout:
        data = plistlib.loads(ent.stdout)
        if data.get('com.apple.security.get-task-allow'):
            raise RuntimeError(f'Debug entitlement in release: {path}')
    return team.group(1)


def verify(app, notarized=False):
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    # Product name is resolved from the bundle rather than guessed if Xcode changes it.
    extensions = list((app / 'Contents/PlugIns').glob('*.appex'))
    if len(extensions) != 1:
        raise RuntimeError('Exactly one embedded Safari extension is required.')
    extension = extensions[0]
    helper = app / 'Contents/MacOS/DropViewRenderNativeHost'
    teams = {signature(p) for p in (extension, helper, app)}
    if len(teams) != 1:
        raise RuntimeError('App, Safari extension and native helper must have the same signing team.')
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    ext_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    if app_info['CFBundleIdentifier'] != APP_ID or ext_info['CFBundleIdentifier'] != EXT_ID:
        raise RuntimeError('Unexpected bundle identity.')
    for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
        if app_info[key] != ext_info[key]:
            raise RuntimeError('App and extension versions differ.')
    for manifest in app.glob('Contents/**/manifest.json'):
        data = json.loads(manifest.read_text())
        if 'manifest_version' in data and data.get('version') != app_info['CFBundleShortVersionString']:
            raise RuntimeError('Browser manifest version differs from the app.')
    if notarized:
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    return app_info


def notarize(path, profile):
    # No Apple password/API key is accepted on this command line or written to repo.
    result = json.loads(run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                            '--wait', '--output-format', 'json', capture=True))
    print(json.dumps(result, indent=2))
    if result.get('status') != 'Accepted':
        raise RuntimeError('Notarization was not accepted; inspect notarytool log using the submission ID.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    build = sub.add_parser('build')
    build.add_argument('--version', required=True)
    build.add_argument('--build-number', required=True)
    build.add_argument('--identity')
    build.add_argument('--unsigned-check', action='store_true', help='Local validation only; cannot package or publish.')
    for name in ('verify', 'notarize-app', 'dmg'):
        command = sub.add_parser(name)
        command.add_argument('app', type=Path)
        if name in ('notarize-app', 'dmg'):
            command.add_argument('--profile', required=True, help='Existing notarytool Keychain profile name')
        if name == 'dmg':
            command.add_argument('--identity', required=True)
    publish = sub.add_parser('publish')
    publish.add_argument('dmg', type=Path)
    publish.add_argument('--tag', required=True)
    publish.add_argument('--notes', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'build':
        if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[1-9]\d*', args.build_number):
            raise RuntimeError('Use a numeric x.y.z version and positive integer build number.')
        if not args.unsigned_check:
            clean()
            signing = identity(args.identity)
        output = ROOT / '.build/macos-release' / f'{args.version}-{args.build_number}'
        if output.exists():
            raise RuntimeError(f'Output already exists; choose a new build number or move it aside: {output}')
        output.mkdir(parents=True)
        run('xcodebuild', '-project', 'DropViewRender.xcodeproj', '-scheme', 'Drop & View Render',
            '-configuration', 'Release', '-derivedDataPath', output / 'DerivedData',
            'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO',
            f'MARKETING_VERSION={args.version}', f'CURRENT_PROJECT_VERSION={args.build_number}', 'build')
        app = output / APP_NAME
        run('ditto', output / 'DerivedData/Build/Products/Release' / APP_NAME, app)
        for manifest in app.glob('Contents/**/manifest.json'):
            data = json.loads(manifest.read_text())
            if 'manifest_version' in data:
                data['version'] = args.version
                manifest.write_text(json.dumps(data, indent=2) + '\n')
        if not args.unsigned_check:
            extension = next((app / 'Contents/PlugIns').glob('*.appex'))
            for path, entitlements in ((extension, ROOT / 'DropViewRender/SafariExtension/SafariExtension.entitlements'),
                                       (app / 'Contents/MacOS/DropViewRenderNativeHost', None), (app, None)):
                command = ['codesign', '--force', '--sign', signing, '--timestamp', '--options', 'runtime']
                if entitlements:
                    command += ['--entitlements', entitlements]
                run(*command, path)
            verify(app)
        record = {'commit': run('git', 'rev-parse', 'HEAD', capture=True), 'version': args.version,
                  'build': args.build_number, 'architecture': 'arm64', 'unsignedCheck': args.unsigned_check}
        (output / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
        print(f'Built: {app}')
    elif args.command == 'verify':
        verify(args.app.resolve(), notarized=True)
    elif args.command == 'notarize-app':
        app = args.app.resolve()
        verify(app)
        archive = app.parent / 'notarization-app.zip'
        if archive.exists():
            archive.unlink()
        run('ditto', '-c', '-k', '--keepParent', app, archive)
        notarize(archive, args.profile)
        run('xcrun', 'stapler', 'staple', app)
        verify(app, notarized=True)
    elif args.command == 'dmg':
        app = args.app.resolve()
        info = verify(app, notarized=True)
        signing = identity(args.identity)
        dmg = app.parent / f'DropViewRender-{info["CFBundleShortVersionString"]}-macOS-arm64.dmg'
        stage = app.parent / 'dmg-content'
        if dmg.exists() or stage.exists():
            raise RuntimeError('DMG staging/output already exists; preserve it or move it aside first.')
        stage.mkdir()
        run('ditto', app, stage / APP_NAME)
        (stage / 'Applications').symlink_to('/Applications')
        shutil.copyfile(ROOT / 'docs/MACOS_INSTALL.md', stage / 'Read Me.txt')
        run('hdiutil', 'create', '-volname', 'Drop & View Render', '-srcfolder', stage,
            '-ov', '-format', 'UDZO', dmg)
        run('codesign', '--sign', signing, '--timestamp', dmg)
        notarize(dmg, args.profile)
        run('xcrun', 'stapler', 'staple', dmg)
        run('xcrun', 'stapler', 'validate', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
        (dmg.parent / 'SHA256SUMS.txt').write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + '  ' + dmg.name + '\n')
        print(f'Release artifact: {dmg}')
    elif args.command == 'publish':
        clean()
        dmg = args.dmg.resolve()
        if not shutil.which('gh'):
            raise RuntimeError('GitHub CLI is required: install gh and authenticate with gh auth login.')
        record = json.loads((dmg.parent / 'provenance.json').read_text())
        if record['unsignedCheck'] or args.tag != 'v' + record['version']:
            raise RuntimeError('Only the matching signed release version can be published.')
        if run('git', 'rev-parse', 'HEAD', capture=True) != record['commit']:
            raise RuntimeError('Source HEAD differs from the signed build.')
        sums = dmg.parent / 'SHA256SUMS.txt'
        if sums.read_text() != hashlib.sha256(dmg.read_bytes()).hexdigest() + '  ' + dmg.name + '\n':
            raise RuntimeError('DMG checksum differs from the prepared release.')
        run('xcrun', 'stapler', 'validate', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
        if run('git', 'ls-remote', '--tags', 'origin', 'refs/tags/' + args.tag, capture=True):
            raise RuntimeError('Release tag already exists; choose a new version instead of reusing it.')
        run('gh', 'auth', 'status')
        run('git', 'push', 'origin', 'HEAD:main')
        run('gh', 'release', 'create', args.tag, dmg, sums, '--repo', 'hildgyorgy/drop-view-render',
            '--target', record['commit'], '--title', f'Drop & View Render {record["version"]}', '--notes-file', args.notes)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        sys.exit(str(error))
