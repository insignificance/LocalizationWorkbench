#!/usr/bin/env python3
# python3 scripts/migrate_i18n_keys.py
#    只生成报告，不改代码
# python3 scripts/migrate_i18n_keys.py --apply
#    生成同一套报告，并执行实际替换
#
import argparse
import csv
import json
import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


DEFAULT_MAP_FILE = Path("map.strings")
DEFAULT_LOCALIZABLE_DIR = Path("Renogy/Localizables")
DEFAULT_SOURCE_DIR = Path("Renogy")
DEFAULT_REPORT_DIR = Path("reports/i18n_key_migration")
SOURCE_EXTS = {".swift", ".m", ".mm", ".h"}

KV_RE = re.compile(
    r'^(?P<indent>\s*)"(?P<key>(?:\\.|[^"\\])*)"(?:\s*)=(?:\s*)"(?P<value>(?:\\.|[^"\\])*)"(?P<suffix>\s*;.*)$'
)
BARE_RE = re.compile(r'^(?P<indent>\s*)"(?P<value>(?:\\.|[^"\\])*)"(?P<suffix>\s*;.*)$')

# Only replace explicit localization call sites.
SOURCE_LOCALIZED_RE = re.compile(r'(?P<prefix>@?)"(?P<key>(?:\\.|[^"\\])*)"(?P<suffix>\.localized\b)')


@dataclass
class StringsEntry:
    line_no: int
    key: str
    value: str
    kind: str


@dataclass
class MigrationConfig:
    project_root: Path
    map_file: Path
    localizable_dir: Path
    en_localizable: Path
    report_dir: Path
    source_dir: Path


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


def escape_strings_token(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', r"\"")


def parse_strings_entries(path: Path) -> List[StringsEntry]:
    entries: List[StringsEntry] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("*/"):
            continue
        kv_match = KV_RE.match(line)
        if kv_match:
            entries.append(
                StringsEntry(
                    line_no=line_no,
                    key=kv_match.group("key"),
                    value=kv_match.group("value"),
                    kind="kv",
                )
            )
            continue
        bare_match = BARE_RE.match(line)
        if bare_match:
            value = bare_match.group("value")
            entries.append(StringsEntry(line_no=line_no, key=value, value=value, kind="bare"))
    return entries


def build_map_groups(map_file: Path) -> Tuple[Dict[str, List[str]], Dict[str, str]]:
    value_to_keys: Dict[str, List[str]] = defaultdict(list)
    for entry in parse_strings_entries(map_file):
        value_to_keys[entry.value].append(entry.key)
    unique_value_to_new_key = {
        value: keys[0]
        for value, keys in value_to_keys.items()
        if len(keys) == 1
    }
    return value_to_keys, unique_value_to_new_key


def build_en_value_index(en_localizable: Path) -> Dict[str, List[StringsEntry]]:
    value_to_entries: Dict[str, List[StringsEntry]] = defaultdict(list)
    for entry in parse_strings_entries(en_localizable):
        value_to_entries[entry.value].append(entry)
    return value_to_entries


def compute_replacements(config: MigrationConfig) -> Dict[str, object]:
    value_to_keys, map_unique = build_map_groups(config.map_file)
    en_value_index = build_en_value_index(config.en_localizable)

    deterministic: List[Dict[str, object]] = []
    ambiguous_old: List[Dict[str, object]] = []
    missing_old: List[Dict[str, object]] = []
    identity: List[Dict[str, object]] = []

    for value, new_key in sorted(map_unique.items(), key=lambda item: (item[1], item[0])):
        entries = en_value_index.get(value, [])
        old_keys = sorted({entry.key for entry in entries})
        if len(old_keys) == 0:
            missing_old.append({"new_key": new_key, "value": value})
            continue
        if len(old_keys) > 1:
            ambiguous_old.append({"new_key": new_key, "value": value, "old_keys": old_keys})
            continue

        old_key = old_keys[0]
        if old_key == new_key:
            identity.append({"new_key": new_key, "old_key": old_key, "value": value})
            continue

        entry = entries[0]
        deterministic.append(
            {
                "new_key": new_key,
                "old_key": old_key,
                "value": value,
                "en_line": entry.line_no,
                "en_kind": entry.kind,
            }
        )

    return {
        "value_to_keys": value_to_keys,
        "map_unique": map_unique,
        "deterministic": deterministic,
        "ambiguous_old": ambiguous_old,
        "missing_old": missing_old,
        "identity": identity,
    }


def ensure_report_dir(report_dir: Path) -> None:
    report_dir.mkdir(parents=True, exist_ok=True)


def write_csv(path: Path, headers: List[str], rows: List[List[object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        writer.writerows(rows)


def write_reports(data: Dict[str, object], config: MigrationConfig) -> Dict[str, int]:
    ensure_report_dir(config.report_dir)

    value_to_keys: Dict[str, List[str]] = data["value_to_keys"]  # type: ignore[assignment]
    deterministic: List[Dict[str, object]] = data["deterministic"]  # type: ignore[assignment]
    ambiguous_old: List[Dict[str, object]] = data["ambiguous_old"]  # type: ignore[assignment]
    missing_old: List[Dict[str, object]] = data["missing_old"]  # type: ignore[assignment]
    identity: List[Dict[str, object]] = data["identity"]  # type: ignore[assignment]

    unique_strings_path = config.report_dir / "unique_map.strings"
    with unique_strings_path.open("w", encoding="utf-8") as f:
        for row in deterministic:
            f.write(f"\"{escape_strings_token(str(row['new_key']))}\" = \"{escape_strings_token(str(row['value']))}\";\n")
        for row in identity:
            f.write(f"\"{escape_strings_token(str(row['new_key']))}\" = \"{escape_strings_token(str(row['value']))}\";\n")

    duplicate_rows: List[List[object]] = []
    duplicate_md = ["| value | keys | count |", "| --- | --- | --- |"]
    for value, keys in sorted(value_to_keys.items(), key=lambda item: (-len(item[1]), item[0])):
        if len(keys) <= 1:
            continue
        joined_keys = " | ".join(keys)
        escaped_value = value.replace("|", r"\|")
        escaped_joined_keys = joined_keys.replace("|", r"\|")
        duplicate_rows.append([value, " | ".join(keys), len(keys)])
        duplicate_md.append(f"| {escaped_value} | {escaped_joined_keys} | {len(keys)} |")
    write_csv(config.report_dir / "duplicate_value_groups.csv", ["value", "keys", "count"], duplicate_rows)
    (config.report_dir / "duplicate_value_groups.md").write_text("\n".join(duplicate_md) + "\n", encoding="utf-8")

    write_csv(
        config.report_dir / "deterministic_replacements.csv",
        ["old_key", "new_key", "value", "en_line", "en_kind"],
        [[row["old_key"], row["new_key"], row["value"], row["en_line"], row["en_kind"]] for row in deterministic],
    )
    write_csv(
        config.report_dir / "ambiguous_old_keys.csv",
        ["new_key", "value", "old_keys"],
        [[row["new_key"], row["value"], " | ".join(row["old_keys"])] for row in ambiguous_old],
    )
    write_csv(
        config.report_dir / "missing_old_keys.csv",
        ["new_key", "value"],
        [[row["new_key"], row["value"]] for row in missing_old],
    )
    write_csv(
        config.report_dir / "identity_mappings.csv",
        ["old_key", "new_key", "value"],
        [[row["old_key"], row["new_key"], row["value"]] for row in identity],
    )

    summary = {
        "map_entries": sum(len(keys) for keys in value_to_keys.values()),
        "map_unique_by_value": sum(1 for keys in value_to_keys.values() if len(keys) == 1),
        "map_duplicate_value_groups": sum(1 for keys in value_to_keys.values() if len(keys) > 1),
        "deterministic_replacements": len(deterministic),
        "identity_mappings": len(identity),
        "ambiguous_old_keys": len(ambiguous_old),
        "missing_old_keys": len(missing_old),
    }
    (config.report_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return summary


def discover_localizable_files(localizable_dir: Path) -> List[Path]:
    return sorted(localizable_dir.glob("*.lproj/Localizable.strings"))


def discover_source_files(source_dir: Path) -> List[Path]:
    files: List[Path] = []
    for path in source_dir.rglob("*"):
        if not path.is_file():
            continue
        if "Pods" in path.parts:
            continue
        if path.suffix in SOURCE_EXTS:
            files.append(path)
    return sorted(files)


def replace_source_content(content: str, key_map: Dict[str, str]) -> Tuple[str, int]:
    replacements = 0

    def repl(match: re.Match[str]) -> str:
        nonlocal replacements
        key = match.group("key")
        new_key = key_map.get(key)
        if not new_key:
            return match.group(0)
        replacements += 1
        return f'{match.group("prefix")}"{escape_strings_token(new_key)}"{match.group("suffix")}'

    return SOURCE_LOCALIZED_RE.sub(repl, content), replacements


def update_strings_file(
    path: Path,
    key_map: Dict[str, str],
    *,
    project_root: Path,
) -> Tuple[bool, int, List[Dict[str, object]]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    parsed_entries = parse_strings_entries(path)
    existing_keys = defaultdict(list)
    for entry in parsed_entries:
        existing_keys[entry.key].append(entry.line_no)

    conflicts: List[Dict[str, object]] = []
    for old_key, new_key in key_map.items():
        if old_key == new_key:
            continue
        if existing_keys.get(old_key) and existing_keys.get(new_key):
            conflicts.append(
                {
                    "file": display_path(path, project_root),
                    "old_key": old_key,
                    "new_key": new_key,
                    "old_lines": existing_keys[old_key],
                    "new_lines": existing_keys[new_key],
                }
            )

    conflicted_old_keys = {item["old_key"] for item in conflicts}
    changed = False
    replacements = 0
    new_lines: List[str] = []

    for line in lines:
        kv_match = KV_RE.match(line)
        if kv_match:
            old_key = kv_match.group("key")
            new_key = key_map.get(old_key)
            if new_key and old_key not in conflicted_old_keys:
                new_line = (
                    f'{kv_match.group("indent")}"{escape_strings_token(new_key)}" = '
                    f'"{kv_match.group("value")}"{kv_match.group("suffix")}'
                )
                if new_line != line:
                    changed = True
                    replacements += 1
                    line = new_line
            new_lines.append(line)
            continue

        bare_match = BARE_RE.match(line)
        if bare_match:
            old_key = bare_match.group("value")
            new_key = key_map.get(old_key)
            if new_key and old_key not in conflicted_old_keys:
                new_line = (
                    f'{bare_match.group("indent")}"{escape_strings_token(new_key)}" = '
                    f'"{bare_match.group("value")}"{bare_match.group("suffix")}'
                )
                if new_line != line:
                    changed = True
                    replacements += 1
                    line = new_line
            new_lines.append(line)
            continue

        new_lines.append(line)

    if changed:
        path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return changed, replacements, conflicts


def apply_changes(data: Dict[str, object], config: MigrationConfig) -> Dict[str, object]:
    deterministic: List[Dict[str, object]] = data["deterministic"]  # type: ignore[assignment]
    key_map = {str(row["old_key"]): str(row["new_key"]) for row in deterministic}

    source_changes: List[Dict[str, object]] = []
    total_source_replacements = 0
    for path in discover_source_files(config.source_dir):
        content = path.read_text(encoding="utf-8")
        new_content, replacements = replace_source_content(content, key_map)
        if replacements > 0 and new_content != content:
            path.write_text(new_content, encoding="utf-8")
            total_source_replacements += replacements
            source_changes.append(
                {"file": display_path(path, config.project_root), "replacements": replacements}
            )

    strings_changes: List[Dict[str, object]] = []
    strings_conflicts: List[Dict[str, object]] = []
    total_strings_replacements = 0
    for path in discover_localizable_files(config.localizable_dir):
        changed, replacements, conflicts = update_strings_file(
            path,
            key_map,
            project_root=config.project_root,
        )
        if conflicts:
            strings_conflicts.extend(conflicts)
        if changed:
            total_strings_replacements += replacements
            strings_changes.append(
                {"file": display_path(path, config.project_root), "replacements": replacements}
            )

    ensure_report_dir(config.report_dir)
    write_csv(
        config.report_dir / "applied_source_changes.csv",
        ["file", "replacements"],
        [[row["file"], row["replacements"]] for row in source_changes],
    )
    write_csv(
        config.report_dir / "applied_strings_changes.csv",
        ["file", "replacements"],
        [[row["file"], row["replacements"]] for row in strings_changes],
    )
    write_csv(
        config.report_dir / "strings_key_conflicts.csv",
        ["file", "old_key", "new_key", "old_lines", "new_lines"],
        [
            [
                row["file"],
                row["old_key"],
                row["new_key"],
                " | ".join(str(x) for x in row["old_lines"]),
                " | ".join(str(x) for x in row["new_lines"]),
            ]
            for row in strings_conflicts
        ],
    )

    apply_summary = {
        "source_files_changed": len(source_changes),
        "source_replacements": total_source_replacements,
        "localizable_files_changed": len(strings_changes),
        "localizable_replacements": total_strings_replacements,
        "strings_conflicts": len(strings_conflicts),
    }
    (config.report_dir / "apply_summary.json").write_text(
        json.dumps(apply_summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return apply_summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Migrate i18n keys from old project keys to standard keys."
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Base directory used to resolve relative paths. Default: current working directory.",
    )
    parser.add_argument(
        "--map-file",
        type=Path,
        default=DEFAULT_MAP_FILE,
        help="Path to the mapping .strings file. Default: map.strings.",
    )
    parser.add_argument(
        "--localizable-dir",
        type=Path,
        default=DEFAULT_LOCALIZABLE_DIR,
        help="Directory containing *.lproj/Localizable.strings. Default: Renogy/Localizables.",
    )
    parser.add_argument(
        "--en-localizable",
        type=Path,
        help=(
            "English Localizable.strings used to map values back to old keys. "
            "Defaults to <localizable-dir>/en.lproj/Localizable.strings."
        ),
    )
    parser.add_argument(
        "--report-dir",
        type=Path,
        default=DEFAULT_REPORT_DIR,
        help="Directory for generated reports. Default: reports/i18n_key_migration.",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIR,
        help="Directory containing source files to update. Default: Renogy.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply replacements after generating reports.",
    )
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> MigrationConfig:
    project_root = resolve_path(args.project_root, Path.cwd())
    localizable_dir = resolve_path(args.localizable_dir, project_root)
    return MigrationConfig(
        project_root=project_root,
        map_file=resolve_path(args.map_file, project_root),
        localizable_dir=localizable_dir,
        en_localizable=resolve_path(
            args.en_localizable or (localizable_dir / "en.lproj/Localizable.strings"),
            project_root,
        ),
        report_dir=resolve_path(args.report_dir, project_root),
        source_dir=resolve_path(args.source_dir, project_root),
    )


def main() -> None:
    args = parse_args()
    config = build_config(args)

    data = compute_replacements(config)
    summary = write_reports(data, config)
    print(f"Reports: {display_path(config.report_dir, config.project_root)}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.apply:
        apply_summary = apply_changes(data, config)
        print(json.dumps(apply_summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
