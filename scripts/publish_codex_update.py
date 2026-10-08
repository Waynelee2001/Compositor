#!/usr/bin/env python3
"""Publish only a tested, signed Compositor AI artifact. Never modifies main or upstream releases."""
from __future__ import annotations
import argparse, base64, datetime, hashlib, json, os, plistlib, re, shutil, subprocess, tempfile
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

REPO = 'Waynelee2001/Compositor'
BUNDLE_ID = 'com.waynelee.compositor.codex'
FEED = f'https://raw.githubusercontent.com/{REPO}/updates-codex/appcast.xml'
ASSET = 'Compositor-AI-arm64.zip'
ARTIFACT = 'Compositor-AI-Updates-arm64-development'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ROOT = Path(__file__).resolve().parents[1]
ET.register_namespace('sparkle', NS)

def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(list(args), cwd=cwd, text=True).strip()

def validate_request(req: dict) -> None:
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', str(req.get('version',''))):
        raise ValueError('Expected a numeric release version')
    if not isinstance(req.get('build'), int) or not 40 < req['build'] < 2**31:
        raise ValueError('Expected an increasing integer build number above 40')
    if not isinstance(req.get('run_id'), int) or req['run_id'] <= 0:
        raise ValueError('A successful Codex Integration run is required')
    for name, n in [('source_sha',40),('archive_sha256',64)]:
        if not re.fullmatch('[0-9a-f]{'+str(n)+'}', str(req.get(name,''))):
            raise ValueError('Invalid '+name)
    if req.get('signature'):
        if len(base64.b64decode(req['signature'], validate=True)) != 64:
            raise ValueError('Invalid Ed25519 signature')

def inspect_archive(archive: Path, req: dict, public_key: str) -> dict:
    if hashlib.sha256(archive.read_bytes()).hexdigest() != req['archive_sha256']:
        raise ValueError('Artifact archive SHA-256 mismatch')
    with zipfile.ZipFile(archive) as z:
        entry = z.getinfo('Compositor.app/Contents/Info.plist')
        if entry.file_size > 1_048_576: raise ValueError('Oversized bundle metadata')
        info = plistlib.loads(z.read(entry))
        expected = {'CFBundleIdentifier':BUNDLE_ID, 'CFBundleShortVersionString':req['version'],
                    'CFBundleVersion':str(req['build']), 'SUPublicEDKey':public_key,
                    'SUFeedURL':FEED, 'SUVerifyUpdateBeforeExtraction':True, 'SUAllowsAutomaticUpdates':False}
        if any(info.get(k) != v for k,v in expected.items()):
            raise ValueError('Archive identity/version/update security settings do not match the request')
        if 'Compositor.app/Contents/Helpers/codex' not in z.namelist():
            raise ValueError('Codex helper is missing; refusing a feature-losing update')
        if z.testzip() is not None: raise ValueError('ZIP CRC verification failed')
    return info

def make_feed(previous: bytes, req: dict, signature: str, size: int, minimum: str) -> bytes:
    root = ET.fromstring(previous); channel = root.find('channel')
    if channel is None: raise ValueError('Invalid existing feed')
    builds = [int(i.findtext('{'+NS+'}version','0')) for i in channel.findall('item')]
    if builds and max(builds) >= req['build']: raise ValueError('Refusing duplicate or downgraded build')
    tag = f"ai-v{req['version']}-b{req['build']}"
    item = ET.Element('item')
    for name,text in [('title',f"Compositor AI {req['version']}"),
        ('pubDate',datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')),
        ('{'+NS+'}version',str(req['build'])), ('{'+NS+'}shortVersionString',req['version']),
        ('{'+NS+'}minimumSystemVersion',minimum),
        ('link',f'https://github.com/{REPO}/releases/tag/{tag}'),
        ('description',str(req.get('notes','Compositor AI development update. This package is not Apple-notarized.'))[:20000])]:
        ET.SubElement(item,name).text=text
    ET.SubElement(item,'enclosure',{'url':f'https://github.com/{REPO}/releases/download/{tag}/{ASSET}',
                                  '{'+NS+'}edSignature':signature,'length':str(size),'type':'application/octet-stream'})
    channel.insert(1,item)
    for old in channel.findall('item')[20:]: channel.remove(old)
    ET.indent(root)
    return ET.tostring(root,encoding='utf-8',xml_declaration=True)+b'\n'

def main() -> None:
    ap=argparse.ArgumentParser();ap.add_argument('request',type=Path);args=ap.parse_args()
    req=json.loads(args.request.read_text());validate_request(req)
    key=(ROOT/'Config/SparklePublicKey.txt').read_text().strip()
    result=json.loads(run('gh','api',f'repos/{REPO}/actions/runs/{req["run_id"]}'))
    if result['conclusion'] != 'success' or result['head_sha'] != req['source_sha'] or result['path'] != '.github/workflows/codex-verify.yml' or result['head_repository']['full_name'] != REPO:
        raise ValueError('The requested artifact did not pass the trusted Codex Integration workflow')
    with tempfile.TemporaryDirectory(prefix='compositor-publish-') as temp:
        work=Path(temp)
        run('gh','run','download',str(req['run_id']),'--repo',REPO,'--name',ARTIFACT,'--dir',str(work))
        original=work/'Compositor-AI-Updates-arm64.zip';archive=work/ASSET
        shutil.copyfile(original,archive)
        info=inspect_archive(archive,req,key)
        signature=req.get('signature')
        signer=str(ROOT/'scripts/update_signature.swift')
        if not signature:
            if not os.environ.get('SPARKLE_PRIVATE_KEY'):
                raise ValueError('Set repository secret SPARKLE_PRIVATE_KEY once, or provide an owner-generated detached signature')
            signature=run('swift',signer,'sign',str(archive),key)
        run('swift',signer,'verify',str(archive),key,signature)
        run('ditto','-x','-k',str(archive),str(work/'extracted'))
        app=work/'extracted/Compositor.app'
        run('codesign','--verify','--deep','--strict',str(app))
        if 'arm64' not in run('lipo','-archs',str(app/'Contents/MacOS/Compositor')).split():
            raise ValueError('The app has no Apple Silicon executable')
        run('git','fetch','origin','updates-codex',cwd=ROOT)
        feed_dir=work/'feed'
        run('git','worktree','add','--detach',str(feed_dir),'FETCH_HEAD',cwd=ROOT)
        try:
            feed_file=feed_dir/'appcast.xml'
            feed=make_feed(feed_file.read_bytes(),req,signature,archive.stat().st_size,str(info.get('LSMinimumSystemVersion','26.0')))
            tag=f"ai-v{req['version']}-b{req['build']}"
            # Publish the asset first. The feed is updated only after the public asset digest matches.
            existing=subprocess.run(['gh','release','view',tag,'--repo',REPO],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if existing.returncode == 0: raise ValueError('Release already exists; never overwrite an advertised update archive')
            notes=work/'notes.txt';notes.write_text(str(req.get('notes','Compositor AI update'))+'\n\nDevelopment build: Apple Silicon, macOS 26+. Not Apple-notarized.\n')
            run('gh','release','create',tag,str(archive),'--repo',REPO,'--target',req['source_sha'],'--draft','--prerelease','--latest=false','--title',f"Compositor AI {req['version']}",'--notes-file',str(notes))
            release=json.loads(run('gh','api',f'repos/{REPO}/releases/tags/{tag}'))
            asset=next(a for a in release['assets'] if a['name']==ASSET)
            if asset.get('digest') != 'sha256:'+req['archive_sha256']:
                raise ValueError('Uploaded asset digest mismatch. Draft retained; feed not changed')
            run('gh','release','edit',tag,'--repo',REPO,'--draft=false','--latest=false')
            feed_file.write_bytes(feed)
            run('git','add','appcast.xml',cwd=feed_dir)
            run('git','-c','user.name=github-actions[bot]','-c','user.email=41898282+github-actions[bot]@users.noreply.github.com','commit','-m',f'Publish signed Compositor AI {req["version"]} ({req["build"]})',cwd=feed_dir)
            run('git','push','origin','HEAD:refs/heads/updates-codex',cwd=feed_dir)
        finally:
            subprocess.run(['git','worktree','remove','--force',str(feed_dir)],cwd=ROOT,check=False)
    print('Signed release and dedicated update feed published; main was not changed.')
if __name__=='__main__': main()
