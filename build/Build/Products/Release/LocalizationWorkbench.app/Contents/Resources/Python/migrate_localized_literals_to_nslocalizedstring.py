#!/usr/bin/env python3
"""
Rewrite literal `.localized` usages to `NSLocalizedString(...)`.

Supported patterns:
  - Swift: "some_key".localized
  - Objective-C: @"some_key".localized

Comment values are read from:
  Renogy/Localizables/zh-Hans.lproj/Localizable.strings

Examples:
  python3 scripts/migrate_localized_literals_to_nslocalizedstring.py
  python3 scripts/migrate_localized_literals_to_nslocalizedstring.py --apply
  python3 scripts/migrate_localized_literals_to_nslocalizedstring.py Renogy/_common
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_SOURCE_ROOT = Path("Renogy")
DEFAULT_COMMENTS_FILE = Path("Renogy/Localizables/zh-Hans.lproj/Localizable.strings")
DEFAULT_SECONDARY_COMMENTS_FILE = Path("Renogy/Localizables/en.lproj/Localizable.strings")
SOURCE_EXTS = {".swift", ".m", ".mm", ".h"}

STRINGS_KV_RE = re.compile(
    r'^\s*"(?P<key>(?:\\.|[^"\\])*)"\s*=\s*"(?P<value>(?:\\.|[^"\\])*)"\s*;\s*$'
)
LITERAL_LOCALIZED_RE = re.compile(
    r'(?P<prefix>@?)"(?P<key>(?:\\.|[^"\\])*)"\.localized\b'
)
SWIFT_NSLOCALIZED_RE = re.compile(
    r'NSLocalizedString\("(?P<key>(?:\\.|[^"\\])*)",\s*comment:\s*"(?P<comment>(?:\\.|[^"\\])*)"\)',
    re.DOTALL,
)
OBJC_NSLOCALIZED_RE = re.compile(
    r'NSLocalizedString\(@"(?P<key>(?:\\.|[^"\\])*)",\s*@"(?P<comment>(?:\\.|[^"\\])*)"\)',
    re.DOTALL,
)


@dataclass
class FileChange:
    path: Path
    replacements: int = 0
    missing_comment_keys: list[str] = field(default_factory=list)
    english_fallback_keys: list[str] = field(default_factory=list)
    changed: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rewrite literal .localized usages to NSLocalizedString."
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Base directory used to resolve relative paths. Default: current working directory.",
    )
    parser.add_argument(
        "--source-root",
        type=Path,
        default=DEFAULT_SOURCE_ROOT,
        help=(
            "Directory scanned when no explicit paths are provided. Relative paths are resolved "
            "against --project-root. Default: Renogy."
        ),
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help=(
            "Files or directories to process. Defaults to scanning Renogy/ for "
            ".swift/.m/.mm/.h files."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write changes back to disk. Without this flag, the script runs in dry-run mode.",
    )
    parser.add_argument(
        "--comments-file",
        type=Path,
        default=DEFAULT_COMMENTS_FILE,
        help="Path to the .strings file used for NSLocalizedString comments.",
    )
    parser.add_argument(
        "--secondary-comments-file",
        type=Path,
        default=DEFAULT_SECONDARY_COMMENTS_FILE,
        help="Fallback .strings file used when the primary comments file has no matching key.",
    )
    parser.add_argument(
        "--report-dir",
        type=Path,
        default=Path("reports"),
        help=(
            "Directory used for generated reports. Relative paths are resolved against "
            "--project-root. Default: reports."
        ),
    )
    parser.add_argument(
        "--missing-comment-fallback",
        choices=("empty", "key"),
        default="empty",
        help='Fallback comment when a key is missing from the comments file. Default: "empty".',
    )
    return parser.parse_args()


def unescape_strings_token(text: str) -> str:
    text = text.replace(r"\\", "\0")
    text = text.replace(r"\"", '"')
    text = text.replace(r"\n", "\n")
    text = text.replace(r"\r", "\r")
    text = text.replace(r"\t", "\t")
    return text.replace("\0", "\\")


def escape_swift_string(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', r"\"")
        .replace("\n", r"\n")
        .replace("\r", r"\r")
        .replace("\t", r"\t")
    )


def escape_objc_string(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', r"\"")
        .replace("\n", r"\n")
        .replace("\r", r"\r")
        .replace("\t", r"\t")
    )


def load_comment_map(path: Path) -> dict[str, str]:
    if not path.exists():
        raise FileNotFoundError(f"Comments file not found: {path}")

    comments: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = STRINGS_KV_RE.match(line)
        if not match:
            continue
        key = unescape_strings_token(match.group("key"))
        value = unescape_strings_token(match.group("value"))
        comments.setdefault(key, value)
    return comments


def mask_comments(content: str) -> str:
    chars = list(content)
    i = 0
    n = len(chars)
    state = "code"
    string_quote = ""

    while i < n:
        ch = chars[i]
        nxt = chars[i + 1] if i + 1 < n else ""

        if state == "code":
            if ch == "/" and nxt == "/":
                chars[i] = " "
                chars[i + 1] = " "
                i += 2
                state = "line_comment"
                continue
            if ch == "/" and nxt == "*":
                chars[i] = " "
                chars[i + 1] = " "
                i += 2
                state = "block_comment"
                continue
            if ch == "@" and nxt == '"':
                i += 2
                state = "string"
                string_quote = '"'
                continue
            if ch == '"':
                i += 1
                state = "string"
                string_quote = '"'
                continue
            i += 1
            continue

        if state == "line_comment":
            if ch == "\n":
                state = "code"
            else:
                chars[i] = " "
            i += 1
            continue

        if state == "block_comment":
            if ch == "*" and nxt == "/":
                chars[i] = " "
                chars[i + 1] = " "
                i += 2
                state = "code"
                continue
            if ch != "\n":
                chars[i] = " "
            i += 1
            continue

        if state == "string":
            if ch == "\\":
                i += 2
                continue
            if ch == string_quote:
                i += 1
                state = "code"
                continue
            i += 1
            continue

    return "".join(chars)


def resolve_path(path: Path, base_dir: Path) -> Path:
    expanded = path.expanduser()
    if expanded.is_absolute():
        return expanded.resolve()
    return (base_dir / expanded).resolve()


def display_path(path: Path, base_dir: Path) -> str:
    try:
        return str(path.relative_to(base_dir))
    except ValueError:
        return str(path)


def collect_source_files(paths: list[Path], *, project_root: Path, source_root: Path) -> list[Path]:
    if not paths:
        paths = [source_root]

    files: list[Path] = []
    for raw_path in paths:
        path = resolve_path(raw_path, project_root)
        if not path.exists():
            continue
        if path.is_file() and path.suffix in SOURCE_EXTS:
            files.append(path.resolve())
            continue
        if path.is_dir():
            for child in path.rglob("*"):
                if child.is_file() and child.suffix in SOURCE_EXTS:
                    files.append(child.resolve())
    return sorted(set(files))


def build_comment(
    primary_comment_map: dict[str, str],
    secondary_comment_map: dict[str, str],
    key: str,
    fallback: str,
) -> tuple[str, str]:
    if key in primary_comment_map:
        return primary_comment_map[key], "primary"
    if key in secondary_comment_map:
        return secondary_comment_map[key], "secondary"
    if fallback == "key":
        return key, "fallback"
    return "", "missing"


def rewrite_content(
    path: Path,
    content: str,
    primary_comment_map: dict[str, str],
    secondary_comment_map: dict[str, str],
    fallback: str,
) -> tuple[str, FileChange]:
    result = FileChange(path=path)
    is_swift = path.suffix == ".swift"
    masked = mask_comments(content)
    pieces: list[str] = []
    last_index = 0

    for match in LITERAL_LOCALIZED_RE.finditer(masked):
        result.replacements += 1
        raw_key = match.group("key")
        key = unescape_strings_token(raw_key)
        comment, source = build_comment(primary_comment_map, secondary_comment_map, key, fallback)
        if source == "secondary":
            result.english_fallback_keys.append(key)
        elif source == "missing":
            result.missing_comment_keys.append(key)

        if is_swift:
            replacement = f'NSLocalizedString("{escape_swift_string(key)}", comment: "{escape_swift_string(comment)}")'
        else:
            replacement = f'NSLocalizedString(@"{escape_objc_string(key)}", @"{escape_objc_string(comment)}")'

        pieces.append(content[last_index:match.start()])
        pieces.append(replacement)
        last_index = match.end()

    pieces.append(content[last_index:])
    updated = "".join(pieces)
    updated = normalize_existing_nslocalizedstring_comments(updated, is_swift=is_swift)
    result.changed = updated != content
    return updated, result


def normalize_existing_nslocalizedstring_comments(content: str, is_swift: bool) -> str:
    pattern = SWIFT_NSLOCALIZED_RE if is_swift else OBJC_NSLOCALIZED_RE

    def repl(match: re.Match[str]) -> str:
        key = unescape_strings_token(match.group("key"))
        comment = unescape_strings_token(match.group("comment"))
        if is_swift:
            return f'NSLocalizedString("{escape_swift_string(key)}", comment: "{escape_swift_string(comment)}")'
        return f'NSLocalizedString(@"{escape_objc_string(key)}", @"{escape_objc_string(comment)}")'

    return pattern.sub(repl, content)


def process_file(
    path: Path,
    primary_comment_map: dict[str, str],
    secondary_comment_map: dict[str, str],
    apply: bool,
    fallback: str,
) -> FileChange:
    content = path.read_text(encoding="utf-8", errors="ignore")
    updated, result = rewrite_content(path, content, primary_comment_map, secondary_comment_map, fallback)
    if apply and result.changed:
        path.write_text(updated, encoding="utf-8")
    return result


def print_report(results: list[FileChange], apply: bool, project_root: Path) -> None:
    changed_results = [item for item in results if item.changed]
    total_replacements = sum(item.replacements for item in changed_results)
    total_english_fallback = sum(len(set(item.english_fallback_keys)) for item in changed_results)
    total_missing = sum(len(set(item.missing_comment_keys)) for item in changed_results)

    for item in changed_results:
        status = "updated" if apply else "would update"
        english_fallback = sorted(set(item.english_fallback_keys))
        missing = sorted(set(item.missing_comment_keys))
        line = f"[{status}] {display_path(item.path, project_root)}: replacements={item.replacements}"
        if english_fallback:
            preview = ", ".join(english_fallback[:5])
            if len(english_fallback) > 5:
                preview += ", ..."
            line += f", english_fallback={len(english_fallback)} ({preview})"
        if missing:
            preview = ", ".join(missing[:5])
            if len(missing) > 5:
                preview += ", ..."
            line += f", missing_comments={len(missing)} ({preview})"
        print(line)

    print(
        "Summary: "
        f"files_scanned={len(results)}, "
        f"files_changed={len(changed_results)}, "
        f"replacements={total_replacements}, "
        f"english_fallback_keys={total_english_fallback}, "
        f"missing_comment_keys={total_missing}"
    )


def write_missing_keys_report(results: list[FileChange], report_dir: Path) -> Path:
    report_path = report_dir / "missing_zh_hans_comments_for_localized_literals.txt"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    missing_keys: set[str] = set()
    for item in results:
        missing_keys.update(item.missing_comment_keys)

    lines = sorted(missing_keys)
    report_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return report_path


def write_english_fallback_report(results: list[FileChange], report_dir: Path) -> Path:
    report_path = report_dir / "english_fallback_comments_for_localized_literals.txt"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    fallback_keys: set[str] = set()
    for item in results:
        fallback_keys.update(item.english_fallback_keys)

    lines = sorted(fallback_keys)
    report_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return report_path


def main() -> int:
    args = parse_args()
    project_root = resolve_path(args.project_root, Path.cwd())
    source_root = resolve_path(args.source_root, project_root)
    report_dir = resolve_path(args.report_dir, project_root)
    try:
        primary_comment_map = load_comment_map(resolve_path(args.comments_file, project_root))
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    try:
        secondary_comment_map = load_comment_map(
            resolve_path(args.secondary_comments_file, project_root)
        )
    except FileNotFoundError:
        secondary_comment_map = {}

    files = collect_source_files(args.paths, project_root=project_root, source_root=source_root)
    if not files:
        print("No source files matched.", file=sys.stderr)
        return 1

    results = [
        process_file(
            path,
            primary_comment_map,
            secondary_comment_map,
            apply=args.apply,
            fallback=args.missing_comment_fallback,
        )
        for path in files
    ]
    changed_results = [item for item in results if item.changed]
    total_replacements = sum(item.replacements for item in changed_results)
    total_english_fallback = sum(len(set(item.english_fallback_keys)) for item in changed_results)
    total_missing = sum(len(set(item.missing_comment_keys)) for item in changed_results)

    for item in changed_results:
        status = "updated" if args.apply else "would update"
        english_fallback = sorted(set(item.english_fallback_keys))
        missing = sorted(set(item.missing_comment_keys))
        line = f"[{status}] {display_path(item.path, project_root)}: replacements={item.replacements}"
        if english_fallback:
            preview = ", ".join(english_fallback[:5])
            if len(english_fallback) > 5:
                preview += ", ..."
            line += f", english_fallback={len(english_fallback)} ({preview})"
        if missing:
            preview = ", ".join(missing[:5])
            if len(missing) > 5:
                preview += ", ..."
            line += f", missing_comments={len(missing)} ({preview})"
        print(line)

    print(
        "Summary: "
        f"files_scanned={len(results)}, "
        f"files_changed={len(changed_results)}, "
        f"replacements={total_replacements}, "
        f"english_fallback_keys={total_english_fallback}, "
        f"missing_comment_keys={total_missing}"
    )
    fallback_report_path = write_english_fallback_report(results, report_dir)
    report_path = write_missing_keys_report(results, report_dir)
    print(f"English-fallback report: {display_path(fallback_report_path, project_root)}")
    print(f"Missing-key report: {display_path(report_path, project_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
