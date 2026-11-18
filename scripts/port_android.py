#!/usr/bin/env python3
"""
NxNative Launcher - Android Port Bridge
Executes the isolated nx2android port pipeline while maintaining full compatibility
with the BuildRunner JSON progress protocol.
"""
import os
import sys
import subprocess
from pathlib import Path

def main():
    scripts_dir = Path(__file__).resolve().parent
    repo_root = scripts_dir.parent
    nx2android_dir = repo_root / "tools" / "nx2android"
    
    if not nx2android_dir.exists():
        # Fallback to user directory if placed there
        user_tools = Path.home() / "Library" / "Application Support" / "nx2android"
        if user_tools.exists() and (user_tools / "porter").exists():
            nx2android_dir = user_tools

    if not (nx2android_dir / "porter").exists():
        print(f'{{"ev": "say", "msg": "[RED] nx2android engine not found at {nx2android_dir}."}}', flush=True)
        sys.exit(1)

    # Pass all incoming CLI args to `python -m porter port ...`
    # BuildRunner invokes this script with: <gameDirectory> [options]
    args = sys.argv[1:]
    
    # If "port" is not the first argument, prepend it
    cmd = [sys.executable, "-m", "porter", "port"] + args

    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"

    proc = subprocess.Popen(
        cmd,
        cwd=str(nx2android_dir),
        env=env,
        stdout=sys.stdout,
        stderr=sys.stderr
    )

    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait()
        sys.exit(130)

    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
