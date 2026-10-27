"""Compile and run the runtime chain calibration regression without Apple SDK or device access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

CASES = [
    "documented-ios16",
    "documented-ios15",
    "second-hop-variant",
    "task-map-moved",
    "pmap-moved",
    "sweep-two-hop",
    "sweep-one-hop",
    "nothing-works",
    "budget",
    "safe-budget",
    "enumeration",
    "coverage",
]


def main():
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

    with tempfile.TemporaryDirectory(prefix="hud-chain-calib-") as directory:
        binary = Path(directory) / ("chain-calib.exe" if os.name == "nt" else "chain-calib")
        source = str(ROOT / "tests/hud_chain_calib_regressions.cpp")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", source, f"/Fe:{binary}"]
        else:
            options = ["-std=c++17", "-Wall", "-Wextra", source, "-o", str(binary)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=120)

        failed = []
        for case in CASES:
            result = subprocess.run([str(binary), case], timeout=60)
            if result.returncode != 0:
                failed.append(case)
        if failed:
            raise SystemExit("hud_chain_calib_regressions failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
