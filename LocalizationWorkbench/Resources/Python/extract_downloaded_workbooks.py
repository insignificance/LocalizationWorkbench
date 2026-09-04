#!/usr/bin/env python3
"""从钉钉导出包中安全提取并校验 Excel 工作簿。"""

# Author: Renogy_YX

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Optional
from zipfile import BadZipFile, ZipFile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract validated .xlsx files from a downloaded archive.")
    parser.add_argument("archive", type=Path, help="Downloaded Excel file or ZIP archive.")
    parser.add_argument("destination", type=Path, help="Directory receiving extracted workbooks.")
    parser.add_argument("source_key", help="Stable identifier for one cloud export target.")
    parser.add_argument("preferred_name", help="Readable workbook name shown in the download directory.")
    return parser.parse_args()


def is_xlsx_archive(archive: ZipFile) -> bool:
    """xlsx 本质是 ZIP，使用 OOXML 必需文件避免把普通 ZIP 当成工作簿。"""
    names = {entry.filename for entry in archive.infolist()}
    return "[Content_Types].xml" in names and "xl/workbook.xml" in names


def safe_file_name(raw_name: str) -> str:
    stem = Path(raw_name).stem.strip()
    normalized = re.sub(r"[^\w.() -]+", "_", stem, flags=re.UNICODE).strip("._ ")
    return normalized or "DingTalkExport"


def stable_name_prefix(source_key: str, preferred_name: str) -> str:
    """显示名便于识别，短哈希确保同名但不同云端表格不会互相覆盖。"""
    digest = hashlib.sha256(source_key.encode("utf-8")).hexdigest()[:12]
    return f"{safe_file_name(preferred_name)}--{digest}"


def planned_destination_name(
    prefix: str,
    member_name: Optional[str] = None,
    occurrence: int = 1,
) -> str:
    stem = prefix if member_name is None else f"{prefix}--{safe_file_name(member_name)}"
    if occurrence > 1:
        stem = f"{stem}-{occurrence}"
    return f"{stem}.xlsx"


def verify_xlsx_file(path: Path) -> bool:
    try:
        with ZipFile(path) as workbook:
            return is_xlsx_archive(workbook)
    except BadZipFile:
        return False


def copy_workbook(source: Path, destination: Path) -> Path:
    temporary = destination.with_suffix(".partial")
    shutil.copyfile(source, temporary)
    if not verify_xlsx_file(temporary):
        temporary.unlink(missing_ok=True)
        raise ValueError("下载内容不是有效的 .xlsx 工作簿")
    temporary.replace(destination)
    return destination


def extract_workbooks(
    archive_path: Path,
    destination_directory: Path,
    source_key: str,
    preferred_name: str,
) -> list[Path]:
    if not archive_path.is_file():
        raise FileNotFoundError(f"下载文件不存在：{archive_path}")

    destination_directory.mkdir(parents=True, exist_ok=True)
    name_prefix = stable_name_prefix(source_key, preferred_name)
    try:
        with ZipFile(archive_path) as archive:
            # 若下载结果本身就是 xlsx，直接复制，不把内部 XML 文件误当成导出包内容。
            if is_xlsx_archive(archive):
                destination = destination_directory / planned_destination_name(name_prefix)
                extracted = [copy_workbook(archive_path, destination)]
            else:
                members = [
                    entry
                    for entry in archive.infolist()
                    if not entry.is_dir() and Path(entry.filename).suffix.lower() == ".xlsx"
                ]
                if not members:
                    raise ValueError("导出包中未找到 .xlsx 文件")

                extracted = []
                name_occurrences: dict[str, int] = {}
                for entry in members:
                    # 始终带上包内工作簿名：同名文件覆盖，其他 Sheet 文件保持不动。
                    member_name = entry.filename
                    base_name = planned_destination_name(name_prefix, member_name)
                    occurrence = name_occurrences.get(base_name, 0) + 1
                    name_occurrences[base_name] = occurrence
                    destination_name = planned_destination_name(
                        name_prefix,
                        member_name,
                        occurrence,
                    )
                    destination = destination_directory / destination_name
                    temporary = destination.with_suffix(".partial")
                    with archive.open(entry) as source, temporary.open("wb") as output:
                        shutil.copyfileobj(source, output)

                    if verify_xlsx_file(temporary):
                        temporary.replace(destination)
                        extracted.append(destination)
                    else:
                        temporary.unlink(missing_ok=True)

            if not extracted:
                raise ValueError("导出包中的 .xlsx 文件均未通过校验")
    except BadZipFile as error:
        raise ValueError("下载内容不是有效的 ZIP 或 Excel 文件") from error

    return extracted


def main() -> int:
    args = parse_args()
    try:
        workbooks = extract_workbooks(
            args.archive,
            args.destination,
            args.source_key,
            args.preferred_name,
        )
    except Exception as error:  # noqa: BLE001 - 需要将底层错误反馈到 App 控制台。
        print(f"处理钉钉下载文件失败：{error}", file=sys.stderr)
        return 1

    print(json.dumps([str(path) for path in workbooks], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
