#!/usr/bin/env python3
"""Package an existing CLI binary with licenses from its recorded build versions."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from release import collect_licenses


def package_binary(binary, output):
    binary = binary.resolve()
    metadata = json.loads(subprocess.check_output(
        ["go", "version", "-m", "-json", str(binary)], text=True))
    if metadata["Main"]["Path"] != "github.com/heavyhorst/nrc/cli":
        raise RuntimeError("Not an NRC CLI binary")
    settings = {item["Key"]: item["Value"] for item in metadata["Settings"]}
    if settings.get("CGO_ENABLED") != "0":
        raise RuntimeError("CGO dependencies need a separate license review")
    version = metadata["GoVersion"].split("-X:")[0]
    if not re.fullmatch(r"go\d+\.\d+\.\d+", version):
        raise RuntimeError("A released Go toolchain version is required")
    output = output.resolve()
    stem = binary.name + "-licensed"
    archive_path = output / (stem + ".tar.gz")
    if archive_path.exists() or Path(str(archive_path) + ".sha256").exists():
        raise RuntimeError(f"Refusing to overwrite {archive_path}")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="nrc-existing-release-") as temporary:
        stage = Path(temporary) / stem
        stage.mkdir()
        env = {**os.environ, "GOTOOLCHAIN": version, "GOWORK": "off", "GOFLAGS": ""}
        modules = []
        for dependency in metadata["Deps"]:
            if dependency.get("Replace"):
                if (dependency["Path"] == "github.com/heavyhorst/nrc/protocol-go"
                        and dependency["Replace"]["Path"] == "../protocol-go"):
                    continue
                raise RuntimeError(f"Review replacement: {dependency['Path']}")
            downloaded = json.loads(subprocess.check_output(
                ["go", "mod", "download", "-json", dependency["Path"] + "@" + dependency["Version"]],
                cwd=temporary, env=env, text=True))
            if downloaded.get("Sum") != dependency.get("Sum"):
                raise RuntimeError(f"Module checksum differs from binary: {dependency['Path']}")
            modules.append({"Module": downloaded})
        goroot = Path(subprocess.check_output(["go", "env", "GOROOT"], cwd=temporary,
                                             env=env, text=True).strip())
        collect_licenses(stage, modules, goroot, metadata["GoVersion"])
        shutil.copy2(binary, stage / binary.name)
        (stage / binary.name).chmod(0o755)
        (stage / "BUILD_INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        (stage / "BINARY_SHA256SUMS").write_text(f"{digest}  {binary.name}\n")
        archive = Path(shutil.make_archive(str(output / stem), "gztar", root_dir=temporary, base_dir=stem))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    Path(str(archive) + ".sha256").write_text(f"{digest}  {archive.name}\n")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(package_binary(args.binary, args.output))
