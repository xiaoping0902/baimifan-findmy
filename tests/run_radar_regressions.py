"""Compile and run the production radar with actual ImGui geometry, without an Apple SDK."""
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
    sources = [ROOT / "tests/radar_render_regressions.cpp"]
    sources += [ROOT / f"app/Sources/Render/imgui/{name}.cpp" for name in ("imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
    include = ROOT / "app/Sources/Render/imgui"
    with tempfile.TemporaryDirectory(prefix="radar-regressions-") as directory:
        binary = Path(directory) / ("radar.exe" if os.name == "nt" else "radar")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", f"/I{include}", *(str(p) for p in sources), f"/Fe:{binary}"]
        else:
            options = ["-std=c++17", "-O1", f"-I{include}", *(str(p) for p in sources), "-o", str(binary)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=180)
        subprocess.run([str(binary)], cwd=directory, check=True, timeout=30)
        offscreen = Path(directory) / ("offscreen.exe" if os.name == "nt" else "offscreen")
        source = ROOT / "tests/offscreen_indicator_regressions.cpp"
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", str(source), f"/Fe:{offscreen}"]
        else:
            options = ["-std=c++17", str(source), "-o", str(offscreen)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=60)
        subprocess.run([str(offscreen)], cwd=directory, check=True, timeout=30)
        heading = Path(directory) / ("heading.exe" if os.name == "nt" else "heading")
        source = ROOT / "tests/hud_heading_regressions.cpp"
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            options = ["/nologo", "/std:c++17", "/EHsc", "/utf-8", str(source), f"/Fe:{heading}"]
        else:
            options = ["-std=c++17", str(source), "-o", str(heading)]
        subprocess.run([compiler, *options], cwd=directory, env=environment, check=True, timeout=60)
        subprocess.run([str(heading)], cwd=directory, check=True, timeout=30)


if __name__ == "__main__":
    main()
