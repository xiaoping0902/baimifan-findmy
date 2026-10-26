"""Compile the actual presentation-rate sampler without an Apple SDK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    environment = os.environ.copy()
    compiler = next((shutil.which(name) for name in ("clang++", "g++", "cl") if shutil.which(name)), None)
    if compiler is None:
        raise SystemExit("A C++17 compiler is required; initialize the developer shell on Windows.")
    with tempfile.TemporaryDirectory(prefix="hud-frame-rate-") as directory:
        binary = Path(directory) / ("frame-rate.exe" if os.name == "nt" else "frame-rate")
        source = str(ROOT / "tests/hud_frame_rate_regressions.cpp")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", source, f"/Fe:{binary}"]
        else:
            options = ["-std=c++17", "-pthread", source, "-o", str(binary)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
