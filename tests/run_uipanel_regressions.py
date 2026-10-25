"""Compile and exercise the production hosted panel using real ImGui frames.

No Apple SDK or GPU is required. On Windows, run from a Visual Studio developer
shell; on macOS/Linux, clang++ or g++ on PATH is sufficient.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    configured = os.environ.get("CXX")
    compiler = shlex.split(configured, posix=os.name != "nt") if configured else None
    if compiler is None:
        available = next((shutil.which(name) for name in ("clang++", "g++", "cl")
                          if shutil.which(name)), None)
        if not available:
            raise SystemExit("A C++17 compiler is required (clang++, g++, or a Visual Studio developer shell).")
        compiler = [available]
    sources = [ROOT / "tests/uipanel_render_regressions.cpp"]
    sources += [ROOT / f"app/Sources/Render/imgui/{name}.cpp" for name in
                ("imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
    include = ROOT / "app/Sources/Render/imgui"
    with tempfile.TemporaryDirectory(prefix="uipanel-regressions-") as directory:
        destination = Path(directory) / ("panel.exe" if os.name == "nt" else "panel")
        if Path(compiler[0]).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", f"/I{include}",
                       *(str(path) for path in sources), f"/Fe:{destination}"]
        else:
            options = ["-std=c++17", "-O1", f"-I{include}",
                       *(str(path) for path in sources), "-o", str(destination)]
        subprocess.run([*compiler, *options], cwd=directory, check=True, timeout=180)
        subprocess.run([str(destination)], cwd=directory, check=True, timeout=30)


if __name__ == "__main__":
    main()
