#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable
from zipfile import ZipFile
import xml.etree.ElementTree as ET


NS = {
    "main": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "pkgrel": "http://schemas.openxmlformats.org/package/2006/relationships",
}

LANGUAGE_HEADERS = {
    "英文",
    "中文",
    "日文",
    "日语",
    "土耳其语",
    "捷克语",
    "德语",
    "丹麦语",
    "西班牙语",
    "法语",
    "加拿大法语",
    "意大利语",
    "荷兰语",
    "波兰语",
    "俄语",
    "乌克兰语",
    "葡萄牙语",
    "韩语",
    "瑞典语",
}

KEY_HEADERS = {"Dev Key", "文案的key"}


@dataclass
class SheetInfo:
    name: str
    target: str


@dataclass
class Issue:
    sheet: str
    row_number: int
    key: str
    english_col: str
    language_col: str
    language_name: str
    marker_type: str
    expected_count: int
    actual_count: int
    english_text: str
    translated_text: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check whether non-English translations preserve line breaks from English in an XLSX file."
    )
    parser.add_argument(
        "workbook",
        nargs="?",
        default="多端文案统一命名规则-转换.xlsx",
        help="Path to the workbook to scan.",
    )
    parser.add_argument(
        "--output-md",
        default="newline_check_report.md",
        help="Markdown report output path.",
    )
    parser.add_argument(
        "--output-csv",
        default="newline_check_report.csv",
        help="CSV report output path.",
    )
    parser.add_argument(
        "--header-search-rows",
        type=int,
        default=20,
        help="How many top rows to scan when locating the header row.",
    )
    return parser.parse_args()


def col_to_index(col: str) -> int:
    idx = 0
    for ch in col:
        if ch.isalpha():
            idx = idx * 26 + (ord(ch.upper()) - 64)
    return idx - 1


def index_to_col(index: int) -> str:
    index += 1
    result = []
    while index:
        index, rem = divmod(index - 1, 26)
        result.append(chr(65 + rem))
    return "".join(reversed(result))


def parse_ref(ref: str) -> tuple[str, int]:
    match = re.match(r"([A-Z]+)(\d+)$", ref)
    if not match:
        raise ValueError(f"Unsupported cell reference: {ref}")
    return match.group(1), int(match.group(2))


def normalize_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n")


def preview_text(value: str, limit: int = 120) -> str:
    compact = normalize_text(value).replace("\n", "\\n")
    return compact[:limit] + ("..." if len(compact) > limit else "")


class XlsxReader:
    def __init__(self, path: Path):
        self.path = path
        self.zip = ZipFile(path)
        self.shared_strings = self._load_shared_strings()
        self.sheets = self._load_sheets()

    def close(self) -> None:
        self.zip.close()

    def _load_shared_strings(self) -> list[str]:
        shared = []
        if "xl/sharedStrings.xml" not in self.zip.namelist():
            return shared

        root = ET.fromstring(self.zip.read("xl/sharedStrings.xml"))
        for si in root.findall("main:si", NS):
            shared.append("".join(t.text or "" for t in si.iterfind(".//main:t", NS)))
        return shared

    def _load_sheets(self) -> list[SheetInfo]:
        workbook = ET.fromstring(self.zip.read("xl/workbook.xml"))
        rels = ET.fromstring(self.zip.read("xl/_rels/workbook.xml.rels"))
        rel_map = {
            rel.attrib["Id"]: rel.attrib["Target"]
            for rel in rels.findall("pkgrel:Relationship", NS)
        }

        sheets = []
        for sheet in workbook.find("main:sheets", NS):
            rel_id = sheet.attrib[
                "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
            ]
            sheets.append(SheetInfo(sheet.attrib["name"], "xl/" + rel_map[rel_id]))
        return sheets

    def iter_sheet_rows(self, target: str) -> Iterable[tuple[int, dict[str, str]]]:
        root = ET.fromstring(self.zip.read(target))
        rows = root.findall(".//main:sheetData/main:row", NS)
        for row in rows:
            row_number = int(row.attrib["r"])
            values = {}
            for cell in row.findall("main:c", NS):
                col, _ = parse_ref(cell.attrib["r"])
                values[col] = self._read_cell(cell)
            yield row_number, values

    def _read_cell(self, cell: ET.Element) -> str:
        cell_type = cell.attrib.get("t")
        value_node = cell.find("main:v", NS)
        if cell_type == "s" and value_node is not None and value_node.text is not None:
            return self.shared_strings[int(value_node.text)]
        if cell_type == "inlineStr":
            return "".join(t.text or "" for t in cell.findall(".//main:t", NS))
        if value_node is not None and value_node.text is not None:
            return value_node.text
        return ""


def find_header_row(
    rows: list[tuple[int, dict[str, str]]], search_limit: int
) -> tuple[int, dict[str, str], str] | None:
    candidates = []
    for row_number, row in rows[:search_limit]:
        english_cols = [col for col, value in row.items() if value == "英文"]
        if not english_cols:
            continue
        lang_count = sum(1 for value in row.values() if value in LANGUAGE_HEADERS)
        candidates.append((lang_count, row_number, row, english_cols[0]))
    if not candidates:
        return None
    _, row_number, row, english_col = max(candidates, key=lambda item: (item[0], -item[1]))
    return row_number, row, english_col


def find_key_column(header_row: dict[str, str], english_col: str) -> str:
    left_side = sorted(
        (col for col in header_row if col_to_index(col) < col_to_index(english_col)),
        key=col_to_index,
    )
    for col in left_side:
        if header_row[col] in KEY_HEADERS:
            return col
    return left_side[0] if left_side else "A"


def language_columns(header_row: dict[str, str], english_col: str) -> list[tuple[str, str]]:
    columns = []
    for col, name in sorted(header_row.items(), key=lambda item: col_to_index(item[0])):
        if col == english_col:
            continue
        if name in LANGUAGE_HEADERS and name != "英文":
            columns.append((col, name))
    return columns


def marker_counts(text: str) -> Counter[str]:
    normalized = normalize_text(text)
    return Counter(
        {
            "literal_\\n": normalized.count("\\n"),
            "actual_newline": normalized.count("\n"),
            "any_newline_marker": normalized.count("\\n") + normalized.count("\n"),
        }
    )


def scan_workbook(path: Path, header_search_rows: int) -> tuple[list[Issue], dict[str, object]]:
    reader = XlsxReader(path)
    issues: list[Issue] = []
    sheets_scanned = []
    sheets_without_english = []
    rows_with_english_markers = 0
    rows_with_issues = set()
    marker_totals = Counter()

    try:
        for sheet in reader.sheets:
            rows = list(reader.iter_sheet_rows(sheet.target))
            header = find_header_row(rows, header_search_rows)
            if not header:
                sheets_without_english.append(sheet.name)
                continue

            header_row_number, header_row, english_col = header
            key_col = find_key_column(header_row, english_col)
            lang_cols = language_columns(header_row, english_col)
            sheets_scanned.append(
                {
                    "sheet": sheet.name,
                    "header_row": header_row_number,
                    "english_col": english_col,
                    "key_col": key_col,
                    "language_count": len(lang_cols),
                }
            )

            for row_number, row in rows:
                if row_number <= header_row_number:
                    continue

                english_text = row.get(english_col, "")
                if not english_text:
                    continue

                english_markers = marker_counts(english_text)
                relevant_markers = {}
                if english_markers["literal_\\n"] > 0:
                    # Prefer the explicit escape sequence when it exists. Some cells are formatted
                    # with visual line wraps around the `\n` token, which should not be treated as
                    # an additional translation requirement.
                    relevant_markers["literal_\\n"] = english_markers["literal_\\n"]
                elif english_markers["actual_newline"] > 0:
                    # If English only contains actual line breaks, accept either actual breaks or
                    # escaped `\n` in translations as long as the total count matches.
                    relevant_markers["any_newline_marker"] = english_markers["actual_newline"]
                if not relevant_markers:
                    continue

                rows_with_english_markers += 1
                marker_totals.update(relevant_markers)
                row_key = row.get(key_col, "")

                for lang_col, lang_name in lang_cols:
                    translated_text = row.get(lang_col, "")
                    translated_markers = marker_counts(translated_text)
                    for marker_name, expected_count in relevant_markers.items():
                        actual_count = translated_markers.get(marker_name, 0)
                        if actual_count == expected_count:
                            continue
                        issues.append(
                            Issue(
                                sheet=sheet.name,
                                row_number=row_number,
                                key=row_key,
                                english_col=english_col,
                                language_col=lang_col,
                                language_name=lang_name,
                                marker_type=marker_name,
                                expected_count=expected_count,
                                actual_count=actual_count,
                                english_text=english_text,
                                translated_text=translated_text,
                            )
                        )
                        rows_with_issues.add((sheet.name, row_number))
    finally:
        reader.close()

    summary = {
        "workbook": str(path),
        "sheets_scanned": sheets_scanned,
        "sheets_without_english": sheets_without_english,
        "rows_with_english_markers": rows_with_english_markers,
        "rows_with_issues": len(rows_with_issues),
        "total_issues": len(issues),
        "marker_totals": dict(marker_totals),
    }
    return issues, summary


def write_csv(path: Path, issues: list[Issue]) -> None:
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "sheet",
                "row_number",
                "key",
                "language_name",
                "language_col",
                "marker_type",
                "expected_count",
                "actual_count",
                "english_preview",
                "translation_preview",
            ]
        )
        for issue in issues:
            writer.writerow(
                [
                    issue.sheet,
                    issue.row_number,
                    issue.key,
                    issue.language_name,
                    issue.language_col,
                    issue.marker_type,
                    issue.expected_count,
                    issue.actual_count,
                    preview_text(issue.english_text, 200),
                    preview_text(issue.translated_text, 200),
                ]
            )


def write_markdown(path: Path, issues: list[Issue], summary: dict[str, object]) -> None:
    by_sheet = defaultdict(list)
    for issue in issues:
        by_sheet[issue.sheet].append(issue)

    lines = [
        "# Excel Newline Check Report",
        "",
        f"- Generated at: {datetime.now().isoformat(timespec='seconds')}",
        f"- Workbook: `{summary['workbook']}`",
        f"- Sheets scanned: {len(summary['sheets_scanned'])}",
        f"- Sheets skipped without English baseline: {len(summary['sheets_without_english'])}",
        f"- English rows containing newline markers: {summary['rows_with_english_markers']}",
        f"- Rows with mismatches: {summary['rows_with_issues']}",
        f"- Total mismatch records: {summary['total_issues']}",
        "",
        "## Marker Summary",
        "",
    ]

    marker_totals = summary["marker_totals"]
    if marker_totals:
        for marker_name, count in marker_totals.items():
            lines.append(f"- `{marker_name}` in English: {count}")
    else:
        lines.append("- No newline markers were found in English cells.")

    lines.extend(["", "## Scanned Sheets", ""])
    for item in summary["sheets_scanned"]:
        lines.append(
            f"- `{item['sheet']}`: header row {item['header_row']}, English column `{item['english_col']}`, "
            f"key column `{item['key_col']}`, language columns {item['language_count']}"
        )

    if summary["sheets_without_english"]:
        lines.extend(["", "## Skipped Sheets", ""])
        for sheet_name in summary["sheets_without_english"]:
            lines.append(f"- `{sheet_name}`")

    lines.extend(["", "## Mismatches", ""])
    if not issues:
        lines.append("- No mismatches found.")
    else:
        for sheet_name in sorted(by_sheet):
            sheet_issues = sorted(
                by_sheet[sheet_name],
                key=lambda item: (item.row_number, col_to_index(item.language_col), item.marker_type),
            )
            lines.extend(["", f"### {sheet_name}", ""])
            for issue in sheet_issues:
                lines.append(
                    f"- Row {issue.row_number}, key `{issue.key or '(empty)'}`, language `{issue.language_name}` "
                    f"(`{issue.language_col}`), marker `{issue.marker_type}`: expected {issue.expected_count}, "
                    f"actual {issue.actual_count}. "
                    f"English: `{preview_text(issue.english_text)}` | "
                    f"Translation: `{preview_text(issue.translated_text)}`"
                )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    workbook_path = Path(args.workbook).expanduser().resolve()
    output_md = Path(args.output_md).expanduser().resolve()
    output_csv = Path(args.output_csv).expanduser().resolve()

    issues, summary = scan_workbook(workbook_path, args.header_search_rows)
    write_markdown(output_md, issues, summary)
    write_csv(output_csv, issues)

    print(f"Workbook: {workbook_path}")
    print(f"Markdown report: {output_md}")
    print(f"CSV report: {output_csv}")
    print(f"Rows with English newline markers: {summary['rows_with_english_markers']}")
    print(f"Rows with issues: {summary['rows_with_issues']}")
    print(f"Total issue records: {summary['total_issues']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
