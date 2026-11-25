#!/usr/bin/env bash
# ============================================================================
# tests/run.sh - build, then run every tests/<dir>/<test>.sh in every image.
#
#   tests/run.sh                          all images, all tests
#   tests/run.sh -i ubuntu:22.04 -i centos:7
#   tests/run.sh -t build/paste -t lint   tests whose "<dir>/<name>" contains a pattern
#   tests/run.sh --no-build --no-cache --platform linux/amd64
#
# Each test runs as:  docker run --rm -v <repo>:/kit:ro <image> bash /kit/tests/<dir>/<test>.sh
# Exit 0 = PASS, 77 = SKIP, other = FAIL. Logs: tests/.work/logs/<image>/<dir>-<test>.log
#
# Package installs are slow, so by default each image is "warmed" once with
# tests/lib/container-prep.sh --warm and cached as sdmkit-test:<image>-<hash>
# (rebuilt when container-prep.sh changes). --no-cache uses the raw images.
# Runs on macOS bash 3.2 and Linux.
# ============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFAULT_IMAGES="ubuntu:22.04 rockylinux:9 amazonlinux:2023 centos:7 debian:12"
IMAGES=""; PATTERNS=""; BUILD=1; CACHE=1; PLATFORM=""; VERBOSE=0

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case $1 in
    -i|--image) IMAGES="$IMAGES $2"; shift 2;;
    -t|--test) PATTERNS="$PATTERNS $2"; shift 2;;
    --no-build) BUILD=0; shift;;
    --no-cache) CACHE=0; shift;;
    --platform) PLATFORM=$2; shift 2;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done
IMAGES=${IMAGES:-$DEFAULT_IMAGES}

command -v docker >/dev/null 2>&1 || { echo "tests/run.sh: docker is required" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "tests/run.sh: docker daemon is not reachable" >&2; exit 2; }

if [ "$BUILD" = 1 ]; then
  echo "== build"
  "$ROOT/tools/build.sh" || { echo "tests/run.sh: build failed" >&2; exit 1; }
fi

# Discover tests (tests/lib is helpers, not tests).
TESTS=""
for f in $(cd "$ROOT/tests" && find . -mindepth 2 -maxdepth 2 -name '*.sh' ! -path './lib/*' | sed 's|^\./||' | LC_ALL=C sort); do
  id=${f%.sh}
  if [ -n "$PATTERNS" ]; then
    keep=0; for p in $PATTERNS; do case $id in *"$p"*) keep=1;; esac; done
    [ "$keep" = 1 ] || continue
  fi
  TESTS="$TESTS $id"
done
[ -n "$TESTS" ] || { echo "tests/run.sh: no tests match:$PATTERNS" >&2; exit 2; }

PLAT_ARGS=""; [ -n "$PLATFORM" ] && PLAT_ARGS="--platform $PLATFORM"
LOGROOT=$ROOT/tests/.work/logs
rm -rf "$LOGROOT"; mkdir -p "$LOGROOT"

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.\n' '-'; }
prep_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ROOT/tests/lib/container-prep.sh"
  else shasum -a 256 "$ROOT/tests/lib/container-prep.sh"; fi | cut -c1-12
}

# warm_image IMAGE -> prints the image to run tests in
warm_image() {
  local img=$1 tag name
  # shellcheck disable=SC2086
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q $PLAT_ARGS "$img" >/dev/null 2>&1 \
    || { echo "tests/run.sh: cannot pull $img" >&2; return 1; }
  if [ "$CACHE" = 0 ]; then echo "$img"; return 0; fi
  tag="sdmkit-test:$(slug "$img")-$(prep_hash)${PLATFORM:+-$(slug "$PLATFORM")}"
  if docker image inspect "$tag" >/dev/null 2>&1; then echo "$tag"; return 0; fi
  name="sdmkit-warm-$$-$(slug "$img")"
  echo "   warming $img -> $tag (one-off package install)" >&2
  # shellcheck disable=SC2086
  if docker run --name "$name" $PLAT_ARGS -v "$ROOT:/kit:ro" "$img" bash /kit/tests/lib/container-prep.sh --warm \
       > "$LOGROOT/warm-$(slug "$img").log" 2>&1 \
     && docker commit "$name" "$tag" >/dev/null 2>&1; then
    docker rm -f "$name" >/dev/null 2>&1; echo "$tag"
  else
    docker rm -f "$name" >/dev/null 2>&1
    echo "   warming failed, using raw $img (see $LOGROOT/warm-$(slug "$img").log)" >&2
    echo "$img"
  fi
}

if [[ " $TESTS " == *" check/"* ]]; then
  mkdir -p "$ROOT/tests/.work/bin"
  for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -o "$ROOT/tests/.work/bin/tlsproxy-$arch" "$ROOT/tests/check/lib/tlsproxy.go" || exit 1
  done
fi
RESULTS=""; NFAIL=0; NPASS=0; NSKIP=0
for img in $IMAGES; do
  echo "== $img"
  if ! run_img=$(warm_image "$img"); then
    for t in $TESTS; do RESULTS="$RESULTS
$img|$t|FAIL|0|image unavailable"; NFAIL=$((NFAIL + 1)); done
    continue
  fi
  mkdir -p "$LOGROOT/$(slug "$img")"
  for t in $TESTS; do
    log="$LOGROOT/$(slug "$img")/$(printf '%s' "$t" | tr '/' '-').log"
    start=$(date +%s)
    # shellcheck disable=SC2086
    docker run --rm $PLAT_ARGS -v "$ROOT:/kit:ro" -e KIT_TEST_IMAGE="$img" "$run_img" \
      bash "/kit/tests/$t.sh" > "$log" 2>&1
    rc=$?
    secs=$(( $(date +%s) - start ))
    case $rc in
      0) st=PASS; NPASS=$((NPASS + 1));;
      77) st=SKIP; NSKIP=$((NSKIP + 1));;
      *) st=FAIL; NFAIL=$((NFAIL + 1));;
    esac
    printf '   %-4s %-22s %4ss\n' "$st" "$t" "$secs"
    if [ "$st" = FAIL ]; then
      grep '^FAIL' "$log" | head -8 | sed 's/^/        /'
      [ "$VERBOSE" = 1 ] && sed 's/^/        | /' "$log"
    fi
    RESULTS="$RESULTS
$img|$t|$st|$secs|${log#"$ROOT"/}"
  done
done

echo
echo "== results"
printf '%-18s %-22s %-5s %5s  %s\n' IMAGE TEST RESULT SECS LOG
printf '%s\n' "$RESULTS" | while IFS='|' read -r i t s secs l; do
  [ -n "$i" ] && printf '%-18s %-22s %-5s %5s  %s\n' "$i" "$t" "$s" "$secs" "$l"
done
echo
echo "$NPASS passed, $NFAIL failed, $NSKIP skipped"
[ "$NFAIL" -eq 0 ]
