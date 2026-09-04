#!/usr/bin/env python3
# python3 excel_to_localizations.py './多端文案统一命名规则-转换.xlsx' './iOS文案补充
#  20260325.xlsx' './output_all_excels_20260326_165140' --format strings --all-sheets-with-app
#  

import argparse
from contextlib import ExitStack
import json
import re
import signal
import sqlite3
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

from locale_registry import load_locale_registry, normalize_locale_code


NS = {
    "main": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
    "office_rel": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}

DEFAULT_TRUE_VALUES = {"true", "1", "yes", "y"}
ESCAPED_VALUE_PATTERN = re.compile(r'\\(?:[nrt"\'\\]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})')
KEY_HEADER_NAMES = {
    "devkey",
    "dev key",
    "文案的key",
    "id",
    "错误码",
    "appdevkey",
}
DEFAULT_PRIMARY_GROUP_NAMES = ("名称", "name")
PROGRESS_PREFIX = "@@LOCALIZATION_PROGRESS@@"
DEFAULT_CHUNK_ROWS = 2_000
SHARED_STRINGS_DISK_THRESHOLD_BYTES = 16 * 1024 * 1024
ENTRY_STORE_MEMORY_LIMIT = 20_000
MAX_RECORDED_ISSUES = 10_000


_locale_registry = load_locale_registry()


class IssueLog:
    def __init__(self) -> None:
        self.items: List[Dict[str, str]] = []
        self.total_count = 0
        self.suppressed_count = 0
        self.level_counts = Counter()

    def add(
        self,
        level: str,
        category: str,
        message: str,
        *,
        sheet: Optional[str] = None,
        row: Optional[int] = None,
        column: Optional[str] = None,
        column_header: Optional[str] = None,
        key: Optional[str] = None,
    ) -> None:
        self.total_count += 1
        normalized_level = level.upper()
        self.level_counts[normalized_level] += 1
        # 大量脏数据不应让问题日志本身占满内存。
        if len(self.items) >= MAX_RECORDED_ISSUES:
            self.suppressed_count += 1
            return

        entry: Dict[str, str] = {
            "level": normalized_level,
            "category": category,
            "message": message,
        }
        if sheet:
            entry["sheet"] = sheet
        if row is not None:
            entry["row"] = str(row)
        if column:
            entry["column"] = column
        if column_header:
            entry["column_header"] = column_header
        if key:
            entry["key"] = key
        self.items.append(entry)

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)

        lines = [
            "Excel To iOS Localizations Log",
            "",
            f"Total issues: {self.total_count}",
            f"ERROR: {self.level_counts.get('ERROR', 0)}",
            f"WARNING: {self.level_counts.get('WARNING', 0)}",
            f"INFO: {self.level_counts.get('INFO', 0)}",
            "",
        ]

        if self.suppressed_count:
            lines.append(
                f"Only the first {MAX_RECORDED_ISSUES} issues are listed; "
                f"{self.suppressed_count} additional issues were suppressed."
            )
            lines.append("")

        if not self.items:
            lines.append("No issues found.")
        else:
            grouped: "OrderedDict[str, List[Dict[str, str]]]" = OrderedDict()
            for item in self.items:
                grouped.setdefault(item.get("sheet", "<global>"), []).append(item)

            lines.append("Summary By Sheet")
            lines.append("")
            for sheet_name, sheet_items in grouped.items():
                sheet_level_counts = Counter(item["level"] for item in sheet_items)
                lines.append(
                    f"- {sheet_name}: total={len(sheet_items)}, "
                    f"ERROR={sheet_level_counts.get('ERROR', 0)}, "
                    f"WARNING={sheet_level_counts.get('WARNING', 0)}, "
                    f"INFO={sheet_level_counts.get('INFO', 0)}"
                )

            lines.append("")
            lines.append("Detailed Issues")
            lines.append("")

            for sheet_name, sheet_items in grouped.items():
                lines.append(f"=== Sheet: {sheet_name} ===")
                for index, item in enumerate(sheet_items, start=1):
                    parts = [f"[{item['level']}]", item["category"]]
                    if "row" in item:
                        parts.append(f"row={item['row']}")
                    if "column" in item:
                        if "column_header" in item:
                            parts.append(f"column={item['column']} ({item['column_header']})")
                        else:
                            parts.append(f"column={item['column']}")
                    if "key" in item:
                        parts.append(f"key={item['key']}")
                    lines.append(f"{index}. {' | '.join(parts)}")
                    lines.append(f"   {item['message']}")
                lines.append("")

        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


@dataclass(frozen=True)
class OutputSpec:
    table_name: str
    key_column: Optional[str]
    key_header: Optional[str]
    optional: bool = False


class ProgressReporter:
    def __init__(self) -> None:
        self.last_emit_at = 0.0
        self.last_stage = ""

    def emit(self, stage: str, fraction: float, detail: str, *, force: bool = False) -> None:
        now = time.monotonic()
        fraction = max(0.0, min(1.0, fraction))
        if not force and stage == self.last_stage and now - self.last_emit_at < 0.16:
            return

        payload = {
            "stage": stage,
            "fraction": round(fraction, 4),
            "detail": detail,
        }
        print(PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=True, separators=(",", ":")), flush=True)
        self.last_emit_at = now
        self.last_stage = stage


class ConversionProgress:
    def __init__(self, input_paths: List[Path]) -> None:
        self.reporter = ProgressReporter()
        self.input_sizes = {path: max(path.stat().st_size, 1) for path in input_paths}
        self.total_input_size = max(sum(self.input_sizes.values()), 1)
        self.completed_input_size = 0
        self.current_file_size = 1
        self.current_file_name = ""
        self.current_file_index = 0
        self.total_file_count = len(input_paths)
        self.current_sheet_count = 0
        self.current_sheet_index = 0
        self.current_sheet_size = 1
        self.completed_sheet_size = 0
        self.total_sheet_size = 1

    def begin_file(
        self,
        path: Path,
        file_index: int,
        sheet_names: List[str],
        sheet_sizes: List[int],
    ) -> None:
        self.current_file_name = path.name
        self.current_file_index = file_index
        self.current_file_size = self.input_sizes[path]
        self.current_sheet_count = len(sheet_names)
        self.current_sheet_index = 0
        self.current_sheet_size = 1
        self.completed_sheet_size = 0
        self.total_sheet_size = max(sum(max(size, 1) for size in sheet_sizes), 1)
        self._emit_parse_progress(0.0, "正在准备工作簿")

    def begin_sheet(self, sheet_name: str, sheet_index: int, sheet_size: int) -> None:
        self.current_sheet_index = sheet_index
        self.current_sheet_size = max(sheet_size, 1)
        self._emit_parse_progress(
            0.0,
            f"{self.current_file_name} · {sheet_name} · 第 {sheet_index}/{self.current_sheet_count} 个 Sheet",
            force=True,
        )

    def update_sheet(self, bytes_read: int, rows_processed: int) -> None:
        sheet_fraction = min(max(bytes_read, 0) / self.current_sheet_size, 1.0)
        self._emit_parse_progress(
            sheet_fraction,
            (
                f"{self.current_file_name} · 第 {self.current_sheet_index}/{self.current_sheet_count} 个 Sheet · "
                f"已处理 {rows_processed:,} 行（分块处理中）"
            ),
        )

    def finish_sheet(self) -> None:
        self.completed_sheet_size += self.current_sheet_size
        self._emit_parse_progress(0.0, "当前 Sheet 处理完成", force=True)

    def finish_file(self) -> None:
        self.completed_input_size += self.current_file_size
        self.reporter.emit(
            "解析工作簿",
            0.9 * min(self.completed_input_size / self.total_input_size, 1.0),
            f"已完成 {self.current_file_index}/{self.total_file_count} 个工作簿",
            force=True,
        )

    def update_output(self, stage: str, current: int, total: int, detail: str) -> None:
        output_fraction = current / max(total, 1)
        self.reporter.emit(stage, 0.9 + 0.1 * output_fraction, detail)

    def finish(self) -> None:
        self.reporter.emit("转换完成", 1.0, "所有输出文件已生成", force=True)

    def _emit_parse_progress(self, sheet_fraction: float, detail: str, *, force: bool = False) -> None:
        file_fraction = (
            self.completed_sheet_size + self.current_sheet_size * sheet_fraction
        ) / self.total_sheet_size
        total_fraction = (
            self.completed_input_size + self.current_file_size * min(file_fraction, 1.0)
        ) / self.total_input_size
        self.reporter.emit("流式解析 Excel", 0.9 * total_fraction, detail, force=force)


@dataclass(frozen=True)
class StreamedRow:
    number: int
    values: Dict[int, str]
    bytes_read: int


class DiskBackedSharedStrings:
    def __init__(self, workbook_zip: zipfile.ZipFile, temporary_directory: Path) -> None:
        self.database_path = temporary_directory / "shared_strings.sqlite"
        self.connection = sqlite3.connect(self.database_path)
        self.connection.execute("CREATE TABLE strings (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        self.cache: "OrderedDict[int, str]" = OrderedDict()

        batch: List[Tuple[int, str]] = []
        index = 0
        with workbook_zip.open("xl/sharedStrings.xml") as source:
            parser = ET.iterparse(source, events=("start", "end"))
            root: Optional[ET.Element] = None
            for event, element in parser:
                if event == "start" and root is None:
                    root = element
                    continue
                if event != "end" or element.tag != f"{{{NS['main']}}}si":
                    continue

                batch.append((index, extract_text(element)))
                index += 1
                if len(batch) >= DEFAULT_CHUNK_ROWS:
                    self.connection.executemany("INSERT INTO strings (id, value) VALUES (?, ?)", batch)
                    batch.clear()
                element.clear()
                if root is not None:
                    root.clear()

        if batch:
            self.connection.executemany("INSERT INTO strings (id, value) VALUES (?, ?)", batch)
        self.connection.commit()

    def __getitem__(self, index: int) -> str:
        cached = self.cache.get(index)
        if cached is not None:
            self.cache.move_to_end(index)
            return cached

        row = self.connection.execute("SELECT value FROM strings WHERE id = ?", (index,)).fetchone()
        if row is None:
            raise IndexError(f"Shared string index {index} is out of range.")

        value = row[0]
        self.cache[index] = value
        if len(self.cache) > 4_096:
            self.cache.popitem(last=False)
        return value

    def close(self) -> None:
        self.connection.close()


class WorkbookReader:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.workbook_zip: Optional[zipfile.ZipFile] = None
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="localization-workbench-xlsx-")
        self.sheet_paths: Dict[str, str] = {}
        self.sheet_names: List[str] = []
        self.shared_strings: Optional[object] = None

    def __enter__(self) -> "WorkbookReader":
        if self.path.suffix.lower() != ".xlsx":
            raise ValueError("Only .xlsx input is supported.")

        self.workbook_zip = zipfile.ZipFile(self.path)
        _, relationships, sheets = load_workbook_metadata(self.workbook_zip)
        for sheet in sheets:
            sheet_name = sheet.attrib.get("name", "")
            relationship_id = sheet.attrib.get(f"{{{NS['office_rel']}}}id")
            if not sheet_name or not relationship_id:
                continue
            target = next(
                (
                    relation.attrib.get("Target")
                    for relation in relationships.findall("rel:Relationship", NS)
                    if relation.attrib.get("Id") == relationship_id
                ),
                None,
            )
            if target is None:
                continue
            self.sheet_names.append(sheet_name)
            self.sheet_paths[sheet_name] = normalize_zip_path("xl", target)
        if not self.sheet_names:
            raise ValueError("Workbook does not contain any sheets.")
        return self

    def __exit__(self, exc_type: object, exc_value: object, traceback: object) -> None:
        self.close()

    def close(self) -> None:
        if isinstance(self.shared_strings, DiskBackedSharedStrings):
            self.shared_strings.close()
        if self.workbook_zip is not None:
            self.workbook_zip.close()
            self.workbook_zip = None
        self.temporary_directory.cleanup()

    def selected_sheet_name(self, sheet_name: Optional[str], sheet_index: int) -> str:
        if sheet_name:
            if sheet_name not in self.sheet_paths:
                raise ValueError(f'Sheet "{sheet_name}" was not found.')
            return sheet_name
        if sheet_index < 0 or sheet_index >= len(self.sheet_names):
            raise ValueError(f"Sheet index {sheet_index} is out of range.")
        return self.sheet_names[sheet_index]

    def sheet_size(self, sheet_name: str) -> int:
        workbook_zip = self._require_zip()
        return workbook_zip.getinfo(self.sheet_paths[sheet_name]).file_size

    def read_header(self, sheet_name: str, header_row: int) -> Dict[int, str]:
        for row in self.iter_rows(sheet_name):
            if row.number == header_row:
                return row.values
            if row.number > header_row:
                break
        return {}

    def iter_rows(self, sheet_name: str) -> Iterator[StreamedRow]:
        workbook_zip = self._require_zip()
        shared_strings = self._load_shared_strings(workbook_zip)
        row_tag = f"{{{NS['main']}}}row"
        sheet_data_tag = f"{{{NS['main']}}}sheetData"

        with workbook_zip.open(self.sheet_paths[sheet_name]) as source:
            parser = ET.iterparse(source, events=("start", "end"))
            sheet_data: Optional[ET.Element] = None
            for event, element in parser:
                if event == "start" and element.tag == sheet_data_tag:
                    sheet_data = element
                    continue
                if event != "end" or element.tag != row_tag:
                    continue

                raw_number = element.attrib.get("r")
                if raw_number is None:
                    element.clear()
                    continue
                row_values: Dict[int, str] = {}
                for cell in element.findall("main:c", NS):
                    reference = cell.attrib.get("r", "")
                    if not reference:
                        continue
                    column_letters = re.sub(r"\d", "", reference)
                    row_values[column_to_index(column_letters)] = read_cell_value(cell, shared_strings).strip()

                # 每处理一行就释放 XML 节点，避免超大 Sheet 常驻内存。
                yield StreamedRow(int(raw_number), row_values, source.tell())
                element.clear()
                if sheet_data is not None:
                    sheet_data.clear()

    def _require_zip(self) -> zipfile.ZipFile:
        if self.workbook_zip is None:
            raise RuntimeError("WorkbookReader must be used as a context manager.")
        return self.workbook_zip

    def _load_shared_strings(self, workbook_zip: zipfile.ZipFile) -> object:
        if self.shared_strings is not None:
            return self.shared_strings
        try:
            shared_strings_info = workbook_zip.getinfo("xl/sharedStrings.xml")
        except KeyError:
            self.shared_strings = []
            return self.shared_strings

        if shared_strings_info.file_size >= SHARED_STRINGS_DISK_THRESHOLD_BYTES:
            print("Large shared string table detected; using temporary on-disk storage.")
            self.shared_strings = DiskBackedSharedStrings(
                workbook_zip,
                Path(self.temporary_directory.name),
            )
        else:
            self.shared_strings = read_shared_strings(workbook_zip)
        return self.shared_strings


class EntryStore:
    def __init__(self, temporary_directory: Path, issue_log: IssueLog) -> None:
        self.temporary_directory = temporary_directory
        self.issue_log = issue_log
        self.memory_entries: Dict[str, Dict[str, str]] = {}
        self.connection: Optional[sqlite3.Connection] = None
        self.entry_count = 0

    @property
    def uses_disk(self) -> bool:
        return self.connection is not None

    def merge(
        self,
        key: str,
        localized_values: Dict[str, str],
        source_name: str,
        conflict_policy: str,
    ) -> None:
        existing = self._read(key)
        if existing is None:
            self._write(key, dict(localized_values))
            self.entry_count += 1
            if self.connection is None and len(self.memory_entries) > ENTRY_STORE_MEMORY_LIMIT:
                self._spill_to_disk()
            return

        changed = False
        for locale, value in localized_values.items():
            if locale not in existing:
                existing[locale] = value
                changed = True
                continue
            if existing[locale] == value:
                continue
            if conflict_policy == "error":
                self.issue_log.add(
                    "ERROR",
                    "conflicting_value",
                    f'Conflicting value found for locale "{locale}" while merging sheets.',
                    sheet=source_name,
                    column="locale",
                    column_header=locale,
                    key=key,
                )
                raise ValueError(
                    f'Conflicting value for key "{key}" locale "{locale}" found in sheet "{source_name}".'
                )
            if conflict_policy == "keep-last":
                existing[locale] = value
                changed = True
                message = f'Replaced earlier value for locale "{locale}" with the value from sheet "{source_name}".'
            else:
                message = f'Kept earlier value for locale "{locale}" and ignored the value from sheet "{source_name}".'
            self.issue_log.add(
                "WARNING",
                "conflicting_value",
                message,
                sheet=source_name,
                column="locale",
                column_header=locale,
                key=key,
            )

        if changed:
            self._write(key, existing)

    def commit(self) -> None:
        if self.connection is not None:
            self.connection.commit()

    def iter_entries(self) -> Iterator[Tuple[str, Dict[str, str]]]:
        if self.connection is None:
            for key in sorted(self.memory_entries):
                yield key, self.memory_entries[key]
            return

        self.connection.commit()
        cursor = self.connection.execute("SELECT key, values_json FROM entries ORDER BY key")
        for key, values_json in cursor:
            yield key, json.loads(values_json)

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def _read(self, key: str) -> Optional[Dict[str, str]]:
        if self.connection is None:
            return self.memory_entries.get(key)
        row = self.connection.execute("SELECT values_json FROM entries WHERE key = ?", (key,)).fetchone()
        return json.loads(row[0]) if row is not None else None

    def _write(self, key: str, values: Dict[str, str]) -> None:
        if self.connection is None:
            self.memory_entries[key] = values
            return
        self.connection.execute(
            "INSERT INTO entries (key, values_json) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET values_json = excluded.values_json",
            (key, json.dumps(values, ensure_ascii=False, separators=(",", ":"))),
        )

    def _spill_to_disk(self) -> None:
        # 超过阈值后将合并结果换到临时 SQLite，避免输出前积累海量字典。
        database_path = self.temporary_directory / "localized_entries.sqlite"
        self.connection = sqlite3.connect(database_path)
        self.connection.execute("CREATE TABLE entries (key TEXT PRIMARY KEY, values_json TEXT NOT NULL)")
        self.connection.executemany(
            "INSERT INTO entries (key, values_json) VALUES (?, ?)",
            [
                (key, json.dumps(values, ensure_ascii=False, separators=(",", ":")))
                for key, values in self.memory_entries.items()
            ],
        )
        self.connection.commit()
        self.memory_entries.clear()
        print("Large import detected; merged localization entries now use temporary on-disk storage.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert one or more Excel .xlsx files into iOS .strings and/or .xcstrings files."
    )
    parser.add_argument(
        "input",
        type=Path,
        nargs="+",
        help="Path(s) to the input .xlsx file(s). When multiple files are provided, their entries are merged.",
    )
    parser.add_argument("output", type=Path, help="Output directory.")
    parser.add_argument(
        "--format",
        choices=("strings", "xcstrings", "both"),
        default="both",
        help="Output format. Default: both.",
    )
    parser.add_argument(
        "--sheet-index",
        type=int,
        default=0,
        help="Zero-based sheet index. Ignored when --sheet-name is provided.",
    )
    parser.add_argument(
        "--sheet-name",
        help="Sheet name to read. Defaults to the first sheet.",
    )
    parser.add_argument(
        "--header-row",
        type=int,
        default=1,
        help="One-based row number that contains language codes. Default: 1.",
    )
    parser.add_argument(
        "--key-column",
        default="A",
        help="Column that contains localization keys. Default: A.",
    )
    parser.add_argument(
        "--key-header",
        help="Header name of the localization key column. Overrides --key-column when provided.",
    )
    parser.add_argument(
        "--table-name",
        default="Localizable",
        help="Base filename for output. Default: Localizable.",
    )
    parser.add_argument(
        "--extra-key-header",
        help=(
            "Optional header name of an additional localization key column. "
            "When provided, matching keys are merged into the same output table."
        ),
    )
    parser.add_argument(
        "--extra-table-name",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--development-language",
        help="Override the source language for .xcstrings. Defaults to the first language column.",
    )
    parser.add_argument(
        "--locale-config",
        type=Path,
        help="Optional JSON file whose locale aliases are merged with the bundled registry.",
    )
    parser.add_argument(
        "--app-column",
        default="App",
        help="Header name of the app filter column. Default: App.",
    )
    parser.add_argument(
        "--app-true-values",
        default="TRUE,true,1,yes,y",
        help="Comma-separated values treated as true for the app filter. Default: TRUE,true,1,yes,y.",
    )
    parser.add_argument(
        "--app-true-only",
        action="store_true",
        help="Only export rows whose app column is a truthy value.",
    )
    parser.add_argument(
        "--all-sheets-with-app",
        action="store_true",
        help="Scan the whole workbook and merge rows from sheets that contain an app column and a recognized key column.",
    )
    parser.add_argument(
        "--auto-detect-workbook-mode",
        action="store_true",
        help=(
            "Automatically switch to workbook scanning when the input appears to use "
            "multi-sheet App-column layout."
        ),
    )
    parser.add_argument(
        "--conflict-policy",
        choices=("error", "keep-first", "keep-last"),
        default="keep-first",
        help="How to handle duplicate keys with conflicting values when merging sheets/files. Default: keep-first.",
    )
    parser.add_argument(
        "--log-file",
        help="Path to the log file. Defaults to <output>/conversion_issues.log.",
    )
    parser.add_argument(
        "--merge-into",
        type=Path,
        help=(
            "Optional localization resource root. Generated .strings / .xcstrings files are merged "
            "into this directory after conversion; incoming cloud translations replace matching keys."
        ),
    )
    parser.add_argument(
        "--chunk-rows",
        type=int,
        default=DEFAULT_CHUNK_ROWS,
        help=(
            "Rows processed before committing a streaming batch and updating progress. "
            f"Default: {DEFAULT_CHUNK_ROWS}."
        ),
    )
    args = parser.parse_args()
    if args.chunk_rows < 1:
        parser.error("--chunk-rows must be at least 1.")
    return args


def read_shared_strings(workbook_zip: zipfile.ZipFile) -> List[str]:
    try:
        xml_bytes = workbook_zip.read("xl/sharedStrings.xml")
    except KeyError:
        return []

    root = ET.fromstring(xml_bytes)
    strings: List[str] = []
    for item in root.findall("main:si", NS):
        strings.append(extract_text(item))
    return strings


def load_workbook_metadata(
    workbook_zip: zipfile.ZipFile,
) -> Tuple[ET.Element, ET.Element, List[ET.Element]]:
    workbook_root = ET.fromstring(workbook_zip.read("xl/workbook.xml"))
    rels_root = ET.fromstring(workbook_zip.read("xl/_rels/workbook.xml.rels"))
    sheets = workbook_root.findall("main:sheets/main:sheet", NS)
    return workbook_root, rels_root, sheets


def normalize_zip_path(base: str, target: str) -> str:
    # OOXML 关系既可能是相对路径，也可能以 / 开头表示包根目录的绝对路径。
    raw_path = target if target.startswith("/") else f"{base}/{target}"
    parts: List[str] = []
    for part in raw_path.split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


def extract_text(element: ET.Element) -> str:
    text_parts: List[str] = []
    for node in element.iter():
        if node.tag == f"{{{NS['main']}}}t":
            text_parts.append(node.text or "")
    return "".join(text_parts)


def read_cell_value(cell: ET.Element, shared_strings: List[str]) -> str:
    cell_type = cell.attrib.get("t")

    if cell_type == "inlineStr":
        inline = cell.find("main:is", NS)
        return extract_text(inline) if inline is not None else ""

    value_node = cell.find("main:v", NS)
    if value_node is None:
        return ""

    raw_value = value_node.text or ""
    if cell_type == "s":
        index = int(raw_value)
        return shared_strings[index]
    if cell_type == "b":
        return "true" if raw_value == "1" else "false"
    return raw_value


def column_to_index(column_letters: str) -> int:
    result = 0
    for letter in column_letters.upper():
        if not ("A" <= letter <= "Z"):
            raise ValueError(f'Invalid column reference "{column_letters}".')
        result = result * 26 + (ord(letter) - ord("A") + 1)
    return result


def index_to_column(column_index: int) -> str:
    if column_index < 1:
        raise ValueError(f"Invalid column index {column_index}.")

    letters: List[str] = []
    current = column_index
    while current > 0:
        current, remainder = divmod(current - 1, 26)
        letters.append(chr(ord("A") + remainder))
    return "".join(reversed(letters))


def normalize_header_name(value: str) -> str:
    return re.sub(r"\s+", "", value).strip().lower()


def normalize_language_code(value: str) -> str:
    return normalize_locale_code(value)


def locale_token_to_code(value: str) -> Optional[str]:
    return _locale_registry.resolve_token(value)


def parse_locale_header(value: str) -> Optional[Tuple[str, str]]:
    return _locale_registry.parse_header(value)


def header_to_locale(value: str) -> Optional[str]:
    parsed = parse_locale_header(value)
    return parsed[1] if parsed is not None else None


def lproj_folder(language_code: str) -> str:
    return f"{normalize_language_code(language_code)}.lproj"


def escape_strings_value(value: str) -> str:
    parts: List[str] = []
    index = 0
    while index < len(value):
        char = value[index]
        if char == "\\":
            next_char = value[index + 1] if index + 1 < len(value) else ""
            # Keep apostrophe escapes as `\'` in .strings source text.
            if next_char == "'":
                parts.append("\\'")
                index += 2
                continue
            parts.append("\\\\")
        elif char == '"':
            parts.append('\\"')
        elif char == "\n":
            parts.append("\\n")
        elif char == "\r":
            parts.append("\\r")
        elif char == "\t":
            parts.append("\\t")
        else:
            parts.append(char)
        index += 1
    return "".join(parts)


def normalize_localized_value(value: str) -> str:
    def replace_escape(match: re.Match[str]) -> str:
        token = match.group(0)
        if token == r"\n":
            return "\n"
        if token == r"\r":
            return "\r"
        if token == r"\t":
            return "\t"
        if token == r"\"":
            return '"'
        if token == r"\\":
            return "\\"
        if token.startswith(r"\u") or token.startswith(r"\U"):
            return chr(int(token[2:], 16))
        return token

    return ESCAPED_VALUE_PATTERN.sub(replace_escape, value)


def normalize_key(value: str) -> str:
    key = value.strip()
    match = re.search(r'<string\s+name="([^"]+)"', key)
    if match:
        return match.group(1)
    return key


def normalized_truthy_values(raw_values: str) -> set:
    parsed = {value.strip().lower() for value in raw_values.split(",") if value.strip()}
    return parsed or DEFAULT_TRUE_VALUES


def is_truthy(value: str, truthy_values: set) -> bool:
    return value.strip().lower() in truthy_values


def find_header_column(header: Dict[int, str], expected_names: List[str]) -> Optional[int]:
    normalized_targets = {normalize_header_name(name) for name in expected_names}
    for column_number, value in header.items():
        if normalize_header_name(value) in normalized_targets:
            return column_number
    return None


def build_language_columns_from_header(
    header: Dict[int, str], excluded_columns: set, key_header_value: str = ""
) -> List[Tuple[int, str]]:
    groups = build_locale_groups_from_header(header, excluded_columns)
    if not groups:
        return []

    selected_prefix = resolve_locale_group_prefix(groups, key_header_value)
    return groups[selected_prefix]


def build_locale_groups_from_header(
    header: Dict[int, str], excluded_columns: set
) -> "OrderedDict[str, List[Tuple[int, str]]]":
    groups: "OrderedDict[str, List[Tuple[int, str]]]" = OrderedDict()
    seen_locales_by_prefix: Dict[str, set] = {}

    for column_number in sorted(header):
        if column_number in excluded_columns:
            continue

        parsed = parse_locale_header(header[column_number])
        if parsed is None:
            continue

        prefix, locale = parsed
        if prefix not in groups:
            groups[prefix] = []
            seen_locales_by_prefix[prefix] = set()
        if locale in seen_locales_by_prefix[prefix]:
            continue
        seen_locales_by_prefix[prefix].add(locale)
        groups[prefix].append((column_number, locale))

    return groups


def normalize_group_prefix(value: str) -> str:
    return value.strip().lower()


def display_group_prefix(value: str) -> str:
    return value or "<default>"


def find_group_prefix(groups: "OrderedDict[str, List[Tuple[int, str]]]", expected_prefix: str) -> Optional[str]:
    normalized_expected = normalize_group_prefix(expected_prefix)
    for prefix in groups:
        if normalize_group_prefix(prefix) == normalized_expected:
            return prefix
    return None


def infer_translation_group_prefix(key_header_value: str) -> Optional[str]:
    normalized = key_header_value.strip()
    if not normalized:
        return None

    match = re.search(r"[（(]\s*([^()（）]+?)\s*[）)]\s*$", normalized)
    if match is None:
        return None
    return match.group(1).strip()


def resolve_locale_group_prefix(
    groups: "OrderedDict[str, List[Tuple[int, str]]]", key_header_value: str
) -> str:
    inferred_prefix = infer_translation_group_prefix(key_header_value)
    if inferred_prefix:
        matched_prefix = find_group_prefix(groups, inferred_prefix)
        if matched_prefix is not None:
            return matched_prefix
        available_groups = ", ".join(display_group_prefix(prefix) for prefix in groups)
        raise ValueError(
            f'Could not match key header "{key_header_value}" to a translation group. '
            f"Available groups: {available_groups}."
        )

    if len(groups) == 1:
        return next(iter(groups))

    default_group = find_group_prefix(groups, "")
    if default_group is not None:
        return default_group

    for candidate in DEFAULT_PRIMARY_GROUP_NAMES:
        matched_prefix = find_group_prefix(groups, candidate)
        if matched_prefix is not None:
            return matched_prefix

    available_groups = ", ".join(display_group_prefix(prefix) for prefix in groups)
    raise ValueError(
        "Multiple translation groups were found in the sheet header. "
        f"Available groups: {available_groups}."
    )


def resolve_key_column_index(
    header: Dict[int, str],
    key_column: str,
    key_header: Optional[str],
    auto_detect_default_column: bool = False,
) -> int:
    if key_header:
        column_index = find_header_column(header, [key_header])
        if column_index is None:
            raise ValueError(f'Key header "{key_header}" was not found in the sheet header row.')
        return column_index

    requested_column_index = column_to_index(key_column)
    if not auto_detect_default_column or key_column.strip().upper() != "A":
        return requested_column_index

    requested_header = header.get(requested_column_index, "")
    if is_likely_key_header(requested_header):
        return requested_column_index

    detected_column_index = find_default_key_column(header)
    if detected_column_index is not None:
        return detected_column_index
    return requested_column_index


def is_likely_key_header(value: str) -> bool:
    normalized = normalize_header_name(value)
    if normalized in KEY_HEADER_NAMES:
        return True
    return "key" in normalized and header_to_locale(value) is None


def find_default_key_column(header: Dict[int, str]) -> Optional[int]:
    for column_number in sorted(header):
        if is_likely_key_header(header[column_number]):
            return column_number
    return None


def build_excluded_columns(*column_numbers: Optional[int]) -> set:
    return {column_number for column_number in column_numbers if column_number is not None}


def build_output_specs(args: argparse.Namespace) -> List[OutputSpec]:
    table_name = args.table_name.strip() or "Localizable"
    primary_key_header = args.key_header.strip() if args.key_header else None

    specs = [
        OutputSpec(
            table_name=table_name,
            key_column=args.key_column,
            key_header=primary_key_header or None,
            optional=False,
        )
    ]

    extra_key_header = args.extra_key_header.strip() if args.extra_key_header else ""

    if extra_key_header:
        specs.append(
            OutputSpec(
                table_name=table_name,
                key_column=None,
                key_header=extra_key_header,
                optional=True,
            )
        )

    return specs


def log_optional_output_spec_skipped(
    issue_log: Optional[IssueLog],
    output_spec: OutputSpec,
    source_name: str,
    message: str,
) -> None:
    if issue_log is not None:
        issue_log.add(
            "INFO",
            "optional_key_skipped",
            message,
            sheet=source_name,
        )
    print(f'Info: skipped optional key source "{describe_output_spec(output_spec)}" in "{source_name}"')


@dataclass(frozen=True)
class SheetProcessingPlan:
    output_spec: OutputSpec
    key_column_index: int
    language_columns: List[Tuple[int, str]]
    app_column_index: Optional[int]
    app_true_only: bool


def header_supports_app_mode(
    header: Dict[int, str],
    args: argparse.Namespace,
    output_spec: OutputSpec,
) -> bool:
    app_column_index = find_header_column(header, [args.app_column])
    if app_column_index is None:
        return False

    if output_spec.key_header:
        key_column_index = find_header_column(header, [output_spec.key_header])
    else:
        key_column_index = find_default_key_column(header)
    if key_column_index is None:
        return False

    key_header_value = header.get(key_column_index, output_spec.key_header or "")
    language_columns = build_language_columns_from_header(
        header,
        build_excluded_columns(key_column_index, app_column_index),
        key_header_value=key_header_value,
    )
    return bool(language_columns)


def should_scan_all_sheets(
    workbook: WorkbookReader,
    args: argparse.Namespace,
    primary_output_spec: OutputSpec,
) -> bool:
    if args.all_sheets_with_app:
        return True
    if not args.auto_detect_workbook_mode:
        return False

    for sheet_name in workbook.sheet_names:
        header = workbook.read_header(sheet_name, args.header_row)
        if header_supports_app_mode(header, args, primary_output_spec):
            return True
    return False


def build_sheet_processing_plans(
    header: Dict[int, str],
    args: argparse.Namespace,
    output_specs: List[OutputSpec],
    *,
    requires_app_column: bool,
    source_name: str,
    issue_log: IssueLog,
) -> List[SheetProcessingPlan]:
    app_column_index = find_header_column(header, [args.app_column])
    if requires_app_column and app_column_index is None:
        issue_log.add(
            "INFO",
            "sheet_skipped",
            f'Skipped sheet because the "{args.app_column}" column was not found.',
            sheet=source_name,
            row=args.header_row,
        )
        return []

    if args.app_true_only and not requires_app_column and app_column_index is None:
        issue_log.add(
            "WARNING",
            "missing_app_column",
            "Skipped app-only filtering because the app column was not found.",
            sheet=source_name,
            row=args.header_row,
        )
        return []

    plans: List[SheetProcessingPlan] = []
    for output_spec in output_specs:
        if requires_app_column:
            key_column_index = (
                find_header_column(header, [output_spec.key_header])
                if output_spec.key_header
                else find_default_key_column(header)
            )
        else:
            try:
                key_column_index = resolve_key_column_index(
                    header,
                    output_spec.key_column or args.key_column,
                    output_spec.key_header,
                    auto_detect_default_column=True,
                )
            except ValueError:
                if output_spec.optional:
                    log_optional_output_spec_skipped(
                        issue_log,
                        output_spec,
                        source_name,
                        f'Optional key header "{output_spec.key_header}" was not found in the sheet header row.',
                    )
                    continue
                raise

        if key_column_index is None:
            message = (
                f'Skipped sheet because the key header "{output_spec.key_header}" was not found.'
                if output_spec.key_header
                else "Skipped sheet because a recognized key column was not found."
            )
            if output_spec.optional:
                log_optional_output_spec_skipped(issue_log, output_spec, source_name, message)
            elif requires_app_column:
                issue_log.add("WARNING", "missing_key_column", message, sheet=source_name, row=args.header_row)
            else:
                raise ValueError(message)
            continue

        key_header_value = header.get(key_column_index, output_spec.key_header or "")
        language_columns = build_language_columns_from_header(
            header,
            build_excluded_columns(key_column_index, app_column_index),
            key_header_value=key_header_value,
        )
        if not language_columns:
            message = "Skipped sheet because no recognized locale columns were found."
            if output_spec.optional:
                log_optional_output_spec_skipped(issue_log, output_spec, source_name, message)
            elif requires_app_column:
                issue_log.add("WARNING", "missing_language_columns", message, sheet=source_name, row=args.header_row)
            else:
                raise ValueError("No language columns were found in the header row.")
            continue

        plans.append(
            SheetProcessingPlan(
                output_spec=output_spec,
                key_column_index=key_column_index,
                language_columns=language_columns,
                app_column_index=app_column_index,
                app_true_only=requires_app_column or args.app_true_only,
            )
        )
    return plans


def collect_entries_from_streamed_sheet(
    workbook: WorkbookReader,
    sheet_name: str,
    args: argparse.Namespace,
    output_specs: List[OutputSpec],
    *,
    requires_app_column: bool,
    entry_store: EntryStore,
    languages: List[str],
    language_set: set,
    collected_counts: Dict[OutputSpec, int],
    issue_log: IssueLog,
    progress: ConversionProgress,
) -> None:
    source_name = f"{workbook.path.name}:{sheet_name}"
    header: Optional[Dict[int, str]] = None
    plans: List[SheetProcessingPlan] = []
    rows_processed = 0
    counts = {output_spec: 0 for output_spec in output_specs}
    truthy_values = normalized_truthy_values(args.app_true_values)

    streamed_row_count = 0
    last_bytes_read = 0
    for streamed_row in workbook.iter_rows(sheet_name):
        streamed_row_count += 1
        last_bytes_read = streamed_row.bytes_read

        if streamed_row.number < args.header_row:
            pass
        elif streamed_row.number == args.header_row:
            header = streamed_row.values
            plans = build_sheet_processing_plans(
                header,
                args,
                output_specs,
                requires_app_column=requires_app_column,
                source_name=source_name,
                issue_log=issue_log,
            )
            if not plans:
                # 当前 Sheet 没有可导出的列时无需继续扫描剩余行。
                return
        elif header is None:
            message = f"Header row {args.header_row} is empty or missing."
            if requires_app_column:
                issue_log.add("WARNING", "missing_header_row", message, sheet=source_name, row=args.header_row)
                return
            raise ValueError(message)
        else:
            rows_processed += 1
            for plan in plans:
                if plan.app_true_only and not is_truthy(
                    streamed_row.values.get(plan.app_column_index, ""),
                    truthy_values,
                ):
                    continue

                key = normalize_key(streamed_row.values.get(plan.key_column_index, ""))
                if not key:
                    issue_log.add(
                        "WARNING",
                        "empty_key",
                        "Skipped row because the key column is empty after filtering.",
                        sheet=source_name,
                        row=streamed_row.number,
                        column=index_to_column(plan.key_column_index),
                        column_header=header.get(plan.key_column_index, ""),
                    )
                    continue

                localized_values: Dict[str, str] = {}
                for column_number, locale in plan.language_columns:
                    value = streamed_row.values.get(column_number, "")
                    if value != "":
                        localized_values[locale] = normalize_localized_value(value)
                if not localized_values:
                    issue_log.add(
                        "WARNING",
                        "empty_translation_row",
                        "Skipped row because all recognized locale columns are empty.",
                        sheet=source_name,
                        row=streamed_row.number,
                        column="multiple",
                        column_header=", ".join(locale for _, locale in plan.language_columns),
                        key=key,
                    )
                    continue

                for _, locale in plan.language_columns:
                    if locale not in language_set:
                        language_set.add(locale)
                        languages.append(locale)
                entry_store.merge(key, localized_values, source_name, args.conflict_policy)
                collected_counts[plan.output_spec] += 1
                counts[plan.output_spec] += 1

        if streamed_row_count % args.chunk_rows == 0:
            entry_store.commit()
            progress.update_sheet(last_bytes_read, rows_processed)

    if streamed_row_count % args.chunk_rows != 0:
        entry_store.commit()
        progress.update_sheet(last_bytes_read, rows_processed)

    if header is None:
        message = f"Header row {args.header_row} is empty or missing."
        if requires_app_column:
            issue_log.add("WARNING", "missing_header_row", message, sheet=source_name, row=args.header_row)
            return
        raise ValueError(message)

    for output_spec, count in counts.items():
        if count:
            print(
                f'Collected {count} keys from sheet "{sheet_name}" in "{workbook.path.name}" '
                f'for key source "{describe_output_spec(output_spec)}"'
            )


def collect_entries_from_inputs_streamed(
    paths: List[Path],
    args: argparse.Namespace,
    output_specs: List[OutputSpec],
    issue_log: IssueLog,
    entry_store: EntryStore,
    progress: ConversionProgress,
) -> List[str]:
    languages: List[str] = []
    language_set = set()
    collected_counts = {output_spec: 0 for output_spec in output_specs}

    for file_index, path in enumerate(paths, start=1):
        with WorkbookReader(path) as workbook:
            requires_app_column = should_scan_all_sheets(workbook, args, output_specs[0])
            sheet_names = (
                workbook.sheet_names
                if requires_app_column
                else [workbook.selected_sheet_name(args.sheet_name, args.sheet_index)]
            )
            sheet_sizes = [workbook.sheet_size(sheet_name) for sheet_name in sheet_names]
            progress.begin_file(path, file_index, sheet_names, sheet_sizes)

            for sheet_index, (sheet_name, sheet_size) in enumerate(zip(sheet_names, sheet_sizes), start=1):
                progress.begin_sheet(sheet_name, sheet_index, sheet_size)
                collect_entries_from_streamed_sheet(
                    workbook,
                    sheet_name,
                    args,
                    output_specs,
                    requires_app_column=requires_app_column,
                    entry_store=entry_store,
                    languages=languages,
                    language_set=language_set,
                    collected_counts=collected_counts,
                    issue_log=issue_log,
                    progress=progress,
                )
                progress.finish_sheet()
            progress.finish_file()

    if collected_counts[output_specs[0]] == 0:
        raise ValueError("No localization entries were collected from the provided Excel files.")
    return languages


def write_strings_files_streamed(
    output_dir: Path,
    table_name: str,
    languages: List[str],
    entry_store: EntryStore,
    progress: ConversionProgress,
    output_offset: int,
    total_output_units: int,
) -> int:
    handles: Dict[str, object] = {}
    written_paths: Dict[str, Path] = {}
    entry_count = entry_store.entry_count

    with ExitStack() as stack:
        for entry_index, (key, localized_values) in enumerate(entry_store.iter_entries(), start=1):
            for language in languages:
                value = localized_values.get(language)
                if value is None:
                    continue
                if language not in handles:
                    language_dir = output_dir / lproj_folder(language)
                    language_dir.mkdir(parents=True, exist_ok=True)
                    target_file = language_dir / f"{table_name}.strings"
                    handles[language] = stack.enter_context(target_file.open("w", encoding="utf-8"))
                    written_paths[language] = target_file
                handles[language].write(f'"{key}" = "{escape_strings_value(value)}";\n')

            if entry_index % DEFAULT_CHUNK_ROWS == 0 or entry_index == entry_count:
                progress.update_output(
                    "写入 .strings",
                    output_offset + entry_index,
                    total_output_units,
                    f"已写入 {entry_index:,}/{entry_count:,} 条本地化记录",
                )

    for target_file in written_paths.values():
        print(f"Wrote {target_file}")
    return entry_count


def write_xcstrings_streamed(
    output_dir: Path,
    table_name: str,
    languages: List[str],
    entry_store: EntryStore,
    development_language: str,
    progress: ConversionProgress,
    output_offset: int,
    total_output_units: int,
) -> int:
    target_file = output_dir / f"{table_name}.xcstrings"
    entry_count = entry_store.entry_count

    with target_file.open("w", encoding="utf-8") as output:
        output.write("{\n  \"sourceLanguage\": ")
        json.dump(normalize_language_code(development_language), output, ensure_ascii=False)
        output.write(",\n  \"strings\": {\n")

        is_first_entry = True
        for entry_index, (key, localized_values) in enumerate(entry_store.iter_entries(), start=1):
            localizations = {}
            for language in languages:
                value = localized_values.get(language)
                if value is None:
                    continue
                localizations[language] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": value,
                    }
                }
            if not localizations:
                continue
            if not is_first_entry:
                output.write(",\n")
            output.write("    ")
            json.dump(key, output, ensure_ascii=False)
            output.write(": ")
            json.dump({"localizations": localizations}, output, ensure_ascii=False, separators=(",", ":"))
            is_first_entry = False

            if entry_index % DEFAULT_CHUNK_ROWS == 0 or entry_index == entry_count:
                progress.update_output(
                    "写入 .xcstrings",
                    output_offset + entry_index,
                    total_output_units,
                    f"已写入 {entry_index:,}/{entry_count:,} 条本地化记录",
                )

        output.write("\n  },\n  \"version\": \"1.0\"\n}\n")

    print(f"Wrote {target_file}")
    return entry_count


def write_outputs_streamed(
    output_dir: Path,
    table_name: str,
    output_format: str,
    languages: List[str],
    entry_store: EntryStore,
    development_language: str,
    progress: ConversionProgress,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    output_count = int(output_format in ("strings", "both")) + int(output_format in ("xcstrings", "both"))
    total_output_units = max(entry_store.entry_count * output_count, 1)
    output_offset = 0

    if output_format in ("strings", "both"):
        output_offset += write_strings_files_streamed(
            output_dir,
            table_name,
            languages,
            entry_store,
            progress,
            output_offset,
            total_output_units,
        )
    if output_format in ("xcstrings", "both"):
        write_xcstrings_streamed(
            output_dir,
            table_name,
            languages,
            entry_store,
            development_language,
            progress,
            output_offset,
            total_output_units,
        )


@dataclass(frozen=True)
class StringsEntry:
    key: str
    key_literal: str
    value_literal: str
    value_start: int
    value_end: int


def scan_quoted_strings_literal(contents: str, start: int) -> Optional[Tuple[int, int]]:
    """返回带引号字符串的范围，兼容转义的双引号。"""
    if start >= len(contents) or contents[start] != '"':
        return None

    index = start + 1
    while index < len(contents):
        if contents[index] == "\\":
            index += 2
            continue
        if contents[index] == '"':
            return start, index + 1
        index += 1
    return None


def skip_strings_ignorable(contents: str, start: int) -> int:
    """跳过 .strings 中的空白与 C 风格注释，避免把注释内容当成键值。"""
    index = start
    while index < len(contents):
        while index < len(contents) and contents[index].isspace():
            index += 1

        if contents.startswith("/*", index):
            comment_end = contents.find("*/", index + 2)
            return len(contents) if comment_end == -1 else skip_strings_ignorable(contents, comment_end + 2)

        if contents.startswith("//", index):
            line_end = contents.find("\n", index + 2)
            return len(contents) if line_end == -1 else skip_strings_ignorable(contents, line_end + 1)

        break
    return index


def decode_strings_literal(literal: str) -> str:
    """解码 .strings 键名，只用于匹配，不会重写目标文件的键或注释。"""
    value = literal[1:-1]
    decoded: List[str] = []
    index = 0
    simple_escapes = {"n": "\n", "r": "\r", "t": "\t"}

    while index < len(value):
        char = value[index]
        if char != "\\" or index + 1 >= len(value):
            decoded.append(char)
            index += 1
            continue

        escaped = value[index + 1]
        if escaped in simple_escapes:
            decoded.append(simple_escapes[escaped])
            index += 2
            continue
        if escaped in {"u", "U"}:
            width = 4 if escaped == "u" else 8
            codepoint = value[index + 2 : index + 2 + width]
            if len(codepoint) == width and all(character in "0123456789abcdefABCDEF" for character in codepoint):
                decoded.append(chr(int(codepoint, 16)))
                index += width + 2
                continue
        decoded.append(escaped)
        index += 2
    return "".join(decoded)


def scan_strings_entries(contents: str) -> List[StringsEntry]:
    """解析 .strings 键值范围，以便仅替换值并保留项目原有注释与排版。"""
    entries: List[StringsEntry] = []
    index = 0

    while index < len(contents):
        index = skip_strings_ignorable(contents, index)
        if index >= len(contents):
            break
        if contents[index] != '"':
            index += 1
            continue

        key_range = scan_quoted_strings_literal(contents, index)
        if key_range is None:
            index += 1
            continue
        key_start, key_end = key_range

        equals_index = skip_strings_ignorable(contents, key_end)
        if equals_index >= len(contents) or contents[equals_index] != "=":
            index = key_end
            continue

        value_index = skip_strings_ignorable(contents, equals_index + 1)
        value_range = scan_quoted_strings_literal(contents, value_index)
        if value_range is None:
            index = key_end
            continue
        value_start, value_end = value_range

        semicolon_index = skip_strings_ignorable(contents, value_end)
        if semicolon_index >= len(contents) or contents[semicolon_index] != ";":
            index = key_end
            continue

        key_literal = contents[key_start:key_end]
        entries.append(
            StringsEntry(
                key=decode_strings_literal(key_literal),
                key_literal=key_literal,
                value_literal=contents[value_start:value_end],
                value_start=value_start,
                value_end=value_end,
            )
        )
        index = semicolon_index + 1

    return entries


def write_text_atomically(path: Path, contents: str) -> None:
    """先写临时文件再替换，避免合并中断时损坏项目资源文件。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial")
    try:
        temporary.write_text(contents, encoding="utf-8")
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def merge_strings_file(source_file: Path, target_file: Path) -> None:
    """将转换结果并入已有 .strings；同 key 仅替换值，其他内容原样保留。"""
    if source_file.resolve() == target_file.resolve():
        print(f"Skipped merge because source and target are the same: {target_file}")
        return

    source_contents = source_file.read_text(encoding="utf-8")
    source_entries = scan_strings_entries(source_contents)
    if not source_entries:
        raise ValueError(f"Generated strings file contains no readable entries: {source_file}")

    if not target_file.exists():
        write_text_atomically(target_file, source_contents)
        print(f"Created {target_file}")
        return

    target_contents = target_file.read_text(encoding="utf-8")
    target_entries = scan_strings_entries(target_contents)
    target_entries_by_key: Dict[str, List[StringsEntry]] = {}
    for entry in target_entries:
        target_entries_by_key.setdefault(entry.key, []).append(entry)

    source_entries_by_key: Dict[str, StringsEntry] = {}
    for entry in source_entries:
        source_entries_by_key[entry.key] = entry

    replacements: List[Tuple[int, int, str]] = []
    for key, source_entry in source_entries_by_key.items():
        for target_entry in target_entries_by_key.get(key, []):
            replacements.append((target_entry.value_start, target_entry.value_end, source_entry.value_literal))

    merged_contents = target_contents
    for value_start, value_end, replacement in reversed(replacements):
        merged_contents = merged_contents[:value_start] + replacement + merged_contents[value_end:]

    missing_entries = [
        entry for key, entry in source_entries_by_key.items() if key not in target_entries_by_key
    ]
    if missing_entries:
        if merged_contents and not merged_contents.endswith("\n"):
            merged_contents += "\n"
        if merged_contents:
            merged_contents += "\n"
        merged_contents += "/* Imported from Localization Workbench */\n"
        merged_contents += "\n".join(
            f"{entry.key_literal} = {entry.value_literal};" for entry in missing_entries
        )
        merged_contents += "\n"

    write_text_atomically(target_file, merged_contents)
    print(f"Merged {source_file} -> {target_file}")


def read_xcstrings_document(path: Path) -> Dict[str, object]:
    try:
        with path.open("r", encoding="utf-8-sig") as source:
            document = json.load(source)
    except json.JSONDecodeError as error:
        raise ValueError(f"Invalid .xcstrings JSON: {path}") from error

    if not isinstance(document, dict):
        raise ValueError(f"Invalid .xcstrings root object: {path}")
    return document


def merge_xcstrings_file(source_file: Path, target_file: Path) -> None:
    """保留项目 Catalog 的元数据，只更新云端提供的语言翻译。"""
    if source_file.resolve() == target_file.resolve():
        print(f"Skipped merge because source and target are the same: {target_file}")
        return

    source_document = read_xcstrings_document(source_file)
    source_strings = source_document.get("strings")
    if not isinstance(source_strings, dict):
        raise ValueError(f"Invalid .xcstrings strings object: {source_file}")

    if not target_file.exists():
        write_text_atomically(target_file, source_file.read_text(encoding="utf-8"))
        print(f"Created {target_file}")
        return

    target_document = read_xcstrings_document(target_file)
    target_strings = target_document.get("strings")
    if target_strings is None:
        target_strings = {}
        target_document["strings"] = target_strings
    if not isinstance(target_strings, dict):
        raise ValueError(f"Invalid .xcstrings strings object: {target_file}")

    for key, source_entry in source_strings.items():
        if not isinstance(source_entry, dict):
            continue
        target_entry = target_strings.get(key)
        if not isinstance(target_entry, dict):
            target_strings[key] = source_entry
            continue

        source_localizations = source_entry.get("localizations")
        if not isinstance(source_localizations, dict):
            continue
        target_localizations = target_entry.get("localizations")
        if target_localizations is None:
            target_localizations = {}
            target_entry["localizations"] = target_localizations
        if not isinstance(target_localizations, dict):
            raise ValueError(f"Invalid .xcstrings localizations object for key {key}: {target_file}")
        target_localizations.update(source_localizations)

    for document_key in ("sourceLanguage", "version"):
        if document_key not in target_document and document_key in source_document:
            target_document[document_key] = source_document[document_key]

    write_text_atomically(
        target_file,
        json.dumps(target_document, ensure_ascii=False, indent=2) + "\n",
    )
    print(f"Merged {source_file} -> {target_file}")


def merge_generated_outputs(
    output_dir: Path,
    target_directory: Path,
    table_name: str,
    output_format: str,
    languages: List[str],
) -> None:
    """把本次转换文件合并到用户选定的项目资源根目录。"""
    if not target_directory.is_dir():
        raise ValueError(f"Localization resource directory does not exist: {target_directory}")

    merged_file_count = 0
    if output_format in ("strings", "both"):
        for language in languages:
            source_file = output_dir / lproj_folder(language) / f"{table_name}.strings"
            if not source_file.is_file():
                continue
            target_file = target_directory / lproj_folder(language) / f"{table_name}.strings"
            merge_strings_file(source_file, target_file)
            merged_file_count += 1

    if output_format in ("xcstrings", "both"):
        source_file = output_dir / f"{table_name}.xcstrings"
        if source_file.is_file():
            merge_xcstrings_file(source_file, target_directory / source_file.name)
            merged_file_count += 1

    if merged_file_count == 0:
        raise ValueError("No generated localization files were available to merge.")
    print(f"Merged {merged_file_count} localization resource file(s) into {target_directory}")


def resolve_log_path(output_dir: Path, raw_log_file: Optional[str]) -> Path:
    if raw_log_file:
        return Path(raw_log_file)
    return output_dir / "conversion_issues.log"


def describe_output_spec(output_spec: OutputSpec) -> str:
    if output_spec.key_header:
        return output_spec.key_header
    if output_spec.key_column:
        return f"column {output_spec.key_column}"
    return output_spec.table_name


def handle_termination_signal(signum: int, frame: object) -> None:
    # 让 macOS App 的“终止”按钮走可清理的取消路径。
    raise KeyboardInterrupt


def configure_locale_registry(locale_config: Optional[Path]) -> None:
    """在处理工作簿前载入用户追加的语言别名。"""
    global _locale_registry
    _locale_registry = load_locale_registry(locale_config)


def main() -> int:
    args = parse_args()
    issue_log = IssueLog()
    log_path = resolve_log_path(args.output, args.log_file)
    progress: Optional[ConversionProgress] = None
    signal.signal(signal.SIGTERM, handle_termination_signal)

    try:
        configure_locale_registry(args.locale_config)
        if args.merge_into is not None:
            if not args.merge_into.is_dir():
                raise ValueError(f"Localization resource directory does not exist: {args.merge_into}")
            if args.output.resolve() == args.merge_into.resolve():
                raise ValueError(
                    "Conversion output directory must differ from the localization resource directory."
                )
        output_specs = build_output_specs(args)
        table_name = args.table_name.strip() or "Localizable"
        progress = ConversionProgress(args.input)
        with tempfile.TemporaryDirectory(prefix="localization-workbench-conversion-") as temporary_directory:
            entry_store = EntryStore(Path(temporary_directory), issue_log)
            try:
                languages = collect_entries_from_inputs_streamed(
                    args.input,
                    args,
                    output_specs,
                    issue_log,
                    entry_store,
                    progress,
                )
                development_language = args.development_language or languages[0]
                write_outputs_streamed(
                    output_dir=args.output,
                    table_name=table_name,
                    output_format=args.format,
                    languages=languages,
                    entry_store=entry_store,
                    development_language=development_language,
                    progress=progress,
                )
                if args.merge_into is not None:
                    merge_generated_outputs(
                        output_dir=args.output,
                        target_directory=args.merge_into,
                        table_name=table_name,
                        output_format=args.format,
                        languages=languages,
                    )
            finally:
                entry_store.close()
    except KeyboardInterrupt:
        issue_log.add("INFO", "cancelled", "Conversion was cancelled by the user.")
        issue_log.write(log_path)
        print(f"Wrote {log_path}")
        print("Conversion cancelled.")
        return 130
    except Exception as error:
        issue_log.add("ERROR", "fatal", str(error))
        issue_log.write(log_path)
        print(f"Wrote {log_path}")
        print(f"Error: {error}", file=sys.stderr)
        return 1

    issue_log.write(log_path)
    print(f"Wrote {log_path}")
    if progress is not None:
        progress.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())
