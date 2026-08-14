#!/usr/bin/env python3
# Author: Renogy_YX
"""统一管理 Excel 表头别名与 BCP 47 Locale 代码。"""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple, Union


LOCALE_CODE_PATTERN = re.compile(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*")
LOCALE_HEADER_GROUP_PATTERN = re.compile(r"^(?P<prefix>.+?)\s*[（(]\s*(?P<locale>[^()（）]+?)\s*[）)]$")
DEFAULT_CONFIG_PATH = Path(__file__).with_name("locale_aliases.json")


def normalize_locale_code(value: str) -> str:
    """规范化 BCP 47 Locale 的大小写与分隔符，保留未知但合法的扩展标签。"""
    cleaned = value.strip().replace("_", "-")
    if not cleaned:
        raise ValueError("Language code cannot be empty.")

    parts = cleaned.split("-")
    normalized = [parts[0].lower()]
    for part in parts[1:]:
        if len(part) == 4 and part.isalpha():
            normalized.append(part.title())
        elif (len(part) == 2 and part.isalpha()) or (len(part) == 3 and part.isdigit()):
            normalized.append(part.upper())
        else:
            normalized.append(part.lower())
    return "-".join(normalized)


def normalize_header_token(value: str) -> str:
    """忽略表头别名中的大小写、全半角与空白差异。"""
    normalized = unicodedata.normalize("NFKC", value).strip()
    return re.sub(r"\s+", "", normalized).casefold()


class LocaleRegistry:
    """可叠加的 Locale 别名注册表。"""

    def __init__(self) -> None:
        self._aliases: Dict[str, str] = {}
        self._ignored_headers = {
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

    def merge_file(self, path: Union[Path, str]) -> None:
        config_path = Path(path).expanduser()
        try:
            payload = json.loads(config_path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise ValueError(f'Locale config file was not found: "{config_path}".') from error
        except json.JSONDecodeError as error:
            raise ValueError(f'Locale config is not valid JSON: "{config_path}" ({error.msg}).') from error

        if not isinstance(payload, dict):
            raise ValueError(f'Locale config must be a JSON object: "{config_path}".')

        locales = payload.get("locales", {})
        if not isinstance(locales, dict):
            raise ValueError(f'"locales" must be an object in "{config_path}".')

        for code, aliases in locales.items():
            if not isinstance(code, str) or not LOCALE_CODE_PATTERN.fullmatch(code.strip().replace("_", "-")):
                raise ValueError(f'Invalid locale code "{code}" in "{config_path}".')
            if not isinstance(aliases, list) or not all(isinstance(alias, str) for alias in aliases):
                raise ValueError(f'Locale "{code}" must contain a string array of aliases in "{config_path}".')
            self.add_locale(code, aliases)

        ignored_headers = payload.get("ignored_headers", [])
        if not isinstance(ignored_headers, list) or not all(isinstance(item, str) for item in ignored_headers):
            raise ValueError(f'"ignored_headers" must be a string array in "{config_path}".')
        self._ignored_headers.update(normalize_header_token(item) for item in ignored_headers if item.strip())

    def add_locale(self, code: str, aliases: Iterable[str]) -> None:
        normalized_code = normalize_locale_code(code)
        self._add_alias(normalized_code, normalized_code)
        for alias in aliases:
            if alias.strip():
                self._add_alias(alias, normalized_code)

    def resolve_token(self, value: str) -> Optional[str]:
        raw_value = value.strip()
        if not raw_value:
            return None

        alias = self._aliases.get(normalize_header_token(raw_value))
        if alias is not None:
            return alias

        candidate = raw_value.lstrip("-")
        if normalize_header_token(candidate) in self._ignored_headers:
            return None
        if not LOCALE_CODE_PATTERN.fullmatch(candidate):
            return None
        if (
            "-" not in candidate
            and "_" not in candidate
            and len(candidate) == 3
            and not (candidate.islower() or candidate.isupper())
        ):
            return None
        return normalize_locale_code(candidate)

    def parse_header(self, value: str) -> Optional[Tuple[str, str]]:
        """解析直接表头或“分组（语言）”表头，返回分组名称和 Locale。"""
        normalized = value.strip()
        if not normalized:
            return None

        direct_locale = self.resolve_token(normalized)
        if direct_locale is not None:
            return "", direct_locale

        match = LOCALE_HEADER_GROUP_PATTERN.fullmatch(normalized)
        if match is None:
            return None
        locale = self.resolve_token(match.group("locale"))
        if locale is None:
            return None
        return match.group("prefix").strip(), locale

    def _add_alias(self, alias: str, code: str) -> None:
        normalized_alias = normalize_header_token(alias)
        if not normalized_alias:
            return

        existing_code = self._aliases.get(normalized_alias)
        if existing_code is not None and existing_code != code:
            raise ValueError(
                f'Locale alias "{alias}" is ambiguous: "{existing_code}" and "{code}".'
            )
        self._aliases[normalized_alias] = code


def load_locale_registry(custom_config_path: Optional[Union[Path, str]] = None) -> LocaleRegistry:
    """加载内置配置，并按需叠加用户选择的 JSON 配置。"""
    registry = LocaleRegistry()
    registry.merge_file(DEFAULT_CONFIG_PATH)
    if custom_config_path is not None:
        registry.merge_file(custom_config_path)
    return registry
