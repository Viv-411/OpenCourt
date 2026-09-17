"""Enforces docs/PLAN.md §3: runtime code never writes frames or video to disk, and never
uses face or appearance features."""

import io
import re
import tokenize
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "opencourt"

FORBIDDEN = [
    r"imwrite", r"VideoWriter", r"imencode", r"np\.save\b", r"capture_file", r"start_recording",
    r"\bface", r"reid", r"embedding", r"botsort", r"\.save\(",
]


def code_only(source: str) -> list[tuple[int, str]]:
    """Source tokens with comments and string literals removed, grouped by line."""
    lines: dict[int, list[str]] = {}
    for tok in tokenize.generate_tokens(io.StringIO(source).readline):
        if tok.type in (tokenize.COMMENT, tokenize.STRING):
            continue
        lines.setdefault(tok.start[0], []).append(tok.string)
    return [(n, " ".join(parts)) for n, parts in sorted(lines.items())]


def test_no_frame_writing_or_identity_features():
    offenders = []
    for path in SRC.rglob("*.py"):
        for n, code in code_only(path.read_text()):
            for pat in FORBIDDEN:
                if re.search(pat, code, re.IGNORECASE):
                    offenders.append(f"{path.name}:{n}: {code}")
    assert not offenders, "\n".join(offenders)


def test_tracker_config_is_motion_only():
    cfg = (SRC.parents[1] / "trackers" / "bytetrack_opencourt.yaml").read_text()
    assert re.search(r"^tracker_type:\s*bytetrack\s*$", cfg, re.M)
    assert not re.search(r"with_reid:\s*true", cfg, re.I)
