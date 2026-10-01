"""Exercise recovery on a fake /opt tree. Run on Linux; never touches a real service."""
import hashlib, json, os, pathlib, subprocess, tempfile, time
HERE = pathlib.Path(__file__).resolve().parent

def put(root, name, content, executable=False):
    p = root / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    if executable: p.chmod(0o755)
    return p

def scenario(fail=False, watchdog=False):
    with tempfile.TemporaryDirectory(prefix='homenet-transaction-test-') as tmp:
        root = pathlib.Path(tmp)
        env = {**os.environ, 'HOMENET_ROOT': tmp, 'HOMENET_CONFIRM_TIMEOUT': '3'}
        stage = root / 'opt/tmp/homenet-release-test'
        backup = root / 'opt/backups/homenet-test'
        put(root, 'opt/sbin/mihomo', '#!/bin/sh\necho old\n', True)
        put(root, 'opt/sbin/xkeen', '#!/bin/sh\necho old-cli\n', True)
        put(root, 'opt/sbin/.xkeen/old-module', 'old')
        put(root, 'opt/etc/init.d/S05xkeen', '#!/bin/sh\n[ "$1" != stop ] || rm -f "$HOMENET_ROOT/opt/etc/ndm/schedule.d/00-xkeen-hotspot-sync.sh"\nexit 0\n', True)
        put(root, 'opt/etc/ndm/schedule.d/00-xkeen-hotspot-sync.sh', 'old-hook')
        put(root, 'opt/etc/mihomo/profiles/default.yaml', 'old-config')
        (root / 'opt/etc/mihomo/config.yaml').symlink_to('profiles/default.yaml')
        put(root, 'opt/etc/mihomo/cache.db', 'old-history')
        put(root, 'opt/etc/mihomo/zash/index.html', 'old-ui')
        put(root, 'opt/bin/curl', '#!/bin/sh\ncase "$*" in */version*) echo \'{"version":"new"}\';; *) echo html;; esac\n', True)
        put(stage, 'mihomo', '#!/bin/sh\nexit 0\n', False)
        put(stage, 'xkeen/xkeen', '#!/bin/sh\necho new-cli\n', True)
        put(stage, 'xkeen/_xkeen/new-module', 'new')
        put(stage, 'zash/index.html', 'new-ui')
        put(stage, 'S05xkeen', '#!/bin/sh\nexit '+('1' if fail else '0')+'\n', True)
        put(stage, 'config.yaml', 'new-config')
        put(stage, 'version.txt', 'new')
        put(stage, 'network-check-url', '')
        put(stage, 'rollback.sh', (HERE/'rollback.sh').read_text(), True)
        checks = ''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(stage).as_posix()+'\n' for p in stage.rglob('*') if p.is_file())
        put(stage, 'payload.sha256', checks)
        result = subprocess.run(['sh', str(HERE/'transaction.sh'), str(stage), str(backup)], env=env, capture_output=True, text=True)
        if not fail:
            assert result.returncode == 0, result.stderr
            assert (root/'opt/etc/mihomo/config.yaml').is_symlink()
            assert (root/'opt/etc/mihomo/profiles/default.yaml').read_text() == 'new-config'
            if watchdog:
                for _ in range(40):
                    if (backup/'rolled-back').exists(): break
                    time.sleep(.2)
                assert (backup/'rolled-back').exists(), 'watchdog did not roll back'
            else:
                (backup/'confirmed').touch()
                subprocess.run(['sh', str(backup/'rollback.sh'), '--check'], env=env, check=True, capture_output=True)
                subprocess.run(['sh', str(backup/'rollback.sh'), '--apply'], env=env, check=True, capture_output=True)
        else:
            assert result.returncode != 0
            assert (backup/'rolled-back').exists(), (result.stdout, result.stderr)
        assert (root/'opt/etc/mihomo/profiles/default.yaml').read_text() == 'old-config'
        assert (root/'opt/etc/mihomo/config.yaml').is_symlink()
        assert (root/'opt/etc/mihomo/cache.db').read_text() == 'old-history'
        assert (root/'opt/etc/ndm/schedule.d/00-xkeen-hotspot-sync.sh').read_text() == 'old-hook'
        assert (root/'opt/etc/mihomo/zash/index.html').read_text() == 'old-ui'
        assert (root/'opt/sbin/.xkeen/old-module').exists()
        assert not (root/'opt/sbin/.xkeen/new-module').exists()
        print(json.dumps({'failure': fail, 'watchdog': watchdog, 'rollback': 'OK'}))

scenario()
scenario(fail=True)
scenario(watchdog=True)
