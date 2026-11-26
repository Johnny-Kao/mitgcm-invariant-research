#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
OUT="$ROOT/research/core-results"
mkdir -p "$OUT"
run_model() {
  local exp="$1" dir="$2"
  (cd "$dir" && "$exp/build/mitgcmuv" > model.log 2>&1)
  if ! grep -Fq 'Execution ended Normally' "$dir/model.log"; then
    tail -n 60 "$dir/model.log"; return 1
  fi
}
for name in advect_xz tutorial_baroclinic_gyre; do
  exp="$ROOT/verification/$name"
  target="$OUT/$name"
  mkdir -p "$target"
  (cd "$exp/build" && ../../../tools/genmake2 -mods=../code -of=../../../tools/build_options/linux_amd64_gfortran -rootdir=../../.. -disable=mnc && make depend && make -j2) > "$target/build.log" 2>&1
  if [[ "$name" == advect_xz ]]; then total=200; splits="100 101"; else total=10; splits="5 6"; fi
  prepare() {
    local run="$1" start="$2" stop="$3"
    mkdir -p "$run"
    cp -a "$exp/input/." "$run/"
    if [[ "$name" == advect_xz ]]; then cp -a "$exp/input.nlfs/." "$run/"; fi
    python3 - "$run" "$start" "$stop" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); start,stop=map(int,sys.argv[2:])
f=p/'data'; s=f.read_text()
for key in ('startTime','endTime','nIter0','nTimeSteps','pChkptFreq','chkptFreq','dumpFreq'):
    s=re.sub(r'(?im)^\s*'+key+r'\s*=.*$', '',s)
s=s.replace('&PARM03',f'&PARM03\n nIter0={start},\n startTime={start*1200}.,\n endTime={stop*1200}.,\n pChkptFreq={stop*1200}.,\n chkptFreq=0.,\n dumpFreq=1200.,')
for key in ('readBinaryPrec','writeBinaryPrec'):
    s=re.sub(r'(?im)^\s*'+key+r'\s*=.*$', '',s)
s=s.replace('&PARM01','&PARM01\n readBinaryPrec=64,\n writeBinaryPrec=64,')
f.write_text(s)
q=p/'data.pkg'; q.write_text(re.sub(r'(?i)useMNC\s*=\s*\.TRUE\.', 'useMNC=.FALSE.',q.read_text()))
PY
  }
  prepare "$target/continuous" 0 "$total"
  run_model "$exp" "$target/continuous"
  for split in $splits; do
    prepare "$target/first-$split" 0 "$split"
    run_model "$exp" "$target/first-$split"
    prepare "$target/restart-$split" "$split" "$total"
    suffix=$(printf '%010d' "$split")
    files=("$target/first-$split"/pickup."$suffix"*)
    test -f "${files[0]}"
    cp "${files[@]}" "$target/restart-$split/"
    run_model "$exp" "$target/restart-$split"
    python3 - "$target" "$total" "$split" <<'PY'
import pathlib,struct,sys,math,json
root=pathlib.Path(sys.argv[1]); total,split=map(int,sys.argv[2:]); suffix=f'{total:010d}'
a=root/'continuous'; b=root/f'restart-{split}'
out={}
for field in ('T','S','U','V','Eta','pickup'):
    files=sorted(a.glob(f'{field}.{suffix}*.data'))
    if not files: continue
    maxerr=0.; count=0; changed=0
    for f in files:
        g=b/f.name
        assert g.exists(),g
        aa=[x[0] for x in struct.iter_unpack('>d',f.read_bytes())]
        bb=[x[0] for x in struct.iter_unpack('>d',g.read_bytes())]
        assert len(aa)==len(bb) and all(map(math.isfinite,aa+bb))
        count+=len(aa); changed+=sum(x!=y for x,y in zip(aa,bb))
        maxerr=max(maxerr,max(abs(x-y) for x,y in zip(aa,bb)))
    out[field]=dict(count=count,changed=changed,max_abs=maxerr)
assert 'T' in out and 'pickup' in out,out
print(root.name,split,json.dumps(out,sort_keys=True))
(root/f'comparison-{split}.json').write_text(json.dumps(out,indent=2))
PY
  done
done
