#!/usr/bin/env bash
# One-time bootstrap publisher. Runs in the public updates repository with its own GITHUB_TOKEN.
# Only a SHA-256 verified, fixed-signer APK may be published.
set -euo pipefail
STAGED=.github/staged-release/v0.9.0-dev
OUT=out
mkdir -p "$OUT"
python3 - "$STAGED" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, sys, zipfile
stage,out=map(Path,sys.argv[1:3])
m=json.loads((stage/'manifest.json').read_text(encoding='utf-8'))
r=m['release']
assert r['schema']==1 and r['package']=='kr.workbibleman.app'
assert r['versionCode']==17 and r['versionName']=='0.9.0-dev'
assert r['apkUrl']=='https://github.com/tarotbear/work-bible-man-updates/releases/download/v0.9.0-dev/work-bible-man.apk'
assert m['signedCertSha256']=='52e86078c16d44c83b265834098fc92fea00a6ccef4f2c41dae022310e4b0387'
assert len(m['parts'])==9
outapk=out/'work-bible-man.apk'
with outapk.open('wb') as f:
    for i,p in enumerate(m['parts']):
        assert p['name']==f'part-{i:03d}.bin'
        data=(stage/p['name']).read_bytes()
        assert len(data)==p['length'] and hashlib.sha256(data).hexdigest()==p['sha256'],p['name']
        f.write(data)
content=outapk.read_bytes()
assert len(content)==r['size'], (len(content),r['size'])
assert hashlib.sha256(content).hexdigest()==r['sha256'], 'APK SHA256 mismatch'
with zipfile.ZipFile(outapk) as z:
    assert z.testzip() is None, 'invalid APK zip'
(out/'latest.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('CHECK PASSED: APK size, 9 chunk SHA-256 values, full-file SHA-256 and APK ZIP structure')
print('Final release sha256',r['sha256'])
PY
apk_tool="$ANDROID_HOME/build-tools/35.0.0/apksigner"
test -x "$apk_tool"
cert_sha=$("$apk_tool" verify --print-certs "$OUT/work-bible-man.apk" | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -1)
expected_cert=52e86078c16d44c83b265834098fc92fea00a6ccef4f2c41dae022310e4b0387
[[ "$cert_sha" == "$expected_cert" ]] || { echo 'BLOCKED: APK signing certificate differs from stable test signing key' >&2; exit 1; }
echo "CHECK PASSED: APK signing cert $cert_sha"
if gh release view v0.9.0-dev --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo 'Bootstrap release already exists; not overwriting. Checking existing asset.'
  gh release view v0.9.0-dev --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' | grep -Fx 'work-bible-man.apk'
else
  gh release create v0.9.0-dev "$OUT/work-bible-man.apk#work-bible-man.apk" --repo "$GITHUB_REPOSITORY" --title '워크 바이블 맨 v0.9.0-dev' --notes '고정 서명 기반 자동 업데이트 검증판. 기존 v0.8.9 고정 서명판에서 학습 기록을 유지하며 덮어쓰기 설치 가능. 본문: 성경전서 개역한글판(1961), 대한성서공회. 실제 삼성 기기 동작은 별도 점검 필요.'
fi
encoded=$(base64 -w0 "$OUT/latest.json")
existing=$(gh api "repos/$GITHUB_REPOSITORY/contents/latest.json" --jq '.sha' 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/latest.json" -f message='Publish signed v0.9.0-dev update feed' -f content="$encoded" -f sha="$existing" >/dev/null
else
  gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/latest.json" -f message='Publish signed v0.9.0-dev update feed' -f content="$encoded" >/dev/null
fi
echo 'PUBLISHED: verified APK release and latest.json feed.'
