#!/usr/bin/env python3
"""Keep PNG when the same basename also exists as JPG/JPEG.

Never removes a JPG/JPEG unless a non-empty .png twin exists.
Default mode is dry-run. Use --apply to quarantine (or --delete to unlink).

Examples:
  python dedupe_question_images.py --dir /path/to/images --dry-run
  python dedupe_question_images.py --dir /path/to/images --apply
  python dedupe_question_images.py --dir /path/to/images --apply --delete
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


KEEP = {".png"}
REMOVE = {".jpg", ".jpeg"}


def scan(root: Path) -> tuple[list[dict], list[dict]]:
    by_stem: dict[str, dict[str, Path]] = defaultdict(dict)
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        # Skip previous quarantine folders so we don't re-process moved files.
        parts_lower = {p.lower() for p in path.parts}
        if any(p.startswith(".dedupe_quarantine_") for p in parts_lower):
            continue
        ext = path.suffix.lower()
        if ext not in KEEP and ext not in REMOVE:
            continue
        stem = path.stem.lower()
        prev = by_stem[stem].get(ext)
        if prev is None or path.stat().st_size >= prev.stat().st_size:
            by_stem[stem][ext] = path

    actions: list[dict] = []
    skipped: list[dict] = []
    for stem, files in sorted(by_stem.items()):
        png = files.get(".png")
        jpgs = [files[e] for e in (".jpg", ".jpeg") if e in files]
        if not png or not jpgs:
            continue
        png_size = png.stat().st_size
        if png_size <= 0:
            skipped.append(
                {
                    "stem": stem,
                    "reason": "png_empty",
                    "png": str(png.relative_to(root)),
                    "jpg": [str(j.relative_to(root)) for j in jpgs],
                }
            )
            continue
        for jpg in jpgs:
            actions.append(
                {
                    "stem": stem,
                    "keep": str(png.relative_to(root)),
                    "keepBytes": png_size,
                    "remove": str(jpg.relative_to(root)),
                    "removeBytes": jpg.stat().st_size,
                }
            )
    return actions, skipped


def apply_actions(
    root: Path, actions: list[dict], hard_delete: bool
) -> tuple[list[dict], list[dict], Path | None]:
    quarantine = root / f".dedupe_quarantine_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"
    removed: list[dict] = []
    errors: list[dict] = []
    if not actions:
        return removed, errors, None
    if not hard_delete:
        quarantine.mkdir(parents=True, exist_ok=True)

    for item in actions:
        src = root / item["remove"]
        try:
            if hard_delete:
                src.unlink(missing_ok=True)
                item = {**item, "action": "deleted"}
            else:
                dest = quarantine / item["remove"]
                dest.parent.mkdir(parents=True, exist_ok=True)
                if dest.exists():
                    dest = dest.with_name(f"{dest.name}.{os.getpid()}")
                shutil.move(str(src), str(dest))
                item = {
                    **item,
                    "action": "quarantined",
                    "quarantine": str(dest.relative_to(root)),
                }
            removed.append(item)
        except Exception as exc:  # noqa: BLE001 - collect and continue
            errors.append({"file": item["remove"], "error": str(exc)})
    return removed, errors, None if hard_delete else quarantine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True, help="Image root directory")
    parser.add_argument("--dry-run", action="store_true", default=False)
    parser.add_argument("--apply", action="store_true", default=False)
    parser.add_argument(
        "--delete",
        action="store_true",
        default=False,
        help="With --apply, permanently delete instead of quarantine",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Optional JSON report path (default: <dir>/../Image_Dedupe_Reports or cwd)",
    )
    parser.add_argument("--label", default="images")
    args = parser.parse_args()

    if args.apply == args.dry_run:
        # Exactly one mode; default dry-run when neither/both.
        if not args.apply:
            args.dry_run = True
        else:
            print("ERROR: pass exactly one of --dry-run or --apply", file=sys.stderr)
            return 2

    root = Path(args.dir).resolve()
    if not root.is_dir():
        print(f"ERROR: directory not found: {root}", file=sys.stderr)
        return 1

    mode = "apply" if args.apply else "dry-run"
    actions, skipped = scan(root)
    removed: list[dict] = []
    errors: list[dict] = []
    quarantine: Path | None = None
    if mode == "apply":
        removed, errors, quarantine = apply_actions(root, actions, args.delete)

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    if args.report:
        report_path = Path(args.report)
    else:
        report_dir = root.parent / "Image_Dedupe_Reports"
        if not report_dir.parent.exists():
            report_dir = Path.cwd() / "Image_Dedupe_Reports"
        report_dir.mkdir(parents=True, exist_ok=True)
        report_path = report_dir / f"dedupe_{args.label}_{mode}_{stamp}.json"

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "label": args.label,
        "mode": mode,
        "hardDelete": bool(args.delete),
        "wouldRemove": len(actions),
        "removed": len(removed),
        "skipped": skipped,
        "errors": errors,
        "quarantineDir": str(quarantine) if quarantine else None,
        "samples": (removed or actions)[:50],
        "allActions": removed if mode == "apply" else actions,
    }
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"root={root}")
    print(f"mode={mode}")
    print(f"pairs={len(actions)} removed={len(removed)} skipped={len(skipped)} errors={len(errors)}")
    print(f"report={report_path}")
    if quarantine:
        print(f"quarantine={quarantine}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
