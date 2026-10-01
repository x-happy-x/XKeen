#!/usr/bin/env python3
"""Prepare/apply pinned fork releases to the known Keenetic layout. SSH uses local keys."""
import argparse, hashlib, io, json, os, pathlib, re, shlex, subprocess, sys, tarfile, time, urllib.request, zipfile
from datetime import datetime

HERE = pathlib.Path(__file__).resolve().parent
OWNER = 'x-happy-x'

def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout

def ssh(host, command, data=None):
    return run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host, command], input=data)

def fetch(url):
    with urllib.request.urlopen(url, timeout=90) as response: return response.read()

def release(repo, asset_name):
    info = json.loads(run(['gh', 'release', 'view', '-R', f'{OWNER}/{repo}', '--json', 'tagName,assets']))
    name = asset_name(info['tagName'])
    assets = {a['name']: a['url'] for a in info['assets']}
    checks = fetch(assets['sha256sums.txt']).decode()
    expected = {line.split()[1].lstrip('*'): line.split()[0] for line in checks.splitlines()}
    data = fetch(assets[name])
    assert hashlib.sha256(data).hexdigest() == expected[name], f'{repo}: checksum mismatch'
    return info['tagName'], data

def write(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode('utf-8'))
    if executable: path.chmod(0o755)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--router', default='keenetic')
    parser.add_argument('--apply', action='store_true', help='Install; default only prepares and validates local payload')
    parser.add_argument('--adaptive', action='store_true', help='Enable ROUTER adaptive checks and restore four automatic fallback groups')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    workspace = args.output or pathlib.Path(os.environ.get('LOCALAPPDATA', pathlib.Path.home()))/'HomeNet'/'deployments'/stamp
    workspace.mkdir(parents=True, exist_ok=False)
    if os.name == 'nt':
        identity = run(['whoami']).decode().strip()
        run(['icacls', str(workspace), '/inheritance:r', '/grant:r', f'{identity}:(OI)(CI)F', 'SYSTEM:(OI)(CI)F'])
    else: workspace.chmod(0o700)
    payload = workspace/'payload'; payload.mkdir()
    host = args.router
    assert ssh(host, 'uname -m').decode().strip() == 'aarch64', 'Expected ARM64 router'
    raw = ssh(host, 'cat /opt/etc/mihomo/config.yaml')
    config = json.loads(ssh(host, '/opt/sbin/yq -o=json /opt/etc/mihomo/config.yaml'))
    assert config.get('external-ui') in ('./zash', 'zash', '/opt/etc/mihomo/zash'), 'Unexpected UI path'
    assert not config.get('secret'), 'This deployment script currently requires an unauthenticated loopback API'
    assert config.get('mixed-port') == 1080, 'Unexpected proxy port'
    selections = json.loads(ssh(host, "curl --noproxy '*' -fsS --max-time 10 http://127.0.0.1:9090/proxies"))
    before = {name: node.get('now') for name,node in selections['proxies'].items() if node.get('all')}
    write(workspace/'selections-before.json', json.dumps(before, ensure_ascii=False))
    print('Downloading and verifying published fork assets...', flush=True)
    core_version, core_gz = release('mihomo', lambda v: f'mihomo-linux-arm64-{v}.gz')
    ui_version, ui_zip = release('zashboard', lambda v: 'dist-cdn-fonts.zip')
    xkeen_version, xkeen_tar = release('XKeen', lambda v: 'xkeen.tar.gz')
    import gzip
    write(payload/'mihomo', gzip.decompress(core_gz), True)
    write(payload/'version.txt', core_version)
    with zipfile.ZipFile(io.BytesIO(ui_zip)) as archive:
        for entry in archive.infolist():
            path = pathlib.PurePosixPath(entry.filename)
            assert not path.is_absolute() and '..' not in path.parts
            if not entry.is_dir(): write(payload/'zash'/str(path), archive.read(entry))
    with tarfile.open(fileobj=io.BytesIO(xkeen_tar)) as archive:
        archive.extractall(payload/'xkeen', filter='data')
    assert (payload/'zash/index.html').is_file()
    assert (payload/'xkeen/xkeen').is_file() and (payload/'xkeen/_xkeen').is_dir()
    # Preserve the same service settings as register_xkeen_initd, without running its other installation hooks.
    old_service = ssh(host, 'cat /opt/etc/init.d/S05xkeen').decode()
    template = (payload/'xkeen/_xkeen/02_install/07_install_register/04_register_init.sh').read_text(encoding='utf-8')
    variables = 'name_client name_policy name_policy_full table_id table_mark custom_mark dscp_enable dscp_force_proxy dscp_force_proxy_tag dscp_exclude dscp_proxy ipv4_proxy ipv4_exclude ipv6_proxy ipv6_exclude proxy_dns proxy_router nfqws_mark pbr_strict start_verbose start_attempts init_delay udp_flush check_fd arm64_fd other_fd delay_fd ipv6_support extended_msg backup aghfix start_auto start_delay'.split()
    for var in variables:
        found = re.search(r'^'+var+r'=.*$', old_service, re.M)
        if found: template = re.sub(r'^'+var+r'=.*$', lambda _: found.group(), template, count=1, flags=re.M)
    write(payload/'S05xkeen', template, True)
    expression = '."external-ui-url" = "https://github.com/x-happy-x/zashboard/releases/latest/download/dist-cdn-fonts.zip"'
    changed_groups = []
    if args.adaptive:
        assert 'ROUTER' in config.get('proxy-providers', {})
        adaptive = {'enable': True, 'network-key': 'home-uplink', 'confirmations': 2, 'concurrency': 4,
            'direct-allowed': [{'url': 'https://ya.ru', 'expected-status': '200-399'}],
            'direct-global': [{'url': 'https://www.gstatic.com/generate_204', 'expected-status': '204'}, {'url': 'https://cp.cloudflare.com/generate_204', 'expected-status': '204'}],
            'targets': [{'url': 'https://www.google.com/', 'expected-status': '200', 'min-bytes': 1024}, {'url': 'https://www.cloudflare.com/cdn-cgi/trace', 'expected-status': '200', 'min-bytes': 64}]}
        health = {'enable': True, 'url': 'https://www.gstatic.com/generate_204', 'expected-status': '204', 'interval': 300, 'timeout': 5000, 'lazy': False, 'adaptive': adaptive}
        expression += ' | ."proxy-providers".ROUTER."health-check" = '+json.dumps(health)
        changed_groups = [g['name'] for g in config['proxy-groups'] if g['name'] in ('EU','RU','Без белых списков','AUTO')]
        for name in changed_groups:
            expression += ' | (."proxy-groups"[] | select(.name == '+json.dumps(name,ensure_ascii=False)+')).type = "fallback"'
        expression += ' | (."proxy-groups"[] | select(.name == "AUTO"))."health-check-urls" = ["https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"]'
    updated = ssh(host, '/opt/sbin/yq '+shlex.quote(expression)+' -', raw)
    write(payload/'config.yaml', updated)
    # Prove unrelated routing, DNS, credentials and outbound definitions did not change.
    revised = json.loads(ssh(host, '/opt/sbin/yq -o=json -', updated))
    for key,value in config.items():
        if key not in ('external-ui-url', 'proxy-providers', 'proxy-groups'): assert revised.get(key) == value, f'Unexpected change: {key}'
    for name,value in config.get('proxy-providers',{}).items():
        a=dict(value); b=dict(revised['proxy-providers'][name])
        if args.adaptive and name=='ROUTER': a.pop('health-check',None); b.pop('health-check',None)
        assert a==b, f'Unexpected provider change: {name}'
    for a,b in zip(config['proxy-groups'],revised['proxy-groups']):
        a=dict(a); b=dict(b)
        if a['name'] in changed_groups:
            a.pop('type',None); b.pop('type',None)
            if a['name']=='AUTO': a.pop('health-check-urls',None); b.pop('health-check-urls',None)
        assert a==b, 'Unexpected group change'
    baseline = ''
    for url in ['https://www.google.com/', 'https://www.cloudflare.com/cdn-cgi/trace']:
        try:
            ssh(host, "curl -x http://127.0.0.1:1080 --noproxy '' -fsSL --connect-timeout 8 --max-time 20 "+shlex.quote(url)+' -o /dev/null')
            baseline = url; break
        except subprocess.CalledProcessError: pass
    write(payload/'network-check-url', baseline)
    for name in ('transaction.sh','rollback.sh'): write(payload/name,(HERE/name).read_bytes(),True)
    manifest = ''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(payload).as_posix()+'\n' for p in sorted(payload.rglob('*')) if p.is_file())
    write(payload/'payload.sha256',manifest)
    backup = '/opt/backups/homenet-'+stamp
    stage = '/opt/tmp/homenet-release-'+stamp
    report = dict(core=core_version, ui=ui_version, xkeen=xkeen_version, router=host, backup=backup, stage=stage, adaptive=args.adaptive, changedGroups=changed_groups, baseline=baseline, applied=False)
    write(workspace/'report.json',json.dumps(report,ensure_ascii=False,indent=2))
    write(workspace/'rollback.ps1', "$ErrorActionPreference = 'Stop'\nssh -o BatchMode=yes "+shlex.quote(host)+" \"sh '"+backup+"/rollback.sh' --apply\"\nif ($LASTEXITCODE -ne 0) { throw 'Rollback failed' }\n")
    print(json.dumps({'prepared':str(workspace),**report},ensure_ascii=False),flush=True)
    if not args.apply: return
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        for path in payload.iterdir(): archive.add(path,arcname=path.name)
    ssh(host, 'umask 077; mkdir -p '+shlex.quote(stage)+'; tar -xzf - -C '+shlex.quote(stage),stream.getvalue())
    ssh(host, 'nohup sh '+stage+'/transaction.sh '+stage+' '+backup+' >'+stage+'/deploy.log 2>&1 </dev/null &')
    deadline=time.monotonic()+240
    while time.monotonic()<deadline:
        flags=ssh(host, 'for f in ready rolled-back; do [ ! -f '+backup+'/$f ] || echo $f; done; true').decode().split()
        failed=ssh(host, 'test ! -f '+stage+'/failed || cat '+stage+'/failed').decode().strip()
        if failed: raise RuntimeError('Deployment failed with exit '+failed+'. Inspect '+stage+'/deploy.log; recovery status in '+backup)
        if 'rolled-back' in flags: raise RuntimeError('Deployment rolled back. Logs: '+backup)
        if 'ready' in flags: break
        time.sleep(3)
    else: raise RuntimeError('No successful deployment acknowledgement; watchdog will restore the backup. Inspect '+stage+'/deploy.log')
    live = json.loads(ssh(host,"curl --noproxy '*' -fsS --max-time 10 http://127.0.0.1:9090/version"))
    assert live['version']==core_version, 'Live version mismatch; watchdog remains armed'
    # Keep the watchdog armed until the backup is copied off the router and validated.
    saved=ssh(host,'cat '+backup+'/before.tar')
    checksum=ssh(host,'cat '+backup+'/before.sha256').decode().split()[0]
    assert hashlib.sha256(saved).hexdigest()==checksum
    write(workspace/'before.tar',saved)
    write(workspace/'before.sha256',checksum+'  before.tar\n')
    ssh(host,'test -f '+backup+'/ready && test ! -f '+backup+'/rolled-back && touch '+backup+'/confirmed')
    report['applied']=True
    write(workspace/'report.json',json.dumps(report,ensure_ascii=False,indent=2))
    print('DEPLOYED. Backup copied and verified. Rollback: '+str(workspace/'rollback.ps1'),flush=True)

if __name__=='__main__':
    if hasattr(sys.stdout,'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
    try: main()
    except subprocess.CalledProcessError as error:
        # Commands may handle private config; never echo argv or captured config.
        print(f'Command failed (exit {error.returncode}). Private output withheld; inspect protected deployment logs.',file=sys.stderr)
        sys.exit(1)
