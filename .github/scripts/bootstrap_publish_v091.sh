#!/usr/bin/env bash
# One-time bootstrap publisher. Runs in the public updates repository with its own GITHUB_TOKEN.
# Only a SHA-256 verified, fixed-signer APK may be published.
set -euo pipefail
STAGED=.github/staged-release/v0.9.1-dev
OUT=out
mkdir -p "$OUT"
python3 - "$STAGED" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, sys, zipfile
stage,out=map(Path,sys.argv[1:3])
m=json.loads((stage/'manifest.json').read_text(encoding='utf-8'))
r=m['release']
assert r['schema']==1 and r['package']=='kr.workbibleman.app'
assert r['versionCode']==18 and r['versionName']=='0.9.1-dev'
assert r['apkUrl']=='https://github.com/tarotbear/work-bible-man-updates/releases/download/v0.9.1-dev/work-bible-man.apk'
assert m['signedCertSha256']=='52e86078c16d44c83b265834098fc92fea00a6ccef4f2c41dae022310e4b0387'
assert 1<=len(m['parts'])<=256
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
print('CHECK PASSED: APK size, per-part SHA-256 values, full-file SHA-256 and APK ZIP structure')
print('Final release sha256',r['sha256'])
PY
apk_tool="$ANDROID_HOME/build-tools/35.0.0/apksigner"
test -x "$apk_tool"
cert_sha=$("$apk_tool" verify --print-certs "$OUT/work-bible-man.apk" | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -1)
expected_cert=52e86078c16d44c83b265834098fc92fea00a6ccef4f2c41dae022310e4b0387
[[ "$cert_sha" == "$expected_cert" ]] || { echo 'BLOCKED: APK signing certificate differs from stable test signing key' >&2; exit 1; }
echo "CHECK PASSED: APK signing cert $cert_sha"
"$ANDROID_HOME/build-tools/35.0.0/aapt" dump badging "$OUT/work-bible-man.apk" > "$OUT/package.txt"
grep -q "package: name='kr.workbibleman.app'.*versionCode='18'.*versionName='0.9.1-dev'" "$OUT/package.txt"
if gh release view v0.9.1-dev --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo 'Bootstrap release already exists; not overwriting. Checking existing asset.'
  mkdir -p "$OUT/existing"
  gh release download v0.9.1-dev --repo "$GITHUB_REPOSITORY" --pattern work-bible-man.apk --dir "$OUT/existing" --clobber
  cmp "$OUT/work-bible-man.apk" "$OUT/existing/work-bible-man.apk"
else
  gh release create v0.9.1-dev "$OUT/work-bible-man.apk#work-bible-man.apk" --repo "$GITHUB_REPOSITORY" --title '워크 바이블 맨 v0.9.1-dev' --notes '오답 집중 학습에서 장·절과 해당 절 전체 문장을 표시하고, 문장 속 단어별 빈칸에 직접 입력합니다. 작은 화면 및 펼친 화면의 입력·채점·복습 기록 검사 통과. 기존 고정 서명 앱에 업데이트 설치할 수 있습니다. 본문: 성경전서 개역한글판(1961), 대한성서공회.'
fi
encoded=$(base64 -w0 "$OUT/latest.json")
existing=$(gh api "repos/$GITHUB_REPOSITORY/contents/latest.json" --jq '.sha' 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/latest.json" -f message='Publish signed v0.9.1-dev update feed' -f content="$encoded" -f sha="$existing" >/dev/null
else
  gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/latest.json" -f message='Publish signed v0.9.1-dev update feed' -f content="$encoded" >/dev/null
fi
echo 'PUBLISHED: verified APK release and latest.json feed.'

# Independently verify the public download without an Authorization header.
python3 - <<'PY'
import hashlib,json,time,urllib.request
from pathlib import Path
expected=json.loads(Path('out/latest.json').read_text())
for attempt in range(8):
    try:
        feed=json.load(urllib.request.urlopen('https://raw.githubusercontent.com/tarotbear/work-bible-man-updates/main/latest.json',timeout=30))
        assert feed==expected, 'public feed has not updated yet'
        data=urllib.request.urlopen(feed['apkUrl'],timeout=90).read()
        assert len(data)==feed['size']
        assert hashlib.sha256(data).hexdigest()==feed['sha256']
        print('PASS: v0.9.1 public update feed and APK download match verified release')
        break
    except Exception:
        if attempt==7: raise
        time.sleep(5)
PY

