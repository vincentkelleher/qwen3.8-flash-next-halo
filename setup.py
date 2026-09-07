#!/usr/bin/env python3
"""One-shot setup for the Qwen 3.8 Flash-Next Strix Halo stack.

Runs the "Setting up" section of README.md, with progress bars:

  1. precheck  tools, docker, /dev/kfd, kernel args, free disk
  2. clone     EngramHalo.cpp — the build context for the images
  3. key       create ./.api-key (0600)
  4. weights   IQ4_XS model, MTP draft head, mmproj  (~100 GB)
  5. verify    every file against the sizes Hugging Face reports

  ./setup.py                      # everything; asks before the big download
  ./setup.py --yes                # unattended
  ./setup.py --check              # status only, change nothing
  ./setup.py --steps key,weights  # subset (precheck and verify always run)
  ./setup.py --quant UD-Q3_K_XL   # different quantisation
  ./setup.py --checksum           # sha256 the weights too (~100 GB of reads)

Files land in <models-dir>/<repo>/<path>, the layout docker-compose.yaml mounts
read-only at /models. Files already present at the expected size are skipped, so
an interrupted run resumes where it stopped.

Stdlib only; needs `git` and the `hf` CLI on PATH.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

GIT_URL = "https://github.com/Aristo94/EngramHalo.cpp.git"
GIT_BRANCH = "strix-halo-qwen4exp"
REPO_MAIN = "unsloth/Qwen3.8-Flash-Next-GGUF"
REPO_MTP = "EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF"
MTP_FILE = "mtp-Qwen3.8-Flash-Next-Q8_0.gguf"
MMPROJ_FILE = "mmproj-BF16.gguf"
KERNEL_ARGS = ("amd_iommu=off", "amdgpu.gttsize=", "ttm.pages_limit=")
STEP_NAMES = ("clone", "key", "weights")

TTY = sys.stdout.isatty()
if TTY:
    BOLD, DIM = "\033[1m", "\033[2m"
    C_OK, C_WARN, C_FAIL = "\033[32m", "\033[33m", "\033[31m"
else:
    BOLD = DIM = ""
    C_OK = C_WARN = C_FAIL = ""


def human(n):
    """1234567890 -> '51.2 GiB'."""
    if n is None:
        return "?"
    val = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(val) < 1024 or unit == "TiB":
            return f"{val:.0f} {unit}" if unit == "B" else f"{val:.1f} {unit}"
        val /= 1024.0
    return f"{val:.1f} TiB"


class Bar:
    """One-line progress bar. Prints periodic percentages when not a terminal."""

    def __init__(self, label, total, width=30):
        self.label = str(label)[:30]
        self.total = max(int(total or 0), 1)
        self.done = 0
        self.width = width
        self.started = time.monotonic()
        self.last_draw = 0.0
        self.next_line = 0.2

    def set(self, done):
        self.done = done
        self._render()

    def advance(self, n=1):
        self.done += n
        self._render()

    def finish(self):
        self._render(final=True)
        if TTY:
            print()

    def _render(self, final=False):
        frac = min(self.done / self.total, 1.0)
        now = time.monotonic()
        if not TTY:
            if frac >= self.next_line or final:
                while self.next_line <= frac:
                    self.next_line += 0.2
                print(f"  {self.label}: {min(frac, 1.0) * 100:5.1f}%")
                sys.stdout.flush()
            return
        if not final and now - self.last_draw < 0.12:
            return
        self.last_draw = now
        filled = self.width if frac >= 1 else int(self.width * frac)
        bar = "#" * filled + "-" * (self.width - filled)
        elapsed = now - self.started
        tail = f"{human(self.done)}/{human(self.total)}"
        if frac >= 1:
            tail += f"  in {elapsed:.0f}s"
        else:
            rate = self.done / max(elapsed, 1e-6)
            if rate > 0:
                left = (self.total - self.done) / rate
                tail += f"  eta {int(left) // 60}:{int(left) % 60:02d}"
        sys.stdout.write(
            f"\r  {self.label:<30} [{bar}] {frac * 100:5.1f}%  {tail}   "
        )
        sys.stdout.flush()


class Log:
    """Step headers and status lines."""

    def __init__(self, count):
        self.count = count
        self.index = 0

    def __call__(self, title):
        self.index += 1
        print(f"\n{BOLD}[{self.index}/{self.count}] {title}{RESET}")

    def ok(self, msg):
        print(f"  {C_OK}ok{RESET}    {msg}")

    def warn(self, msg):
        print(f"  {C_WARN}warn{RESET}  {msg}")

    def fail(self, msg):
        print(f"  {C_FAIL}fail{RESET}  {msg}")

    def info(self, msg):
        print(f"  {msg}")


def capture(cmd):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True)


def run(cmd):
    """Run a command with its own output visible (git/hf draw their own bars)."""
    print(f"  {DIM}$ {' '.join(str(c) for c in cmd)}{RESET}")
    return subprocess.run([str(c) for c in cmd]).returncode


# --------------------------------------------------------------------- HF API


def hf_api(path):
    req = urllib.request.Request(f"https://huggingface.co/api/{path}")
    token = os.environ.get("HF_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def remote_meta(repo, name):
    """(size, sha256) for a repo file. sha256 only if the ETag is one."""
    url = f"https://huggingface.co/{repo}/resolve/main/{name}"
    try:
        req = urllib.request.Request(
            f"https://huggingface.co/{repo}/resolve/main/{name}", method="HEAD"
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            size = resp.headers.get("Content-Length")
            etag = (resp.headers.get("ETag") or "").strip('"')
    except (urllib.error.URLError, ValueError, TimeoutError, OSError):
        return None, None
    sha = etag if re.fullmatch(r"[0-9a-f]{64}", etag or "") else None
    return (int(size) if size else None), sha


def build_manifest(models_dir, quant):
    """Files this setup needs: [{repo, name, path, size, sha256}]. Raises on API failure."""
    siblings = [s["rfilename"] for s in hf_api(f"models/{REPO_MAIN}")["siblings"]]
    main_files = sorted(
        n for n in siblings if n.startswith(f"{quant}/") and n.endswith(".gguf")
    )
    if not main_files:
        quants = sorted({n.split("/")[0] for n in siblings if "/" in n})
        raise SystemExit(
            f"no {quant!r} files in {REPO_MAIN} — try one of: {', '.join(quants)}"
        )
    wanted = [
        (REPO_MAIN, main_files),
        (REPO_MTP, [MTP_FILE]),
        (REPO_MAIN, [MMPROJ_FILE]),
    ]
    total_files = sum(len(names) for _, names in wanted for n in [names])
    bar = Bar("resolving sizes", max(len(main_files) + 2, 1))
    manifest, i = [], 0
    for repo, names in wanted:
        for name in names:
            size, sha = remote_meta(repo, name)
            manifest.append(
                {
                    "repo": repo,
                    "name": name,
                    "path": Path(models_dir) / repo / name,
                    "size": size if False else size,
                    "sha256": sha,
                }
            )
            i += 1
            bar.set(i)
    bar.finish()
    return manifest


# ---------------------------------------------------------------- local state


def sha256_file(path, size):
    digest = hashlib.sha256()
    bar = Bar(f"sha256 {Path(path).name}", size)
    with open(path, "rb") as fh:
        while True:
            block = fh.read(1 << 24)
            if not block:
                break
            digest.update(block)
            bar.advance(len(block))
    bar.finish()
    return digest.hexdigest()


def scan(files, checksum=False):
    """Split the manifest into complete / incomplete by size (optionally sha256)."""
    complete, incomplete = [], []
    total = sum(f["size"] or 0 for f in files)
    bar = Bar("scanning local files", max(len(files), 1))
    for i, f in enumerate(manifest, 1):
        path = Path(f["path"])
        why = "missing"
        if path.is_file():
            actual = path.stat().st_size
            f["local"] = path
            if f["size"] is not None and actual != f["size"]:
                why = f"{human(actual)} of {human(f['size'])} on disk"
            elif checksum and f["sha256"]:
                if sha256_file(path, actual) != f["sha256"]:
                    why = "sha256 mismatch"
            else:
                why = None
        if why:
            f["why"] = why
            incomplete.append(f)
        else:
            complete.append(f)
        bar.set(i)
    bar.finish()
    return complete, incomplete


def disk_free(path):
    probe = Path(path)
    while not probe.exists() and probe.parent != probe:
        probe = probe.parent
    return shutil.disk_usage(str(probe)).free


# ----------------------------------------------------------------- the steps


def step_precheck(log, plan):
    log("precheck — tools, GPU, disk")
    fatal = []
    for tool in ("git", args.hf_bin):
        where = shutil.which(tool)
        if where:
            log.ok(f"{tool} {DIM}{where}{RESET}")
        else:
            fatal.append(f"{tool} not on PATH")
    if shutil.which("docker"):
        probe = capture(["docker", "info", "-f", "{{.ServerVersion}}"])
        if proc.returncode:
            log.warn("docker is installed but the daemon is not answering")
        else:
            log.ok(f"docker daemon {proc.stdout.strip()}")
    else:
        log.warn("docker not found — the compose step will not work on this host")
    if platform.machine() != "x86_64":
        log.warn(f"arch is {platform.machine()}; this stack targets x86_64 Strix Halo")
    if Path("/dev/kfd").is_char_device():
        log.ok("/dev/kfd present")
    else:
        log.warn("/dev/kfd missing — ROCm profiles cannot run here")
    cmdline = Path("/proc/cmdline").read_text() if Path("/proc/cmdline").exists() else ""
    absent = [a for a in KERNEL_ARGS if a not in cmdline]
    if absent:
        log.warn(f"kernel args not set: {' '.join(absent)} — see README /etc/default/grub")
    else:
        log.ok("kernel GTT args set")
    free = disk_free(args.models_dir)
    need = plan["total"]
    if free < need:
        fatal.append(f"{human(free)} free at {args.models_dir}, {human(need)} needed")
    else:
        log.ok(f"{human(free)} free at {args.models_dir} ({human(need)} needed)")
    for msg in fatal:
        log.fail(msg)
    if fatal:
        raise SystemExit(2)


def step_clone(log):
    log(f"clone EngramHalo.cpp ({GIT_BRANCH}) -> {args.clone_dir}")
    dest = Path(args.clone_dir)
    if dest.exists():
        if (dest / ".git").exists():
            branch = capture(
                ["git", "-C", str(dest), "rev-parse", "--abbrev-ref", "HEAD"]
            ).stdout.strip()
            if branch == GIT_BRANCH:
                log.ok(f"already checked out on {branch}")
            else:
                log.warn(f"{dest} is on {branch!r}, expected {GIT_BRANCH!r}")
            return
        log.fail(f"{dest} exists but is not a git checkout")
        raise SystemExit(1)
    if args.check or args.dry_run:
        log.info(f"would clone {GIT_URL} -> {dest}")
        return
    cmd = ["git", "clone", "--branch", GIT_BRANCH, "--single-branch"]
    if not args.full_clone:
        cmd += ["--depth", "1"]
    if run(cmd + ["--progress", GIT_URL, str(dest)]):
        log.fail("git clone failed")
        raise SystemExit(1)
    log.ok(f"{dest} ready")


def step_key(log):
    log(f"API key -> {args.key_file}")
    path = Path(args.key_file)
    if path.is_file():
        if path.read_text().strip():
            log.ok(f"{path} exists ({human(path.stat().st_size)})")
            if path.stat().st_mode & 0o077:
                os.chmod(path, 0o600)
                log.ok("permissions tightened to 0600")
            return
        log.fail(f"{path} exists but is empty")
        raise SystemExit(1)
    if args.check or args.dry_run:
        log.info(f"would write {path} (0600)")
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(secrets.token_urlsafe(48) + "\n")
    log.ok(f"{path} written (0600)")


def step_weights(log, plan):
    log(f"weights -> {args.models_dir}")
    todo = plan["todo"]
    if not todo:
        log.ok("all files present at the expected size — nothing to download")
        return
    total = sum(e["size"] or 0 for e in todo)
    log.info(f"{len(todo)} file(s) to fetch ({human(total)})")
    if args.check or args.dry_run:
        for e in todo:
            print(f"    {e['name']}  {human(e['size'])}")
        return
    if not args.yes:
        answer = input(f"  Download {human(total)} into {args.models_dir}? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            raise SystemExit("aborted")
    by_repo = {}
    for entry in todo:
        by_repo.setdefault(entry["repo"], []).append(entry)
    for repo, entries in by_repo.items():
        log.info(repo)
        cmd = [
            args.hf_bin,
            "download",
            repo,
            *[e["name"] for e in entries],
            "--local-dir",
            str(Path(args.models_dir) / repo),
        ]
        print(f"  {DIM}$ {' '.join(cmd)}{RESET}")
        if subprocess.run(cmd).returncode:
            log.warn("hf download failed — re-run this script to resume")
            raise SystemExit(1)
    log.ok("downloads finished")


def step_verify(log, plan):
    log("verify against Hugging Face")
    files = plan["files"]
    bar = Bar("verify", max(len(files), 1))
    problems = []
    for i, f in enumerate(files, 1):
        path = Path(f["path"])
        if not path.is_file():
            problems.append((f, "missing"))
        elif f["size"] is not None and path.stat().st_size != f["size"]:
            problems.append((f, f"{human(path.stat().st_size)} of {human(f['size'])}"))
        elif args.checksum and f["sha256"]:
            if sha256_file(path, f["size"]) != f["sha256"]:
                problems.append((f, "sha256 mismatch"))
        bar.set(i)
    bar.finish()
    if problems:
        for f, why in problems:
            log.fail(f"{f['name']}: {why}")
        log.warn("re-run this script to resume the download")
        raise SystemExit(1)
    log.ok(f"{len(files)} files, {human(sum(f['size'] or 0 for f in files))} in place")
    if not args.checksum:
        print(f"  {DIM}sizes checked only — --checksum also compares sha256{RESET}")


# --------------------------------------------------------------------- main


def parse_args():
    root = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(
        description="Set up the Qwen 3.8 Flash-Next Strix Halo stack.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--models-dir", type=Path, default=Path.home() / "Models",
                   help="GGUF root; docker-compose mounts it read-only at /models")
    p.add_argument("--clone-dir", type=Path, default=root / "EngramHalo.cpp",
                   help="EngramHalo.cpp checkout (the compose build context)")
    p.add_argument("--key-file", type=Path, default=root / ".api-key")
    p.add_argument("--quant", default="UD-IQ4_XS", help="quantisation folder in the main repo")
    p.add_argument("--hf-bin", default="hf", help="Hugging Face CLI")
    p.add_argument("--steps", default=",".join(STEP_NAMES),
                   help="comma list of clone,key,weights (precheck and verify always run)")
    p.add_argument("--check", action="store_true", help="report status, change nothing")
    p.add_argument("--dry-run", action="store_true", help="print commands, do not run them")
    p.add_argument("--yes", "-y", action="store_true", help="skip the download confirmation")
    p.add_argument("--checksum", action="store_true", help="verify sha256, not just sizes")
    p.add_argument("--force", action="store_true", help="re-download files that look complete")
    p.add_argument("--full-clone", action="store_true", help="clone the full git history")
    return p.parse_args()


def main():
    global args
    args = parse_args()
    wanted = [s.strip() for s in args.steps.split(",") if s.strip()]
    invalid = [s for s in wanted if s not in STEP_NAMES]
    if invalid:
        raise SystemExit(
            f"unknown step(s): {', '.join(invalid)} — pick from {', '.join(STEP_NAMES)}"
        )

    names = (["precheck"] if wanted else []) + wanted + ["verify"]
    log = Log(len(names))
    print(f"{BOLD}Qwen 3.8 Flash-Next setup{RESET}")
    print(f"  {DIM}repo   {Path(__file__).resolve().parent}{RESET}")
    print(f"  {DIM}models {args.models_dir}{RESET}")

    try:
        files = build_manifest(args.models_dir, args.quant)
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(f"cannot reach huggingface.co ({exc}) — setup needs it for sizes")

    total_all = sum(f["size"] or 0 for f in files)
    print(f"  {DIM}{len(files)} files expected, {human(total_all)}{RESET}")

    if args.force:
        complete, incomplete = [], files
    else:
        complete, incomplete = scan(files, args.checksum)
    todo = incomplete
    plan = {"files": files, "todo": todo, "total": sum(e["size"] or 0 for e in todo)}
    if args.force:
        plan["todo"] = list(files)
        plan["total"] = total_all

    print(f"  {DIM}{human(sum(f['size'] or 0 for f in plan['files']))} complete, "
          f"{human(sum(e['size'] or 0 for e in plan['todo']))} to fetch{RESET}")

    for step in wanted:
        handlers[step]()

    step_verify(log, plan)
    if args.check or args.dry_run:
        print(f"\n{BOLD}Nothing changed ({'--check' if args.check else '--dry-run'}).{RESET}")
        return
    print(f"\n{BOLD}{C_OK}Setup complete.{RESET} Start the server with:")
    print("  docker compose --profile long up -d")
    print("  docker logs -f qwen38-flash-next-qwen-long-1")


if __name__ == "__main__":
    main()
