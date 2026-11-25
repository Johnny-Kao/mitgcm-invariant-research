#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
EXP="$ROOT/verification/advect_xz"
OUT="$ROOT/research/results"
mkdir -p "$OUT"
git rev-parse HEAD | tee "$OUT/research-sha.txt"
gfortran --version | tee "$OUT/compiler.txt"
cd "$EXP/build"
../../../tools/genmake2 -mods=../code -of=../../../tools/build_options/linux_amd64_gfortran -rootdir=../../.. > "$OUT/genmake.log" 2>&1
make depend > "$OUT/depend.log" 2>&1
make -j2 > "$OUT/build-baseline.log" 2>&1
cp mitgcmuv "$OUT/mitgcmuv-baseline"
run_case() {
  local name="$1" binary="$2" scheme="$3"
  local run="$OUT/$name"
  mkdir -p "$run"
  cp -a "$EXP/input/." "$run/"
  cp -a "$EXP/input.nlfs/." "$run/"
  if [[ "$scheme" == 33 ]]; then
    python3 - "$run/data" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text()
assert 'tempAdvScheme=77,' in s and 'saltAdvScheme=3,' in s
s=s.replace('tempAdvScheme=77,','tempAdvScheme=33,\n tempVertAdvScheme=33,').replace('saltAdvScheme=3,','saltAdvScheme=33,\n saltVertAdvScheme=33,')
p.write_text(s)
PY
  fi
  (cd "$run" && "$binary" > model.log 2>&1)
  test -s "$run/model.log"
  if ! grep -Fq 'Execution ended Normally' "$run/model.log"; then
    echo "Missing normal completion marker in $name" >&2
    tail -n 50 "$run/model.log" >&2
    return 1
  fi
  if grep -iE 'ABNORMAL END|STOP in |ERROR STOP' "$run/model.log"; then
    echo "Model reported an error in $name" >&2; return 1
  fi
  echo "Native model completed: $name"
  test -n "$(find "$run" -name 'T.0000000200*.data' -print -quit)"
  test -n "$(find "$run" -name 'S.0000000200*.data' -print -quit)"
}
run_case control-original "$OUT/mitgcmuv-baseline" original
run_case dst3-original "$OUT/mitgcmuv-baseline" 33
python3 - "$ROOT/pkg/generic_advdiff/gad_dst3fl_impl_r.F" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text()
old='IF ( rTrans(i,j).GT.0. _d 0 ) THEN'
new='IF ( rTrans(i,j)*rkSign.GT.0. _d 0 ) THEN'
assert s.count(old)==1
p.write_text(s.replace(old,new))
PY
# Rebuild the actual native routine and relink, keeping all other objects.
rm -f gad_dst3fl_impl_r.o mitgcmuv
make -j2 > "$OUT/build-alternative.log" 2>&1
cp mitgcmuv "$OUT/mitgcmuv-alternative"
run_case control-alternative "$OUT/mitgcmuv-alternative" original
run_case dst3-alternative "$OUT/mitgcmuv-alternative" 33
python3 - "$OUT" <<'PY'
import pathlib,struct,sys,math
root=pathlib.Path(sys.argv[1])
def compare(a,b):
    a,b=root/a,root/b
    for tracer in ('T','S'):
        names=sorted(p.name for p in a.glob(f'{tracer}.0000000200*.data'))
        assert names
        d=[]; x=[]
        for name in names:
            pa,pb=a/name,b/name
            aa=[v[0] for v in struct.iter_unpack('>d',pa.read_bytes())]
            bb=[v[0] for v in struct.iter_unpack('>d',pb.read_bytes())]
            assert len(aa)==len(bb) and all(map(math.isfinite,aa+bb))
            d.extend(abs(u-v) for u,v in zip(aa,bb)); x.extend(abs(u) for u in aa)
        print(f'{a.name} vs {b.name} {tracer}: n={len(d)} max_abs={max(d):.12g} rms={math.sqrt(sum(v*v for v in d)/len(d)):.12g}')
        if a.name.startswith('control'): assert max(d)==0
compare('control-original','control-alternative')
compare('dst3-original','dst3-alternative')
PY
