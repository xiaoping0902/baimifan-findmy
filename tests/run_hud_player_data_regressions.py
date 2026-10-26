"""Compile the production SDK player/gear decoder without Apple SDK or game access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


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
    with tempfile.TemporaryDirectory(prefix="hud-player-data-") as directory:
        binary = Path(directory) / ("player-data.exe" if os.name == "nt" else "player-data")
        source = str(ROOT / "tests/hud_player_data_regressions.cpp")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", source, f"/Fe:{binary}"]
        else:
            options = ["-std=c++17", source, "-o", str(binary)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
