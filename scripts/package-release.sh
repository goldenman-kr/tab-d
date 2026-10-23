#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build first with build-mac.sh and build-android.sh. Never package build/private.
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil, subprocess
root=Path.cwd()
source=root/'build/Tab-D.app'
info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
version=info['CFBundleShortVersionString']
out=root/'build/releases'/version
out.mkdir(parents=True,exist_ok=True)
staging=out/'dmg-root'
if staging.exists(): shutil.rmtree(staging)
staging.mkdir()
app=staging/'Mr. Tab-D.app'
subprocess.run(['ditto',str(source),str(app)],check=True)
# Installed releases use each user's Application Support, never a developer's source path.
info.pop('TabDDevelopmentStateDirectory',None)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['python3','scripts/sign-mac.py',str(app)],check=True)
(staging/'Applications').symlink_to('/Applications')
(staging/'설치 안내.txt').write_text('Mr. Tab-D.app을 Applications 폴더로 드래그하세요.\nApple Silicon Mac용 개인 개발 빌드이며 Apple 공증은 제공하지 않습니다.\n실행이 차단되면 시스템 설정 → 개인정보 보호 및 보안에서 직접 확인해 허용하세요.\n화면 기록·손쉬운 사용 권한이 필요합니다. USB 연결에는 Android SDK Platform Tools와 USB 디버깅이 필요합니다.\n',encoding='utf-8')
name=f'Mr-Tab-D-{version}-macOS-arm64.dmg'
subprocess.run(['hdiutil','create','-volname','Mr. Tab-D','-srcfolder',str(staging),'-ov','-format','UDZO',str(out/name)],check=True)
apk=root/'android/app/build/outputs/apk/debug/app-debug.apk'
shutil.copy2(apk,out/f'Mr-Tab-D-{version}-Android.apk')
import hashlib
files=[out/name,out/f'Mr-Tab-D-{version}-Android.apk']
(out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print(f'Release assets: build/releases/{version}/')
PY
