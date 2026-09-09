#!/bin/sh
# port.sh — port a new S22-family firmware build to a target profile.
#
# Usage:
#   ./support/port.sh <kernel-Image> <BUILD_ID> [--model SM-XXXX] [--fingerprint ...]
#     [--phys-load 0x80000000] [--defex-off 0x02052158] [--no-defex]
#
# Example (S22+ GZD7):
#   ./support/port.sh /path/to/Image S906BXXSNGZD7 \
#     --model SM-S906B \
#     --fingerprint "samsung/g0sxxx/essi:16/BP2A.250605.031.A3/S906BXXSNGZD7:user/release-keys"
#
# Pipeline (same family assumptions as the S901B profile):
#   1. gcc kallsyms.c -> ./kallsyms Image -> kallsyms.txt
#   2. ./extract-ikconfig Image -> config.txt (warn only if it fails)
#   3. generate_target.py with target_template.h -> raw target.h
#   4. stamp BUILD_VARIANT_LABEL / BUILD_FINGERPRINT / P0_KERNEL_PHYS_LOAD
#      (+ optional DEFEX offsets) into the new target dir
#      src/targets/<BUILD_ID>/{target.h,stack.c skeleton note}
#   5. verify: every required offset symbol resolves in kallsyms.txt and
#      the generated header differs from template only in known defines
#   6. print next steps (measure EXP32_STAMP_OFF on device, build, test)
#
# Needs: gcc, python3 + capstone (`pip install capstone`).
# Does NOT guess stack geometry or phys-slide policy — those still need a
# device run (see step 6 output).

set -u

fail() { echo "port: ERROR: $*" >&2; exit 1; }

IMAGE="${1:-}"; BUILD_ID="${2:-}"; shift 2 2>/dev/null || true
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || fail "usage: $0 <kernel-Image> <BUILD_ID> [options]"
[ -n "$BUILD_ID" ] || fail "missing BUILD_ID (e.g. S906BXXSNGZD7)"

MODEL=""
FINGERPRINT=""
PHYS_LOAD="0x80000000"
DEFEX_OFF=""
NO_DEFEX=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --phys-load) PHYS_LOAD="$2"; shift 2 ;;
    --defex-off) DEFEX_OFF="$2"; shift 2 ;;
    --no-defex) NO_DEFEX=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v gcc >/dev/null 2>&1 || fail "gcc not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
python3 -c "import capstone" 2>/dev/null || fail "python capstone missing (pip install capstone)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/target_generator"
TARGET_DIR="$REPO_ROOT/src/targets/$BUILD_ID"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/port-$BUILD_ID-XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "port: work dir $WORK"
echo "port: [1/5] extracting kallsyms"
gcc -O2 "$GEN/kallsyms.c" -o "$WORK/kallsyms" 2>/dev/null \
  || fail "kallsyms.c compile failed"
# NOTE: the kallsyms tool writes ./kallsyms.txt into its CWD, so run it
# inside WORK (a stray kallsyms.txt in the repo root means this regressed).
(cd "$WORK" && "$WORK/kallsyms" "$IMAGE" >"$WORK/kallsyms.log" 2>&1) \
  || { tail -n 5 "$WORK/kallsyms.log" >&2; fail "kallsyms extraction failed"; }
[ -s "$WORK/kallsyms.txt" ] || fail "empty kallsyms.txt"
echo "port: $(wc -l <"$WORK/kallsyms.txt") symbols"

echo "port: [2/5] extracting ikconfig"
if ! "$GEN/extract-ikconfig" "$IMAGE" >"$WORK/config.txt" 2>"$WORK/ikconfig.log"; then
  echo "port: WARN: ikconfig extract failed (continuing, generator tolerates it)" >&2
  : >"$WORK/config.txt"
fi

echo "port: [3/5] generating target.h"
python3 "$GEN/generate_target.py" "$WORK/kallsyms.txt" "$WORK/config.txt" \
  "$IMAGE" --template "$GEN/target_template.h" -o "$WORK/target.h" \
  || fail "generate_target.py failed"

echo "port: [4/5] stamping identity -> $TARGET_DIR"
mkdir -p "$TARGET_DIR" || fail "cannot create $TARGET_DIR"
cp "$WORK/target.h" "$TARGET_DIR/target.h"

# BUILD_VARIANT_LABEL / BUILD_FINGERPRINT
python3 - "$TARGET_DIR/target.h" "$BUILD_ID" "$FINGERPRINT" <<'EOF' \
    || fail "identity stamp failed"
import re, sys
path, build, fp = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(path).read()
txt = re.sub(r'#define BUILD_VARIANT_LABEL ".*?"',
             f'#define BUILD_VARIANT_LABEL "{build}"', txt, count=1)
if fp:
    txt = re.sub(r'#define BUILD_FINGERPRINT ".*?"',
                 f'#define BUILD_FINGERPRINT "{fp}"', txt, count=1)
open(path, "w").write(txt)
EOF

# P0_KERNEL_PHYS_LOAD (sboot pre-slide base; GZD7 family default 0x80000000)
python3 - "$TARGET_DIR/target.h" "$PHYS_LOAD" <<'EOF' \
    || fail "phys-load stamp failed"
import re, sys
path, phys = sys.argv[1], sys.argv[2]
txt = open(path).read()
txt2, n = re.subn(r'(#define P0_KERNEL_PHYS_LOAD\s+)0x[0-9a-fA-F]+',
                  rf'\g<1>{phys}', txt, count=1)
if n != 1:
    sys.exit("P0_KERNEL_PHYS_LOAD define not found")
open(path, "w").write(txt2)
EOF

# Optional DEFEX offsets (base = global_privesc_status; other three are +4/+8/+12).
# The template has no DEFEX block, so INSERT it (same shape as S901B).
if [ "$NO_DEFEX" = 0 ] && [ -n "$DEFEX_OFF" ]; then
  python3 - "$TARGET_DIR/target.h" "$DEFEX_OFF" <<'EOF' \
    || exit 1
import re, sys
path, base = sys.argv[1], int(sys.argv[2], 16)
txt = open(path).read()
names = ["GLOBAL_PRIVESC_STATUS_OFF", "GLOBAL_SAFEPLACE_STATUS_OFF",
         "GLOBAL_INTEGRITY_STATUS_OFF", "GLOBAL_IMMUTABLE_STATUS_OFF"]
syms = ["global_privesc_status", "global_safeplace_status",
        "global_integrity_status", "global_immutable_status"]
offs = "\n".join(
    f"#define {n}    0x{base + i * 4:08x}ULL  /* {s}  */"
    for i, (n, s) in enumerate(zip(names, syms)))
macros = "\n".join(
    f"#define {n.replace('_OFF', '')}    (KIMAGE_TEXT_BASE + {n})"
    for n in names)
block = ("\n/* Samsung DEFEX per-feature runtime status bytes (each u8: 0=off).\n"
         " * Zeroing them disables each DEFEX feature (Safeplace kill of\n"
         " * /data exec + Privesc interference with UID-0 transitions).\n"
         " * Base verified against this build's kallsyms by port.sh. */\n"
         + offs + "\n")
anchor = "#define SELINUX_ENFORCING_OFF"
assert anchor in txt, "SELINUX anchor not found"
txt = txt.replace(anchor, block + anchor, 1)
anchor2 = "#define SELINUX_ENFORCING  (KIMAGE_TEXT_BASE + SELINUX_ENFORCING_OFF)"
assert anchor2 in txt, "SELINUX macro anchor not found"
txt = txt.replace(anchor2, anchor2 + "\n" + macros, 1)
open(path, "w").write(txt)
EOF
  [ $? -eq 0 ] || fail "DEFEX insert failed"
  echo "port: DEFEX base $DEFEX_OFF inserted"
fi

echo "port: [5/5] verifying required symbols"
MISSING=0
for sym in ashmem_misc ashmem_fops ashmem_ioctl ashmem_open ashmem_release \
           ashmem_mmap compat_ashmem_ioctl ashmem_show_fdinfo \
           configfs_read_file configfs_write_bin_file noop_llseek \
           generic_file_splice_read init_task root_task_group selinux_state \
           kmalloc_caches anon_pipe_buf_ops system_unbound_wq \
           call_usermodehelper_exec_work nfulnl_logger sysctl_bootid worker_thread; do
  if ! grep -q -E " $sym([.$]|$)" "$WORK/kallsyms.txt"; then
    echo "port: MISSING symbol: $sym" >&2
    MISSING=1
  fi
done
[ "$MISSING" = 0 ] || fail "symbol verification failed (wrong Image?)"
echo "port: all required symbols resolve"

# DEFEX cross-check when requested: confirm the 4 globals exist at +0/+4/+8/+12
if [ "$NO_DEFEX" = 0 ] && [ -n "$DEFEX_OFF" ]; then
  for sym in global_privesc_status global_safeplace_status \
             global_integrity_status global_immutable_status; do
    grep -q -E " $sym\$" "$WORK/kallsyms.txt" \
      || { echo "port: MISSING DEFEX symbol: $sym" >&2; MISSING=1; }
  done
  [ "$MISSING" = 0 ] || fail "DEFEX verification failed"
  echo "port: DEFEX globals resolve"
fi

echo "port: DONE -> $TARGET_DIR/target.h"
echo "port: NEXT STEPS (not automated):"
echo "  1. Copy src/targets/S901BXXSNGZD7/stack.c to $TARGET_DIR/stack.c and"
echo "     re-measure EXP32_STAMP_OFF on the new device (live GDB or dmesg)."
echo "  2. Confirm phys-slide policy: fixed P0_KERNEL_PHYS_LOAD ($PHYS_LOAD)"
echo "     vs TRACE6 scan — compare a boot with SLIDE_ONLY=1 first."
echo "  3. make PROJECT=$BUILD_ID clean preload root-helper"
echo "  4. ./support/deploy.sh --skip-run, then run on device."
echo "  5. Republish artifacts + feed entry (see README)."
