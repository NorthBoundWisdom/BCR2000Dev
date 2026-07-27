#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


CLI_VERSION = "0.145.0"
ROOT = Path(__file__).resolve().parent.parent
SCHEMA_OUT = ROOT / "Schemas" / "Codex" / CLI_VERSION / "stable"


def _codex_version() -> str:
    completed = subprocess.run(
        ["codex", "--version"],
        text=True,
        capture_output=True,
        cwd=ROOT,
        check=False,
    )
    if completed.returncode != 0:
        raise SystemExit(
            "codex 命令不可用，请先安装 codex CLI 或确认 PATH 中可执行"
        )

    value = completed.stdout.strip() or completed.stderr.strip()
    if not value:
        raise SystemExit("无法读取 codex --version 输出")
    # 典型格式类似 `codex 0.145.0`
    version = value.split()[-1]
    return version


def generate_schema() -> None:
    actual = _codex_version()
    if not actual.startswith(CLI_VERSION):
        raise SystemExit(
            f"当前 codex 版本 {actual} 与预期 {CLI_VERSION} 不一致，请先同步文档/脚本"
        )

    SCHEMA_OUT.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            "codex",
            "app-server",
            "generate-json-schema",
            "--out",
            str(SCHEMA_OUT),
        ],
        cwd=ROOT,
        check=False,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"生成 schema 失败：{completed.stderr or completed.stdout}")
    print(f"schema 已生成：{SCHEMA_OUT.relative_to(ROOT)}")


def verify_schema() -> None:
    if not SCHEMA_OUT.exists():
        raise SystemExit(f"未检测到 schema 目录：{SCHEMA_OUT.relative_to(ROOT)}")
    if not any(SCHEMA_OUT.glob("*.json")):
        raise SystemExit("schema 目录存在但未发现 json 文件")
    print(f"schema 校验通过：{SCHEMA_OUT.relative_to(ROOT)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Codex schema 管理")
    parser.add_argument("action", choices=("generate", "verify"))
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    if args.action == "generate":
        generate_schema()
    else:
        verify_schema()
