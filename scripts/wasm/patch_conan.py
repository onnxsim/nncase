#!/usr/bin/env python3
"""Patch conan (1.x) so `conan install` can resolve nncase's compiler-side
dependency graph for a wasm32-emscripten target, entirely offline from a
GitHub perspective.

Three independent problems this solves, in order:

1. conan's settings.yml enumerates known clang versions and tops out at 17;
   Emscripten's bundled clang is far newer. Rather than fight conan's
   profile-vs-CMake-detected-compiler cross-check (which requires the two to
   literally match), this just adds every clang version up to the one this
   Emscripten release bundles to that enum, so the build profile can name it
   directly.
2. flatbuffers/fmt/protobuf/spdlog/zlib/opencv/jasper/libjpeg-turbo/libpng
   have no prebuilt wasm32 binary on conancenter and must build from source --
   but their conandata.yml `sources:` point at github.com/zlib.net/sourceforge.net,
   none of which this build's network policy can necessarily reach. After
   nncase's own CMakeLists.txt/conanfile.py option gates
   (ENABLE_VULKAN_COMPILER, ENABLE_TFLITE_IMPORTER, the stb_image swap, and
   dropping the unused zlib requirement -- see this branch's own commits),
   only fmt, protobuf, and spdlog are left needing this: this rewrites their
   `sources:` entry to a `file://`-style localhost URL a caller has already
   started serving apt's own source packages from (Ubuntu ships all three;
   see build-wasm.sh), with a matching sha256.
3. spdlog 1.8.2's pinned fmt (7.1.3) is far older than the fmt actually
   substituted above (whatever Ubuntu ships) has moved to. Its own
   `SPDLOG_FMT_STRING` macro wraps every literal format string in fmt's
   `FMT_STRING`, whose compile-time-checked implementation trips a real
   consteval-strictness incompatibility under newer fmt + newer clang
   together (a bug, not a deliberate compile-time check failing correctly --
   confirmed by testing the exact same call succeeds at runtime). Patches
   spdlog's own source (not conan's cached recipe) to skip that wrapping,
   before conan ever downloads/extracts it, so nothing needs a second pass.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

import yaml

CONAN_PACKAGES = {
    "fmt": {"version": "7.1.3", "pattern": "fmtlib_*.orig.tar*"},
    "protobuf": {"version": "3.17.1", "pattern": "protobuf_*.orig.tar*"},
    "spdlog": {"version": "1.8.2", "pattern": "spdlog_*.orig.tar*"},
}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def patch_clang_versions(conan_home: Path, max_version: int) -> None:
    # A plain string/replace edit risks touching some *other* compiler's version
    # list that happens to share clang's exact tail (a real bug caught while
    # testing this script: a too-short marker matched Visual Studio's list
    # instead). Loading the whole file as YAML and editing compiler.clang.version
    # directly can't have that ambiguity, at the cost of losing settings.yml's
    # own comments and anchor/alias formatting on write-back -- fine here since
    # nothing reads this file except conan itself, immediately after.
    settings_path = conan_home / "settings.yml"
    data = yaml.safe_load(settings_path.read_text())
    versions = data["compiler"]["clang"]["version"]
    for v in range(18, max_version + 1):
        version_str = str(v)
        if version_str not in versions:
            versions.append(version_str)
    settings_path.write_text(yaml.safe_dump(data, sort_keys=False))
    print(f"patched {settings_path}: compiler.clang.version now includes up to {max_version}")


def patch_spdlog_source(orig_tarball: Path, out_tarball: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        with tarfile.open(orig_tarball) as tf:
            tf.extractall(tmp_path)  # noqa: S202 -- trusted, locally-fetched apt source

        (root,) = [p for p in tmp_path.iterdir() if p.is_dir()]
        common_h = root / "include" / "spdlog" / "common.h"
        text = common_h.read_text()
        needle = "#    define SPDLOG_FMT_STRING(format_string) FMT_STRING(format_string)"
        if needle not in text:
            raise RuntimeError(f"{common_h}: expected macro definition not found -- spdlog source layout may have changed")
        replacement = (
            "#    define SPDLOG_FMT_STRING(format_string) format_string "
            "/* patched: FMT_STRING's consteval check is incompatible with a newer fmt "
            "+ newer clang than this spdlog release was paired with -- see patch_conan.py's docstring */"
        )
        common_h.write_text(text.replace(needle, replacement, 1))

        with tarfile.open(out_tarball, "w:xz") as tf:
            tf.add(root, arcname=root.name)
    print(f"patched spdlog source ({common_h.relative_to(tmp_path)}) -> {out_tarball}")


def patch_conandata_sources(conan_home: Path, http_port: int, apt_src_dir: Path, spdlog_tarball: Path) -> None:
    for name, info in CONAN_PACKAGES.items():
        version = info["version"]
        if name == "spdlog":
            tarball = spdlog_tarball
        else:
            matches = sorted(apt_src_dir.glob(info["pattern"]))
            if not matches:
                raise RuntimeError(f"no apt source tarball matching {info['pattern']!r} in {apt_src_dir}")
            tarball = matches[0]

        conandata_path = conan_home / "data" / name / version / "_" / "_" / "export" / "conandata.yml"
        if not conandata_path.exists():
            raise RuntimeError(
                f"{conandata_path} doesn't exist yet -- run "
                f"`conan download {name}/{version}@ -r conancenter --recipe` first "
                "so conan's cache has the recipe (and this conandata.yml) to patch"
            )

        data = yaml.safe_load(conandata_path.read_text()) or {}
        data.setdefault("sources", {})[version] = {
            "url": f"http://127.0.0.1:{http_port}/{tarball.name}",
            "sha256": sha256_of(tarball),
        }
        # Patches keyed to the pinned version were written against that exact
        # upstream source; the substituted (newer) source may not match their
        # context lines, and none of them matter for a wasm32 compiler build
        # (protobuf's is a macOS-only SDK-macro fix).
        if "patches" in data and version in data.get("patches", {}):
            del data["patches"][version]
            if not data["patches"]:
                del data["patches"]

        conandata_path.write_text(yaml.safe_dump(data, sort_keys=False))
        print(f"patched {conandata_path} -> {tarball.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--conan-home", type=Path, required=True, help="conan's CONAN_USER_HOME (`conan config home`)")
    parser.add_argument("--clang-version", type=int, required=True, help="major clang version this Emscripten release bundles (`em++ --version`)")
    parser.add_argument("--apt-src-dir", type=Path, required=True, help="directory containing apt-get source --download-only output for fmtlib/protobuf/spdlog")
    parser.add_argument("--http-port", type=int, required=True, help="port a `python3 -m http.server` serving --apt-src-dir is (about to be) listening on")
    parser.add_argument("--spdlog-tarball-out", type=Path, required=True, help="where to write spdlog's patched source tarball")
    args = parser.parse_args()

    patch_clang_versions(args.conan_home, args.clang_version)

    spdlog_orig = sorted(args.apt_src_dir.glob(CONAN_PACKAGES["spdlog"]["pattern"]))
    if not spdlog_orig:
        raise RuntimeError(f"no spdlog source tarball found in {args.apt_src_dir}")
    patch_spdlog_source(spdlog_orig[0], args.spdlog_tarball_out)
    shutil.copy(args.spdlog_tarball_out, args.apt_src_dir / args.spdlog_tarball_out.name)

    patch_conandata_sources(args.conan_home, args.http_port, args.apt_src_dir, args.apt_src_dir / args.spdlog_tarball_out.name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
