#!/usr/bin/env python3
"""Build the pinned official SentencePiece processor and a small C ABI for Swift.

Uses only vendored protobuf-lite/abseil sources; no dependency downloads by CMake.
Generated archives/XCFrameworks stay in ignored ModelArtifacts, never in git.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "tools/models/sentencepiece-source.json"
BRIDGE = ROOT / "tools/translation_runtime"
ARTIFACTS = ROOT / "ModelArtifacts"
OUTPUT = ARTIFACTS / "SentencePieceRuntime"
WORK = ARTIFACTS / "SentencePieceBuild"
FRAMEWORK = "SentencePieceRuntime.xcframework"
REQUIRED_FILES = {"SentencePiece-LICENSE.txt", f"{FRAMEWORK}/Info.plist"}
for _slice, _library in (
    ("macos-arm64", "libSentencePieceRuntime.a"),
    ("ios-arm64", "libSentencePieceRuntime.a"),
    ("ios-arm64_x86_64-simulator", "libSentencePieceRuntime-simulator.a"),
):
    REQUIRED_FILES.update({
        f"{FRAMEWORK}/{_slice}/{_library}",
        f"{FRAMEWORK}/{_slice}/Headers/SentencePieceRuntime.h",
        f"{FRAMEWORK}/{_slice}/Headers/module.modulemap",
    })


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def recipe_hash():
    digest = hashlib.sha256()
    for path in [CONFIG, Path(__file__), *sorted(BRIDGE.iterdir())]:
        if path.is_file():
            digest.update(path.name.encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def run(arguments):
    environment = dict(os.environ, ZERO_AR_DATE="1")
    subprocess.run([str(value) for value in arguments], check=True, env=environment)


def capture(arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def fetch(spec, path, offline):
    if path.exists():
        if sha256(path) != spec["sha256"]:
            raise ValueError("Cached SentencePiece source checksum does not match its pin")
        return
    if offline:
        raise ValueError("SentencePiece source archive is absent; rerun without --offline")
    temporary = path.with_suffix(".download")
    try:
        with urllib.request.urlopen(spec["url"], timeout=120) as response, temporary.open("wb") as target:
            shutil.copyfileobj(response, target)
        if sha256(temporary) != spec["sha256"]:
            raise ValueError("Downloaded SentencePiece source checksum does not match its pin")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def unpack(archive, destination, commit):
    prefix = f"sentencepiece-{commit}/"
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            if member.name.rstrip("/") == prefix.rstrip("/"):
                continue
            if not member.name.startswith(prefix):
                raise ValueError("Unexpected archive root")
            relative = Path(member.name[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts or member.issym() or member.islnk():
                raise ValueError("Unsafe SentencePiece archive member")
            path = destination / relative
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as original, path.open("wb") as target:
                    shutil.copyfileobj(original, target)
            else:
                raise ValueError("Unsupported SentencePiece archive member")


def verify(directory=None, announce=True):
    directory = OUTPUT if directory is None else Path(directory)
    manifest_path = directory / "runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    config = json.loads(CONFIG.read_text())
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ValueError("Unsupported SentencePiece runtime manifest schema")
    if manifest.get("source") != config:
        raise ValueError("SentencePiece runtime source provenance does not match its pin")
    if manifest.get("runtime_id") != config["runtime_id"] or manifest.get("recipe_sha256") != recipe_hash():
        raise ValueError("SentencePiece runtime recipe changed; rebuild it")
    expected = manifest.get("files")
    if not isinstance(expected, dict) or not REQUIRED_FILES.issubset(expected):
        raise ValueError("SentencePiece runtime inventory is missing required files")
    if directory.is_symlink() or any(path.is_symlink() for path in directory.rglob("*")):
        raise ValueError("SentencePiece runtime must not contain symbolic links")
    if any(not (directory / name).is_file() or (directory / name).stat().st_size == 0 for name in REQUIRED_FILES):
        raise ValueError("SentencePiece runtime is missing required nonempty files")
    actual = {str(path.relative_to(directory)): sha256(path) for path in directory.rglob("*")
              if path.is_file() and path != manifest_path}
    if actual != expected:
        raise ValueError("SentencePiece runtime inventory/checksum mismatch")
    if announce:
        print(f"Verified {len(expected)} runtime files: {directory}", flush=True)


def publish(package):
    """Retain the previous working package until its replacement is verified."""
    verify(package, announce=False)
    # Keep the backup outside the build's temporary directory. If rollback itself
    # fails (for example, disk permissions change), cleanup must not erase it.
    backup = OUTPUT.with_name(f".{OUTPUT.name}.previous-{uuid.uuid4().hex}")
    if OUTPUT.exists():
        OUTPUT.rename(backup)
    published = False
    try:
        package.rename(OUTPUT)
        published = True
        verify(announce=False)
    except BaseException:
        if published and OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        if backup.exists():
            backup.rename(OUTPUT)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def build(args):
    config = json.loads(CONFIG.read_text())
    if OUTPUT.exists() and not args.rebuild:
        verify()
        return
    if platform.system() != "Darwin":
        raise ValueError("Building this Apple runtime requires macOS with full Xcode")
    cmake = Path(args.cmake).resolve()
    version = capture([cmake, "--version"]).splitlines()[0]
    if version != f"cmake version {config['cmake_version']}":
        raise ValueError(f"Expected cmake {config['cmake_version']}, found {version}")
    WORK.mkdir(parents=True, exist_ok=True)
    archive = WORK / f"sentencepiece-{config['version']}.tar.gz"
    fetch(config["source_archive"], archive, args.offline)
    # A new source directory avoids trusting arbitrary mutations of a previous checkout.
    with tempfile.TemporaryDirectory(prefix="build-", dir=WORK) as temporary:
        staging = Path(temporary)
        source = staging / "source"
        unpack(archive, source, config["source_commit"])
        headers = staging / "Headers"
        headers.mkdir()
        for name in ["SentencePieceRuntime.h", "module.modulemap"]:
            shutil.copyfile(BRIDGE / name, headers / name)
        libraries = {}
        slices = [
            ("macos-arm64", "macosx", "arm64", "Darwin", config["macos_deployment_target"], "arm64-apple-macos13.0"),
            ("ios-arm64", "iphoneos", "arm64", "iOS", config["ios_deployment_target"], "arm64-apple-ios17.0"),
            ("simulator-arm64", "iphonesimulator", "arm64", "iOS", config["ios_deployment_target"], "arm64-apple-ios17.0-simulator"),
            ("simulator-x86_64", "iphonesimulator", "x86_64", "iOS", config["ios_deployment_target"], "x86_64-apple-ios17.0-simulator"),
        ]
        for name, sdk, architecture, system, deployment, triple in slices:
            print(f"Building SentencePiece {name}", flush=True)
            directory = staging / name
            sdk_path = capture(["xcrun", "--sdk", sdk, "--show-sdk-path"])
            run([cmake, "-S", source, "-B", directory,
                 "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_SYSTEM_NAME={system}",
                 f"-DCMAKE_PROJECT_INCLUDE={BRIDGE / 'AppleSupport.cmake'}",
                 f"-DCMAKE_OSX_SYSROOT={sdk_path}", f"-DCMAKE_OSX_ARCHITECTURES={architecture}",
                 f"-DCMAKE_OSX_DEPLOYMENT_TARGET={deployment}",
                 "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO",
                 "-DSPM_ENABLE_SHARED=OFF", "-DSPM_BUILD_TEST=OFF", "-DSPM_ENABLE_TCMALLOC=OFF",
                 "-DSPM_PROTOBUF_PROVIDER=internal", "-DSPM_ABSL_PROVIDER=internal"])
            run([cmake, "--build", directory, "--target", "sentencepiece-static", "--parallel", "8"])
            object_file = directory / "SentencePieceRuntime.o"
            run(["xcrun", "--sdk", sdk, "clang++", "-std=c++17", "-O3", "-fvisibility=hidden",
                 "-target", triple, "-isysroot", sdk_path, "-I", source / "src", "-I", BRIDGE,
                 "-c", BRIDGE / "SentencePieceRuntime.cpp", "-o", object_file])
            library = directory / "libSentencePieceRuntime.a"
            run(["xcrun", "libtool", "-static", "-o", library, directory / "src/libsentencepiece.a", object_file])
            libraries[name] = library
        simulator = staging / "libSentencePieceRuntime-simulator.a"
        run(["xcrun", "lipo", "-create", libraries["simulator-arm64"], libraries["simulator-x86_64"], "-output", simulator])
        package = staging / "package"
        package.mkdir()
        run(["xcodebuild", "-create-xcframework", "-library", libraries["macos-arm64"], "-headers", headers,
             "-library", libraries["ios-arm64"], "-headers", headers, "-library", simulator, "-headers", headers,
             "-output", package / "SentencePieceRuntime.xcframework"])
        license_parts = [("SentencePiece (Apache-2.0)", source / "LICENSE")]
        for dependency in ["absl", "protobuf-lite", "darts_clone", "esaxx"]:
            license_parts.append((f"Vendored {dependency}", source / "third_party" / dependency / "LICENSE"))
        (package / "SentencePiece-LICENSE.txt").write_text("\n\n".join(
            name + "\n" + path.read_text() for name, path in license_parts), encoding="utf-8")
        manifest = {
            "schema_version": 1, "runtime_id": config["runtime_id"], "source": config,
            "recipe_sha256": recipe_hash(), "xcode": capture(["xcodebuild", "-version"]),
            "cmake": version, "slices": [item[0] for item in slices],
            "dependency_policy": "SentencePiece internal protobuf-lite/abseil; network disabled in CMake configuration",
            "files": {str(path.relative_to(package)): sha256(path) for path in package.rglob("*") if path.is_file()},
        }
        (package / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        publish(package)
    verify()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake", default=str(ARTIFACTS / ".venv/bin/cmake"))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        verify() if args.verify else build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"SentencePiece preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
