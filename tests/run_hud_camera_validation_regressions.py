"""Execute the actual MFUEBuildCamera body without Apple SDK or game access.

The camera POD declaration and FOV limits also come from production headers.
Each corrupt sample group runs in a subprocess so an angle-loop regression
fails with a deadline instead of hanging the entire regression/build job.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "app/Sources/Game"
CASES = ("valid", "yaw-infinity", "pitch-infinity", "roll-infinity", "huge-finite", "invalid-fields")


def production_builder():
    source = (GAME / "MFUEReader.mm").read_text(encoding="utf-8")
    start = source.index("static BOOL MFUEBuildCamera(")
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    environment = os.environ.copy()
    compiler = next((shutil.which(name) for name in ("clang++", "g++", "cl") if shutil.which(name)), None)
    if compiler is None and os.name == "nt":
        vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = subprocess.check_output([str(vswhere), "-latest", "-property", "installationPath"], text=True).strip()
        batch = Path(installation) / "VC/Auxiliary/Build/vcvars64.bat"
        output = subprocess.check_output(f'"{batch}" >nul && set', shell=True, text=True)
        environment.update(line.split("=", 1) for line in output.splitlines() if "=" in line and not line.startswith("="))
        compiler = shutil.which("cl", path=environment.get("Path", environment.get("PATH")))
    if compiler is None:
        raise SystemExit("A C++17 compiler is required.")

    projection = (GAME / "MFProjection.h").read_text(encoding="utf-8")
    camera = re.search(r"typedef struct \{[^}]*\} MFCamera;", projection).group()
    offsets = (GAME / "MFUEOffsets.h").read_text(encoding="utf-8")
    limits = "\n".join(re.search(rf"static const float {name}\s*=\s*[^;]+;", offsets).group()
                       for name in ("kMFUE_POV_FovMin", "kMFUE_POV_FovMax"))
    tests = (ROOT / "tests/hud_camera_validation_regressions.cpp").read_text(encoding="utf-8")
    prelude = """#include <cmath>
typedef bool BOOL;
constexpr BOOL YES = true, NO = false;
#if __has_include("MFUECameraValidation.h")
#include "MFUECameraValidation.h"
#endif
"""
    with tempfile.TemporaryDirectory(prefix="hud-camera-validation-") as directory:
        binary = Path(directory) / ("camera.exe" if os.name == "nt" else "camera")
        source = Path(directory) / "camera.cpp"
        source.write_text("\n".join((prelude, camera, limits, production_builder(), tests)), encoding="utf-8")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", f"/I{GAME}", str(source), f"/Fe:{binary}"]
        else:
            options = ["-std=c++17", "-I", str(GAME), str(source), "-o", str(binary)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=60)
        failures = []
        for case in (args.case,) if args.case else CASES:
            try:
                result = subprocess.run([str(binary), case], timeout=3)
                if result.returncode:
                    failures.append(case)
            except subprocess.TimeoutExpired:
                print(f"FAIL: production camera {case} exceeded 3s; remote angle validation must terminate", flush=True)
                failures.append(case)
        if failures:
            raise SystemExit("Failed camera cases: " + ", ".join(failures))


if __name__ == "__main__":
    main()
