#!/usr/bin/env python3
"""Fail an Xcode build when its version has no complete in-app release record."""

import datetime
import json
import plistlib
import re
import sys
from pathlib import Path


def validate(info_path: Path, history_path: Path) -> str:
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    with history_path.open(encoding="utf-8") as handle:
        history = json.load(handle)

    version = str(info.get("CFBundleShortVersionString", "")).strip()
    build = str(info.get("CFBundleVersion", "")).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit():
        raise ValueError("Info.plist 中的版本号或构建号无效")

    releases = history.get("releases")
    if not isinstance(releases, list) or not releases:
        raise ValueError("ReleaseHistory.json 至少需要一条版本记录")

    seen = set()
    for index, release in enumerate(releases, start=1):
        if not isinstance(release, dict):
            raise ValueError(f"第 {index} 条版本记录不是对象")
        key = (release.get("version"), release.get("build"))
        if not all(isinstance(value, str) and value.strip() for value in key):
            raise ValueError(f"第 {index} 条版本记录缺少版本号或构建号")
        if key in seen:
            raise ValueError(f"版本 {key[0]}（{key[1]}）重复")
        seen.add(key)
        for field in ("date", "title"):
            if not isinstance(release.get(field), str) or not release[field].strip():
                raise ValueError(f"版本 {key[0]}（{key[1]}）缺少 {field}")
        try:
            datetime.date.fromisoformat(release["date"])
        except ValueError as error:
            raise ValueError(f"版本 {key[0]}（{key[1]}）日期应为 YYYY-MM-DD") from error
        changes = release.get("changes")
        if not isinstance(changes, list) or not changes or not all(
            isinstance(change, str) and change.strip() for change in changes
        ):
            raise ValueError(f"版本 {key[0]}（{key[1]}）需要非空的更新说明")

    if (releases[0]["version"], releases[0]["build"]) != (version, build):
        raise ValueError(
            f"当前版本 {version}（{build}）必须是 ReleaseHistory.json 的首条记录；"
            "更新 Info.plist 时请同时写入本次迭代内容"
        )
    return f"版本记录已校验：{version}（{build}），共 {len(releases)} 条"


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("用法：ValidateReleaseHistory.py Info.plist ReleaseHistory.json")
        print(validate(Path(sys.argv[1]), Path(sys.argv[2])))
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        sys.exit(f"版本记录校验失败：{error}")
