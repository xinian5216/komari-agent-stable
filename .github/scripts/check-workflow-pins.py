#!/usr/bin/env python3
"""Fail when a workflow executes an unpinned third-party GitHub Action."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)(?:\s+#\s*(\S.*))?$")
PIN_RE = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^v\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?$")
PIPE_INSTALL_RE = re.compile(
    r"curl[^\n]*(?:\\\s*)?(?:\n\s*)?\|(?:\s*\n\s*)?(?:bash|sh|tar)\b"
)
FORBIDDEN_WORKFLOWS = {
    "build.yml",
    "build.yaml",
    "development.yaml",
    "i18n-sync.yml",
    "preview-theme.yaml",
}


def yaml_files() -> list[pathlib.Path]:
    files = list((ROOT / ".github" / "workflows").glob("*.yml"))
    files += list((ROOT / ".github" / "workflows").glob("*.yaml"))
    files += list((ROOT / ".github" / "actions").glob("**/action.yml"))
    files += list((ROOT / ".github" / "actions").glob("**/action.yaml"))
    return sorted(files)


def main() -> int:
    failures: list[str] = []
    for path in yaml_files():
        text = path.read_text(encoding="utf-8")
        if path.parent.name == "workflows" and path.name in FORBIDDEN_WORKFLOWS:
            failures.append(f"{path.relative_to(ROOT)}: forbidden legacy workflow")
        if PIPE_INSTALL_RE.search(text):
            failures.append(
                f"{path.relative_to(ROOT)}: pipe-to-shell/archive download is forbidden; download and verify a checksum first"
            )
        for number, line in enumerate(text.splitlines(), 1):
            match = USES_RE.match(line)
            if not match:
                continue
            target, comment = match.groups()
            if target.startswith("./") or target.startswith("docker://"):
                continue
            if not PIN_RE.fullmatch(target):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: external action is not pinned to a full commit SHA: {target}"
                )
                continue
            if not comment or not VERSION_RE.fullmatch(comment.strip()):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: pinned action must include an exact version comment"
                )

    if failures:
        print("workflow pin policy failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("OK: every third-party Action is pinned to a full commit SHA with a version comment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
