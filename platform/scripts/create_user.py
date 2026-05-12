#!/usr/bin/env python3
"""管理员命令行工具：手工创建平台用户。

用法示例:
    export PLATFORM_DATABASE_URL=postgresql+asyncpg://user:pass@localhost/nanobot_platform
    python scripts/create_user.py alice alice@corp.com strongPassword123
    python scripts/create_user.py bob bob@corp.com pass123 --runtime-mode shared
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

# 将 project root 加入 PYTHONPATH，以便导入 app 包
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PROJECT_ROOT not in sys.path:
    sys.path.insert(0, _PROJECT_ROOT)

from app.db.engine import async_session
from app.auth.service import create_user, get_user_by_email, get_user_by_username


async def create_user_cli(
    username: str,
    email: str,
    password: str,
    runtime_mode: str = "dedicated",
) -> None:
    async with async_session() as db:
        if await get_user_by_username(db, username):
            print(f"ERROR: 用户名 '{username}' 已存在", file=sys.stderr)
            sys.exit(1)

        if await get_user_by_email(db, email):
            print(f"ERROR: 邮箱 '{email}' 已被注册", file=sys.stderr)
            sys.exit(1)

        user = await create_user(
            db,
            username=username,
            email=email,
            password=password,
            runtime_mode=runtime_mode,
        )
        print(
            f"SUCCESS: 用户创建成功 — "
            f"id={user.id}, username={user.username}, email={user.email}, "
            f"role={user.role}, runtime_mode={user.runtime_mode}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="手工创建平台用户（管理员专用）")
    parser.add_argument("username", help="用户名（唯一）")
    parser.add_argument("email", help="邮箱（唯一）")
    parser.add_argument("password", help="登录密码")
    parser.add_argument(
        "--runtime-mode",
        "-r",
        choices=["dedicated", "shared"],
        default="dedicated",
        help="运行模式：dedicated（独立容器，默认）或 shared（共享容器）",
    )
    args = parser.parse_args()

    asyncio.run(
        create_user_cli(
            username=args.username,
            email=args.email,
            password=args.password,
            runtime_mode=args.runtime_mode,
        )
    )


if __name__ == "__main__":
    main()
