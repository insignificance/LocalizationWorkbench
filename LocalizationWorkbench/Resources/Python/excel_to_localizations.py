#!/usr/bin/env python3
# python3 excel_to_localizations.py './多端文案统一命名规则-转换.xlsx' './iOS文案补充
#  20260325.xlsx' './output_all_excels_20260326_165140' --format strings --all-sheets-with-app
#  

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from collections import OrderedDict
from pathlib import Path
from typing import Dict, List, Optional, Tuple


NS = {
    "main": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
    "office_rel": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}

HEADER_LOCALE_ALIASES = {
    "-英文": "en",
    "英文": "en",
    "EN": "en",
    "English": "en",
    "en": "en",
    "中文": "zh-Hans",
    "日文": "ja",
    "日语": "ja",
    "日本語": "ja",
    "德语": "de",
    "德文": "de",
    "法语": "fr",
    "加拿大法语": "fr-CA",
    "意大利语": "it",
    "西班牙语": "es",
    "葡萄牙语": "pt-PT",
    "荷兰语": "nl",
    "波兰语": "pl",
    "俄语": "ru",
    "乌克兰语": "uk",
    "韩语": "ko",
    "韩文": "ko",
    "丹麦语": "da",
    "捷克语": "cs",
    "土耳其语": "tr",
    "瑞典语": "sv",
}

NON_LOCALE_HEADER_NAMES = {
    "app",
    "vision",
    "remark",
    "remarks",
    "comment",
    "comments",
    "note",
    "notes",
    "备注",
}

DEFAULT_TRUE_VALUES = {"true", "1", "yes", "y"}
ESCAPED_VALUE_PATTERN = re.compile(r'\\(?:[nrt"\'\\]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})')


class IssueLog:
    def __init__(self) -> None:
        self.items: List[Dict[str, str]] = []

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
        entry: Dict[str, str] = {
            "level": level.upper(),
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

        level_counts = Counter(item["level"] for item in self.items)
        lines = [
            "Excel To iOS Localizations Log",
            "",
            f"Total issues: {len(self.items)}",
            f"ERROR: {level_counts.get('ERROR', 0)}",
            f"WARNING: {level_counts.get('WARNING', 0)}",
            f"INFO: {level_counts.get('INFO', 0)}",
            "",
        ]

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
        "--table-name",
        default="Localizable",
        help="Base filename for output. Default: Localizable.",
    )
    parser.add_argument(
        "--development-language",
        help="Override the source language for .xcstrings. Defaults to the first language column.",
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
    return parser.parse_args()


def read_xlsx(path: Path, sheet_name: Optional[str], sheet_index: int) -> Dict[int, Dict[int, str]]:
    if path.suffix.lower() != ".xlsx":
        raise ValueError("Only .xlsx input is supported.")

    with zipfile.ZipFile(path) as workbook_zip:
        shared_strings = read_shared_strings(workbook_zip)
        sheet_path = resolve_sheet_path(workbook_zip, sheet_name, sheet_index)
        sheet_xml = workbook_zip.read(sheet_path)
        sheet_root = ET.fromstring(sheet_xml)

    rows: Dict[int, Dict[int, str]] = {}
    for row in sheet_root.findall(".//main:sheetData/main:row", NS):
        row_number = int(row.attrib["r"])
        row_values: Dict[int, str] = {}
        for cell in row.findall("main:c", NS):
            ref = cell.attrib.get("r", "")
            if not ref:
                continue
            column_letters = re.sub(r"\d", "", ref)
            column_number = column_to_index(column_letters)
            row_values[column_number] = read_cell_value(cell, shared_strings).strip()
        rows[row_number] = row_values
    return rows


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


def resolve_sheet_path(
    workbook_zip: zipfile.ZipFile, sheet_name: Optional[str], sheet_index: int
) -> str:
    workbook_root, rels_root, sheets = load_workbook_metadata(workbook_zip)
    if not sheets:
        raise ValueError("Workbook does not contain any sheets.")

    selected_sheet = None
    if sheet_name:
        for sheet in sheets:
            if sheet.attrib.get("name") == sheet_name:
                selected_sheet = sheet
                break
        if selected_sheet is None:
            raise ValueError(f'Sheet "{sheet_name}" was not found.')
    else:
        if sheet_index < 0 or sheet_index >= len(sheets):
            raise ValueError(f"Sheet index {sheet_index} is out of range.")
        selected_sheet = sheets[sheet_index]

    relationship_id = selected_sheet.attrib.get(f"{{{NS['office_rel']}}}id")
    if not relationship_id:
        raise ValueError("Selected sheet is missing a relationship id.")

    for relation in rels_root.findall("rel:Relationship", NS):
        if relation.attrib.get("Id") == relationship_id:
            target = relation.attrib["Target"]
            return normalize_zip_path("xl", target)

    raise ValueError("Could not resolve selected sheet path.")


def load_workbook_metadata(
    workbook_zip: zipfile.ZipFile,
) -> Tuple[ET.Element, ET.Element, List[ET.Element]]:
    workbook_root = ET.fromstring(workbook_zip.read("xl/workbook.xml"))
    rels_root = ET.fromstring(workbook_zip.read("xl/_rels/workbook.xml.rels"))
    sheets = workbook_root.findall("main:sheets/main:sheet", NS)
    return workbook_root, rels_root, sheets


def list_sheet_names(path: Path) -> List[str]:
    with zipfile.ZipFile(path) as workbook_zip:
        _, _, sheets = load_workbook_metadata(workbook_zip)
    return [sheet.attrib.get("name", "") for sheet in sheets]


def normalize_zip_path(base: str, target: str) -> str:
    parts: List[str] = []
    for part in f"{base}/{target}".split("/"):
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


def normalize_language_code(value: str) -> str:
    cleaned = value.strip().replace("_", "-")
    if not cleaned:
        raise ValueError("Language code cannot be empty.")

    parts = cleaned.split("-")
    if len(parts) == 1:
        return parts[0].lower()

    normalized = [parts[0].lower()]
    for part in parts[1:]:
        normalized.append(part.upper() if len(part) in (2, 3) else part)
    return "-".join(normalized)


def header_to_locale(value: str) -> Optional[str]:
    normalized = value.strip()
    if not normalized:
        return None
    if normalized in HEADER_LOCALE_ALIASES:
        return HEADER_LOCALE_ALIASES[normalized]

    candidate = normalized.lstrip("-")
    if candidate.lower() in NON_LOCALE_HEADER_NAMES:
        return None
    if re.fullmatch(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*", candidate):
        if (
            "-" not in candidate
            and "_" not in candidate
            and len(candidate) == 3
            and not (candidate.islower() or candidate.isupper())
        ):
            return None
        return normalize_language_code(candidate)
    return None


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


def parse_rows(
    rows: Dict[int, Dict[int, str]],
    header_row: int,
    key_column: str,
    issue_log: Optional[IssueLog] = None,
    sheet_name: Optional[str] = None,
) -> Tuple[List[str], List[Tuple[str, Dict[str, str]]]]:
    header = rows.get(header_row)
    if not header:
        raise ValueError(f"Header row {header_row} is empty or missing.")

    key_column_index = column_to_index(key_column)

    languages: List[str] = []
    language_columns: List[Tuple[int, str]] = []
    for column_number in sorted(header):
        if column_number == key_column_index:
            continue
        raw_language = header[column_number].strip()
        language = header_to_locale(raw_language)
        if language is None:
            continue
        languages.append(language)
        language_columns.append((column_number, language))

    if not languages:
        raise ValueError("No language columns were found in the header row.")

    ordered_rows: List[Tuple[str, Dict[str, str]]] = []
    seen_keys = set()
    for row_number in sorted(number for number in rows if number > header_row):
        row = rows[row_number]
        key = normalize_key(row.get(key_column_index, ""))
        if not key:
            if issue_log is not None:
                issue_log.add(
                    "WARNING",
                    "empty_key",
                    "Skipped row because the key column is empty.",
                    sheet=sheet_name,
                    row=row_number,
                    column=index_to_column(key_column_index),
                    column_header=rows.get(header_row, {}).get(key_column_index, ""),
                )
            continue
        if key in seen_keys:
            raise ValueError(f'Duplicate localization key "{key}" found on row {row_number}.')
        seen_keys.add(key)

        values: Dict[str, str] = {}
        for column_number, language in language_columns:
            value = row.get(column_number, "")
            if value != "":
                values[language] = normalize_localized_value(value)
        if not values and issue_log is not None:
            issue_log.add(
                "WARNING",
                "empty_translation_row",
                "Skipped row because all recognized locale columns are empty.",
                sheet=sheet_name,
                row=row_number,
                column="multiple",
                column_header=", ".join(locale for _, locale in language_columns),
                key=key,
            )
            continue
        ordered_rows.append((key, values))

    if not ordered_rows:
        raise ValueError("No localization rows were found below the header row.")

    return languages, ordered_rows


def normalized_truthy_values(raw_values: str) -> set:
    parsed = {value.strip().lower() for value in raw_values.split(",") if value.strip()}
    return parsed or DEFAULT_TRUE_VALUES


def is_truthy(value: str, truthy_values: set) -> bool:
    return value.strip().lower() in truthy_values


def find_header_column(header: Dict[int, str], expected_names: List[str]) -> Optional[int]:
    normalized_targets = {name.strip().lower() for name in expected_names}
    for column_number, value in header.items():
        if value.strip().lower() in normalized_targets:
            return column_number
    return None


def build_language_columns_from_header(
    header: Dict[int, str], excluded_columns: set
) -> List[Tuple[int, str]]:
    result: List[Tuple[int, str]] = []
    seen = set()
    for column_number in sorted(header):
        if column_number in excluded_columns:
            continue
        locale = header_to_locale(header[column_number])
        if locale is None or locale in seen:
            continue
        seen.add(locale)
        result.append((column_number, locale))
    return result


def collect_entries_from_sheet(
    rows: Dict[int, Dict[int, str]],
    header_row: int,
    key_column_index: int,
    language_columns: List[Tuple[int, str]],
    app_column_index: Optional[int],
    truthy_values: set,
    app_true_only: bool,
    issue_log: Optional[IssueLog] = None,
    sheet_name: Optional[str] = None,
) -> List[Tuple[str, Dict[str, str]]]:
    entries: List[Tuple[str, Dict[str, str]]] = []
    if app_true_only and app_column_index is None:
        if issue_log is not None:
            issue_log.add(
                "WARNING",
                "missing_app_column",
                "Skipped app-only filtering because the app column was not found.",
                sheet=sheet_name,
            )
        return entries

    for row_number in sorted(number for number in rows if number > header_row):
        row = rows[row_number]
        if app_true_only:
            if not is_truthy(row.get(app_column_index, ""), truthy_values):
                continue

        key = normalize_key(row.get(key_column_index, ""))
        if not key:
            if issue_log is not None:
                issue_log.add(
                    "WARNING",
                    "empty_key",
                    "Skipped row because the key column is empty after filtering.",
                    sheet=sheet_name,
                    row=row_number,
                    column=index_to_column(key_column_index),
                    column_header=rows.get(header_row, {}).get(key_column_index, ""),
                )
            continue

        values: Dict[str, str] = {}
        for column_number, locale in language_columns:
            value = row.get(column_number, "")
            if value != "":
                values[locale] = normalize_localized_value(value)
        if values:
            entries.append((key, values))
        elif issue_log is not None:
            issue_log.add(
                "WARNING",
                "empty_translation_row",
                "Skipped row because all recognized locale columns are empty.",
                sheet=sheet_name,
                row=row_number,
                column="multiple",
                column_header=", ".join(locale for _, locale in language_columns),
                key=key,
            )
    return entries


def merge_entries(
    merged: Dict[str, Dict[str, str]],
    entries: List[Tuple[str, Dict[str, str]]],
    source_name: str,
    conflict_policy: str,
    issue_log: Optional[IssueLog] = None,
) -> None:
    for key, localized_values in entries:
        if key not in merged:
            merged[key] = dict(localized_values)
            continue

        existing = merged[key]
        for locale, value in localized_values.items():
            if locale not in existing:
                existing[locale] = value
                continue
            if existing[locale] != value:
                if conflict_policy == "error":
                    if issue_log is not None:
                        issue_log.add(
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
                    message = (
                        f'Replaced earlier value for locale "{locale}" with the value from sheet "{source_name}".'
                    )
                    print(f'Warning: replacing key "{key}" locale "{locale}" with value from sheet "{source_name}"')
                    if issue_log is not None:
                        issue_log.add(
                            "WARNING",
                            "conflicting_value",
                            message,
                            sheet=source_name,
                            column="locale",
                            column_header=locale,
                            key=key,
                        )
                    existing[locale] = value
                    continue
                message = (
                    f'Kept earlier value for locale "{locale}" and ignored the value from sheet "{source_name}".'
                )
                print(
                    f'Warning: keeping earlier value for key "{key}" locale "{locale}", ignoring sheet "{source_name}"'
                )
                if issue_log is not None:
                    issue_log.add(
                        "WARNING",
                        "conflicting_value",
                        message,
                        sheet=source_name,
                        column="locale",
                        column_header=locale,
                        key=key,
                    )


def collect_entries_from_workbook(
    path: Path,
    header_row: int,
    app_column_name: str,
    truthy_values: set,
    conflict_policy: str,
    issue_log: Optional[IssueLog] = None,
) -> Tuple[List[str], List[Tuple[str, Dict[str, str]]]]:
    merged: Dict[str, Dict[str, str]] = {}
    all_languages = set()

    for sheet_name in list_sheet_names(path):
        rows = read_xlsx(path, sheet_name, 0)
        source_name = f"{path.name}:{sheet_name}"
        header = rows.get(header_row, {})
        if not header:
            if issue_log is not None:
                issue_log.add(
                    "WARNING",
                    "missing_header_row",
                    f"Skipped sheet because header row {header_row} is empty or missing.",
                    sheet=source_name,
                    row=header_row,
                )
            continue

        app_column_index = find_header_column(header, [app_column_name])
        if app_column_index is None:
            if issue_log is not None:
                issue_log.add(
                    "INFO",
                    "sheet_skipped",
                    f'Skipped sheet because the "{app_column_name}" column was not found.',
                    sheet=source_name,
                    row=header_row,
                )
            continue

        key_column_index = find_header_column(header, ["Dev Key", "文案的key", "id", "错误码"])
        if key_column_index is None:
            if issue_log is not None:
                issue_log.add(
                    "WARNING",
                    "missing_key_column",
                    "Skipped sheet because a recognized key column was not found.",
                    sheet=source_name,
                    row=header_row,
                )
            continue

        language_columns = build_language_columns_from_header(
            header, {key_column_index, app_column_index}
        )
        if not language_columns:
            if issue_log is not None:
                issue_log.add(
                    "WARNING",
                    "missing_language_columns",
                    "Skipped sheet because no recognized locale columns were found.",
                    sheet=source_name,
                    row=header_row,
                )
            continue

        entries = collect_entries_from_sheet(
            rows=rows,
            header_row=header_row,
            key_column_index=key_column_index,
            language_columns=language_columns,
            app_column_index=app_column_index,
            truthy_values=truthy_values,
            app_true_only=True,
            issue_log=issue_log,
            sheet_name=source_name,
        )
        if not entries:
            if issue_log is not None:
                issue_log.add(
                    "INFO",
                    "no_matching_rows",
                    "No rows matched the app filter or usable translation content.",
                    sheet=source_name,
                )
            continue

        all_languages.update(locale for _, locale in language_columns)
        merge_entries(merged, entries, source_name, conflict_policy, issue_log)
        print(f'Collected {len(entries)} keys from sheet "{sheet_name}" in "{path.name}"')

    if not merged:
        raise ValueError("No matching rows were found in sheets with an app column.")

    ordered_languages = sorted(all_languages)
    ordered_entries = sorted(merged.items(), key=lambda item: item[0])
    return ordered_languages, ordered_entries


def workbook_supports_app_mode(path: Path, header_row: int, app_column_name: str) -> bool:
    for sheet_name in list_sheet_names(path):
        rows = read_xlsx(path, sheet_name, 0)
        header = rows.get(header_row, {})
        if not header:
            continue

        app_column_index = find_header_column(header, [app_column_name])
        if app_column_index is None:
            continue

        key_column_index = find_header_column(header, ["Dev Key", "文案的key", "id", "错误码"])
        if key_column_index is None:
            continue

        language_columns = build_language_columns_from_header(
            header, {key_column_index, app_column_index}
        )
        if language_columns:
            return True

    return False


def build_strings_files(
    languages: List[str], entries: List[Tuple[str, Dict[str, str]]]
) -> Dict[str, str]:
    output: Dict[str, List[str]] = {language: [] for language in languages}
    for key, localized_values in entries:
        for language in languages:
            value = localized_values.get(language)
            if value is None:
                continue
            output[language].append(f'"{key}" = "{escape_strings_value(value)}";')

    return {
        language: ("\n".join(lines) + ("\n" if lines else ""))
        for language, lines in output.items()
    }


def build_xcstrings(
    languages: List[str],
    entries: List[Tuple[str, Dict[str, str]]],
    development_language: str,
) -> Dict[str, object]:
    strings: Dict[str, object] = {}
    for key, localized_values in entries:
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
        if localizations:
            strings[key] = {"localizations": localizations}

    return {
        "sourceLanguage": normalize_language_code(development_language),
        "strings": strings,
        "version": "1.0",
    }


def write_outputs(
    output_dir: Path,
    table_name: str,
    output_format: str,
    languages: List[str],
    entries: List[Tuple[str, Dict[str, str]]],
    development_language: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    if output_format in ("strings", "both"):
        strings_files = build_strings_files(languages, entries)
        for language, content in strings_files.items():
            if not content:
                continue
            language_dir = output_dir / lproj_folder(language)
            language_dir.mkdir(parents=True, exist_ok=True)
            target_file = language_dir / f"{table_name}.strings"
            target_file.write_text(content, encoding="utf-8")
            print(f"Wrote {target_file}")

    if output_format in ("xcstrings", "both"):
        xcstrings_content = build_xcstrings(languages, entries, development_language)
        target_file = output_dir / f"{table_name}.xcstrings"
        target_file.write_text(
            json.dumps(xcstrings_content, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Wrote {target_file}")


def resolve_log_path(output_dir: Path, raw_log_file: Optional[str]) -> Path:
    if raw_log_file:
        return Path(raw_log_file)
    return output_dir / "conversion_issues.log"


def merge_language_lists(existing: List[str], incoming: List[str]) -> List[str]:
    ordered = list(existing)
    seen = set(existing)
    for language in incoming:
        if language in seen:
            continue
        ordered.append(language)
        seen.add(language)
    return ordered


def resolve_selected_sheet_label(path: Path, sheet_name: Optional[str], sheet_index: int) -> str:
    if sheet_name:
        return f"{path.name}:{sheet_name}"

    sheet_names = list_sheet_names(path)
    if sheet_index < 0 or sheet_index >= len(sheet_names):
        raise ValueError(f"Sheet index {sheet_index} is out of range for file {path}.")
    return f"{path.name}:{sheet_names[sheet_index]}"


def collect_entries_from_file(
    path: Path, args: argparse.Namespace, issue_log: Optional[IssueLog] = None
) -> Tuple[List[str], List[Tuple[str, Dict[str, str]]]]:
    truthy_values = normalized_truthy_values(args.app_true_values)
    use_workbook_mode = args.all_sheets_with_app
    if not use_workbook_mode and args.auto_detect_workbook_mode:
        use_workbook_mode = workbook_supports_app_mode(
            path=path,
            header_row=args.header_row,
            app_column_name=args.app_column,
        )

    if use_workbook_mode:
        return collect_entries_from_workbook(
            path=path,
            header_row=args.header_row,
            app_column_name=args.app_column,
            truthy_values=truthy_values,
            conflict_policy=args.conflict_policy,
            issue_log=issue_log,
        )

    rows = read_xlsx(path, args.sheet_name, args.sheet_index)
    sheet_label = resolve_selected_sheet_label(path, args.sheet_name, args.sheet_index)
    languages, entries = parse_rows(
        rows,
        args.header_row,
        args.key_column,
        issue_log=issue_log,
        sheet_name=sheet_label,
    )
    if not args.app_true_only:
        return languages, entries

    header = rows.get(args.header_row, {})
    key_column_index = column_to_index(args.key_column)
    app_column_index = find_header_column(header, [args.app_column])
    language_columns = build_language_columns_from_header(
        header, {key_column_index, app_column_index}
    )
    filtered_entries = collect_entries_from_sheet(
        rows=rows,
        header_row=args.header_row,
        key_column_index=key_column_index,
        language_columns=language_columns,
        app_column_index=app_column_index,
        truthy_values=truthy_values,
        app_true_only=True,
        issue_log=issue_log,
        sheet_name=sheet_label,
    )
    return languages, filtered_entries


def collect_entries_from_inputs(
    paths: List[Path], args: argparse.Namespace, issue_log: Optional[IssueLog] = None
) -> Tuple[List[str], List[Tuple[str, Dict[str, str]]]]:
    merged_entries: Dict[str, Dict[str, str]] = {}
    languages: List[str] = []

    for path in paths:
        file_languages, file_entries = collect_entries_from_file(path, args, issue_log)
        languages = merge_language_lists(languages, file_languages)
        merge_entries(merged_entries, file_entries, path.name, args.conflict_policy, issue_log)
        print(f'Collected {len(file_entries)} keys from file "{path.name}"')

    if not merged_entries:
        raise ValueError("No localization entries were collected from the provided Excel files.")

    ordered_entries = sorted(merged_entries.items(), key=lambda item: item[0])
    return languages, ordered_entries


def main() -> int:
    args = parse_args()
    issue_log = IssueLog()
    log_path = resolve_log_path(args.output, args.log_file)

    try:
        languages, entries = collect_entries_from_inputs(args.input, args, issue_log)
        development_language = args.development_language or languages[0]
        write_outputs(
            output_dir=args.output,
            table_name=args.table_name,
            output_format=args.format,
            languages=languages,
            entries=entries,
            development_language=development_language,
        )
    except Exception as error:
        issue_log.add("ERROR", "fatal", str(error))
        issue_log.write(log_path)
        print(f"Wrote {log_path}")
        print(f"Error: {error}", file=sys.stderr)
        return 1

    issue_log.write(log_path)
    print(f"Wrote {log_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
