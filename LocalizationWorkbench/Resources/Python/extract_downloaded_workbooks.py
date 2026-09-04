#!/usr/bin/env python3
"""从钉钉导出包中安全提取并校验 Excel 工作簿。"""

# Author: Renogy_YX

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract validated .xlsx files from a downloaded archive.")
    parser.add_argument("archive", type=Path, help="Downloaded Excel file or ZIP archive.")
    parser.add_argument("destination", type=Path, help="Directory receiving extracted workbooks.")
    parser.add_argument("preferred_name", help="Fallback workbook name when the archive has one workbook.")
    return parser.parse_args()


def is_xlsx_archive(archive: ZipFile) -> bool:
    """xlsx 本质是 ZIP，使用 OOXML 必需文件避免把普通 ZIP 当成工作簿。"""
    names = {entry.filename for entry in archive.infolist()}
    return "[Content_Types].xml" in names and "xl/workbook.xml" in names


def safe_file_name(raw_name: str) -> str:
    stem = Path(raw_name).stem.strip()
    normalized = re.sub(r"[^\w.() -]+", "_", stem, flags=re.UNICODE).strip("._ ")
    return normalized or "DingTalkExport"


def unique_destination(directory: Path, name: str) -> Path:
    candidate = directory / f"{name}.xlsx"
    index = 2
    while candidate.exists():
        candidate = directory / f"{name}-{index}.xlsx"
        index += 1
    return candidate


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


def extract_workbooks(archive_path: Path, destination_directory: Path, preferred_name: str) -> list[Path]:
    if not archive_path.is_file():
        raise FileNotFoundError(f"下载文件不存在：{archive_path}")

    destination_directory.mkdir(parents=True, exist_ok=True)
    try:
        with ZipFile(archive_path) as archive:
            # 若下载结果本身就是 xlsx，直接复制，不把内部 XML 文件误当成导出包内容。
            if is_xlsx_archive(archive):
                destination = unique_destination(destination_directory, safe_file_name(preferred_name))
                return [copy_workbook(archive_path, destination)]

            members = [
                entry
                for entry in archive.infolist()
                if not entry.is_dir() and Path(entry.filename).suffix.lower() == ".xlsx"
            ]
            if not members:
                raise ValueError("导出包中未找到 .xlsx 文件")

            extracted: list[Path] = []
            for entry in members:
                member_name = preferred_name if len(members) == 1 else entry.filename
                destination = unique_destination(destination_directory, safe_file_name(member_name))
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
            return extracted
    except BadZipFile as error:
        raise ValueError("下载内容不是有效的 ZIP 或 Excel 文件") from error


def main() -> int:
    args = parse_args()
    try:
        workbooks = extract_workbooks(args.archive, args.destination, args.preferred_name)
    except Exception as error:  # noqa: BLE001 - 需要将底层错误反馈到 App 控制台。
        print(f"处理钉钉下载文件失败：{error}", file=sys.stderr)
        return 1

    print(json.dumps([str(path) for path in workbooks], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
