#!/usr/bin/env python3
# 1.清洗重复的"key" = "value" 2.将不规范的"key" 改成规范的 "key" = "value"
# 3.排查重复的key 输出报告
# python3 scripts/clean_localizable_strings.py --write 
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ENTRY_RE = re.compile(
    r'^(?P<indent>\s*)"(?P<key>(?:\\.|[^"\\])*)"\s*=\s*"(?P<value>(?:\\.|[^"\\])*)"\s*;\s*$'
)
STANDALONE_RE = re.compile(
    r'^(?P<indent>\s*)"(?P<text>(?:\\.|[^"\\])*)"\s*;\s*$'
)


@dataclass
class FileReport:
    path: Path
    normalized_entries: int = 0
    removed_duplicate_pairs: int = 0
    conflicting_keys: int = 0
    conflict_key_names: list[str] | None = None
    unchanged_lines: int = 0
    wrote_changes: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize Localizable.strings files by converting bare strings to "
            '"key" = "value"; form and removing duplicate key/value pairs.'
        )
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help=(
            "Files or directories to process. Defaults to "
            "Renogy/Localizables/**/*.lproj/Localizable.strings."
        ),
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Write changes back to disk. Without this flag, the script runs in dry-run mode.",
    )
    return parser.parse_args()


def collect_files(paths: list[Path]) -> list[Path]:
    if not paths:
        return sorted(Path("Renogy/Localizables").glob("*.lproj/Localizable.strings"))

    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted(path.rglob("Localizable.strings")))
        elif path.name.endswith(".strings"):
            files.append(path)
    return sorted({path.resolve() for path in files})


def format_entry(indent: str, key: str, value: str) -> str:
    return f'{indent}"{key}" = "{value}";'


def normalize_file(path: Path, write: bool) -> FileReport:
    report = FileReport(path=path)
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines()
    new_lines: list[str] = []
    seen_pairs: set[tuple[str, str]] = set()
    first_value_by_key: dict[str, str] = {}
    conflict_keys: set[str] = set()

    for line in lines:
        entry_match = ENTRY_RE.match(line)
        if entry_match:
            indent = entry_match.group("indent")
            key = entry_match.group("key")
            value = entry_match.group("value")
            normalized_line = format_entry(indent, key, value)
            pair = (key, value)

            if pair in seen_pairs:
                report.removed_duplicate_pairs += 1
                continue

            seen_pairs.add(pair)
            previous_value = first_value_by_key.setdefault(key, value)
            if previous_value != value:
                conflict_keys.add(key)

            new_lines.append(normalized_line)
            continue

        standalone_match = STANDALONE_RE.match(line)
        if standalone_match:
            indent = standalone_match.group("indent")
            text = standalone_match.group("text")
            normalized_line = format_entry(indent, text, text)
            pair = (text, text)

            report.normalized_entries += 1
            if pair in seen_pairs:
                report.removed_duplicate_pairs += 1
                continue

            seen_pairs.add(pair)
            previous_value = first_value_by_key.setdefault(text, text)
            if previous_value != text:
                conflict_keys.add(text)

            new_lines.append(normalized_line)
            continue

        report.unchanged_lines += 1
        new_lines.append(line)

    report.conflict_key_names = sorted(conflict_keys)
    report.conflicting_keys = len(conflict_keys)
    normalized = "\n".join(new_lines) + ("\n" if original.endswith("\n") or new_lines else "")
    if write and normalized != original:
        path.write_text(normalized, encoding="utf-8")
        report.wrote_changes = True
    return report


def print_report(report: FileReport) -> None:
    status = "updated" if report.wrote_changes else "checked"
    line = (
        f"[{status}] {report.path}: "
        f"normalized={report.normalized_entries}, "
        f"deduped={report.removed_duplicate_pairs}, "
        f"conflicts={report.conflicting_keys}"
    )
    if report.conflict_key_names:
        line += f" ({', '.join(report.conflict_key_names)})"
    print(line)


def main() -> int:
    args = parse_args()
    files = collect_files(args.paths)
    if not files:
        print("No .strings files matched.", file=sys.stderr)
        return 1

    reports = [normalize_file(path, write=args.write) for path in files]
    for report in reports:
        print_report(report)

    total_conflicts = sum(report.conflicting_keys for report in reports)
    total_updates = sum(1 for report in reports if report.wrote_changes)
    print(
        f"Summary: files={len(reports)}, updated={total_updates}, "
        f"normalized={sum(r.normalized_entries for r in reports)}, "
        f"deduped={sum(r.removed_duplicate_pairs for r in reports)}, "
        f"conflicts={total_conflicts}"
    )

    if total_conflicts:
        print(
            "Conflicting keys were kept as-is. Resolve them manually if you want one key to map to one value only.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
