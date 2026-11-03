#!/usr/bin/env python3
"""PreToolUse hook (Claude Code twin of opencode/plugins/guard-secrets.js).

Hard-blocks plaintext-secret leaks before an Edit/Write/MultiEdit runs:
  1. never create decrypted secret artifacts (*.decrypted*, *decrypted~*)
  2. a *.sops.yaml / *.sops.yml write must contain SOPS ciphertext (ENC[)
  3. best-effort plaintext-secret scan via gitleaks, on PATH or through mise (warns and continues when absent),
     honouring the repository's own .gitleaks.toml so its allowlist (test fixtures, published test vectors) applies

Blocking = exit 2 with a reason on stderr (Claude Code's deny contract, the
analogue of the opencode plugin's throw). Any other error path exits 0
(fail-open — a same-machine convenience guard, not a security boundary; MR
review is that). Content is taken from whichever field the tool provides
(Write: content; Edit: new_string; MultiEdit: each edit's new_string).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

DECRYPTED = ("decrypted",)


def gitleaks_path():
    found = shutil.which("gitleaks")
    if found or not shutil.which("mise"):
        return found
    try:
        resolved = subprocess.run(["mise", "which", "gitleaks"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError:
        return None
    if resolved.returncode != 0:
        return None
    return resolved.stdout.strip() or None


def repo_config(path: str):
    """The repository root above `path` and its .gitleaks.toml, if any."""
    directory = os.path.dirname(os.path.abspath(path))
    while True:
        config = os.path.join(directory, ".gitleaks.toml")
        if os.path.isfile(config):
            return directory, config
        if os.path.exists(os.path.join(directory, ".git")):
            return directory, None
        parent = os.path.dirname(directory)
        if parent == directory:
            return None, None
        directory = parent


def scan_target(path: str, root):
    """Where the content is written for scanning: its path inside the repository, so path allowlists match."""
    if root:
        relative = os.path.relpath(os.path.abspath(path), root)
        if not relative.startswith(".."):
            return relative
    return os.path.basename(path) or "content.txt"


def deny(msg: str) -> None:
    print(f"BLOCKED: {msg}", file=sys.stderr)
    sys.exit(2)


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except Exception:
        return  # fail-open on malformed input
    ti = event.get("tool_input") or {}
    path = ti.get("file_path") or ti.get("path") or ""
    if not path:
        return
    base = os.path.basename(path)

    # gather content across Write / Edit / MultiEdit shapes
    parts = []
    if ti.get("content"):
        parts.append(ti["content"])
    if ti.get("new_string"):
        parts.append(ti["new_string"])
    for edit in ti.get("edits") or []:
        if edit.get("new_string"):
            parts.append(edit["new_string"])
    content = "\n".join(parts)

    # 1) never create decrypted secret artifacts
    if "decrypted" in base:
        deny(f"refusing to write a decrypted secret artifact ({base}). Secrets live only in *.sops.yaml.")

    # 2) a SOPS file must contain ciphertext, never plaintext
    if base.endswith((".sops.yaml", ".sops.yml")) and content and "ENC[" not in content:
        deny(f"{base} is a SOPS file but the content isn't encrypted. Edit plaintext elsewhere, then 'sops --encrypt'.")

    # 3) best-effort gitleaks scan (warn, never block, when absent)
    gitleaks = gitleaks_path() if content else None
    if content and not gitleaks:
        print("guard-secrets: gitleaks not on PATH or in mise; plaintext scan skipped. Pin it in .mise.toml.", file=sys.stderr)
    if gitleaks:
        root, config = repo_config(path)
        scratch = tempfile.mkdtemp(prefix="guard-secrets-")
        try:
            target = os.path.join(scratch, scan_target(path, root))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w") as fh:
                fh.write(content)
            command = [gitleaks, "detect", "--no-banner", "--no-git", "--redact", "-s", scratch]
            if config:
                command += ["--config", config]
            scan = subprocess.run(command, capture_output=True)
            if scan.returncode == 1:
                deny(f"gitleaks flagged a likely plaintext secret in {base}. Use a SOPS secret + Helm value wiring (existingSecret/envFromSecret).")
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

if __name__ == "__main__":
    main()
