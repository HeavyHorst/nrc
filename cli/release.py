#!/usr/bin/env python3
"""Build CLI release archives with licenses; never upload or create releases."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


CLI = Path(__file__).resolve().parent
REPO = CLI.parent
TARGETS = ("linux/amd64", "linux/arm64", "darwin/amd64", "darwin/arm64",
           "windows/amd64", "windows/arm64")


def go(*args, env=None):
    return subprocess.check_output(["go", *args], cwd=CLI, env=env, text=True).strip()


def decode_objects(text):
    decoder = json.JSONDecoder()
    while text.strip():
        obj, end = decoder.raw_decode(text.lstrip())
        yield obj
        text = text.lstrip()[end:]


def copy_notices(source, destination):
    """Keep upstream bytes and nested notices, including additional attributions."""
    files = []
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        name = path.name.upper()
        if not any(name.startswith(prefix) for prefix in
                   ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "PATENTS")):
            continue
        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        files.append(relative.as_posix())
    if not any(Path(name).name.upper().startswith(("LICENSE", "LICENCE", "COPYING"))
               for name in files):
        raise RuntimeError(f"No license text found in {source}; review this dependency before release")
    return files


def collect_licenses(stage, packages, goroot, go_version):
    shutil.copyfile(REPO / "LICENSE", stage / "LICENSE")
    modules = {}
    for package in packages:
        module = package.get("Module")
        if module:
            modules[module["Path"]] = module
    entries = ["# CLI third-party notices", "",
               f"Built with {go_version}.", "",
               "License files are copied unchanged. This collection includes all notices",
               "found in each imported module and the Go source tree, including notices",
               "for files not linked into this binary. It is not an exact linked-code SBOM.", "",
               "NRC and its protocol-go package are covered by the included LICENSE.", ""]
    for name, module in sorted(modules.items()):
        source = Path(module["Dir"]).resolve()
        if name in ("github.com/heavyhorst/nrc/cli", "github.com/heavyhorst/nrc/protocol-go"):
            continue
        version = module.get("Version", "")
        if module.get("Replace"):
            raise RuntimeError(f"Review external module replacement before release: {name}")
        destination = Path("licenses") / "modules" / (name + "@" + version)
        files = copy_notices(source, stage / destination)
        entries.extend([f"## {name} {version}", ""])
        entries.extend(f"- [{file}]({(destination / file).as_posix()})" for file in files)
        entries.append("")
    destination = Path("licenses") / "go"
    (stage / destination).mkdir(parents=True)
    for name in ("LICENSE", "PATENTS"):
        shutil.copyfile(goroot / name, stage / destination / name)
    files = copy_notices(goroot / "src", stage / destination / "src")
    entries.extend(["## Go standard library and runtime", "",
                    "- [LICENSE](licenses/go/LICENSE)", "- [PATENTS](licenses/go/PATENTS)"])
    entries.extend(f"- [{file}](licenses/go/src/{file})" for file in files)
    (stage / "THIRD_PARTY_NOTICES.md").write_text("\n".join(entries) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="Release label, for example cli-v0.7.0")
    parser.add_argument("--output", type=Path, default=CLI / "dist")
    parser.add_argument("--target", action="append", choices=TARGETS,
                        help="Repeat to select targets; defaults to all six")
    args = parser.parse_args()
    if not args.version or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
                               for c in args.version) or args.version in (".", ".."):
        parser.error("version must be a filename-safe release label")
    targets = list(dict.fromkeys(args.target or TARGETS))
    output = args.output.resolve()
    checksum_path = output / f"nrc_{args.version}_SHA256SUMS"
    if checksum_path.exists():
        parser.error(f"already exists: {checksum_path}")
    for target in targets:
        stem = f"nrc_{args.version}_{target.replace('/', '_')}"
        suffix = ".zip" if target.startswith("windows/") else ".tar.gz"
        if (output / (stem + suffix)).exists():
            parser.error(f"archive already exists: {stem + suffix}")
    output.mkdir(parents=True, exist_ok=True)
    checksums = []
    for target in targets:
        system, arch = target.split("/")
        env = {**os.environ, "CGO_ENABLED": "0", "GOOS": system, "GOARCH": arch,
               "GOFLAGS": "", "GOWORK": "off"}
        stem = f"nrc_{args.version}_{system}_{arch}"
        with tempfile.TemporaryDirectory(prefix="nrc-release-") as temporary:
            stage = Path(temporary) / stem
            stage.mkdir()
            binary = stage / ("nrc.exe" if system == "windows" else "nrc")
            go("build", "-mod=readonly", "-trimpath", "-ldflags", f"-X main.version={args.version}",
               "-o", str(binary), "./cmd/nrc", env=env)
            packages = list(decode_objects(go("list", "-mod=readonly", "-deps", "-json", "./cmd/nrc", env=env)))
            collect_licenses(stage, packages, Path(go("env", "GOROOT", env=env)), go("version", env=env))
            archive = Path(shutil.make_archive(str(output / stem), "zip" if system == "windows" else "gztar",
                                               root_dir=temporary, base_dir=stem))
        checksums.append(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}")
        print(f"Created {archive}")
    checksum_path.write_text("\n".join(checksums) + "\n")
    print(f"Created {checksum_path}")


if __name__ == "__main__":
    main()
