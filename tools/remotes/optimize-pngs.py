#!/usr/bin/env python3
"""Try two strict lossless PNG optimizers; verify before replacing with the smallest.
Requires oxipng, zopflipng, and a compiled verify-images.swift (see README).
No alpha cleanup, quantization, resizing or lossy depth reduction is allowed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--verifier", required=True, type=Path)
parser.add_argument("--jobs", type=int, default=4)
parser.add_argument("paths", nargs="+", type=Path)
args = parser.parse_args()
verifier = str(args.verifier.resolve())
files = sorted({p for root in args.paths for p in
                (root.rglob("*.png") if root.is_dir() else [root])})


def optimize(path):
    with tempfile.TemporaryDirectory(prefix="lossless-png-") as tmp:
        oxi, zopfli = Path(tmp) / "oxi.png", Path(tmp) / "zopfli.png"
        subprocess.run(["oxipng", "-o", "max", "-z", "--fast", "-t", "2",
                        "--keep", "eXIf,gAMA,cHRM,display", "--out", str(oxi), str(path)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(["zopflipng", "-y", "--iterations=15",
                        "--keepchunks=sRGB,iCCP,gAMA,cHRM,eXIf,pHYs",
                        str(path), str(zopfli)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        candidates = sorted((p for p in [path, oxi, zopfli] if p.exists()),
                            key=lambda p: p.stat().st_size)
        best = path
        for candidate in candidates:
            if candidate == path:
                break
            result = subprocess.run([verifier, "--pair", str(path), str(candidate)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode == 0:
                best = candidate
                break
            print(f"Rejected {candidate.name} for {path}: {result.stderr.decode().strip()}", flush=True)
        before, after = path.stat().st_size, best.stat().st_size
        if best != path:
            # Publish a fully verified file atomically, even if optimization is interrupted.
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".optimized-",
                                             suffix=".png", delete=False) as staged:
                staged_path = Path(staged.name)
                staged.write(best.read_bytes())
            try:
                shutil.copymode(path, staged_path)
                staged_path.replace(path)
            finally:
                staged_path.unlink(missing_ok=True)
        print(f"{path}: {before} -> {after} ({best.name})", flush=True)
        return before, after


with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    sizes = list(pool.map(optimize, files))
print(f"{len(sizes)} PNGs: {sum(a for a, _ in sizes)} -> {sum(b for _, b in sizes)} bytes")
