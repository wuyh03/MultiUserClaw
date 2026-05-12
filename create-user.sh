#!/usr/bin/env bash
# 创建平台用户的便捷包装脚本，通过 docker compose exec 在 gateway 容器内执行。
#
# 用法:
#     ./create-user.sh <用户名> <邮箱> <密码> [--runtime-mode dedicated|shared]
#
# 示例:
#     ./create-user.sh alice alice@corp.com strongPassword123
#     ./create-user.sh bob bob@corp.com pass123 --runtime-mode shared

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker 未安装" >&2
    exit 1
fi

# 检查 gateway 容器是否运行
if ! docker compose ps gateway --format '{{.State}}' | grep -q 'running'; then
    echo "ERROR: openclaw-gateway 容器未运行，请先启动服务: docker compose up -d" >&2
    exit 1
fi

# 透传所有参数
docker compose exec gateway python scripts/create_user.py "$@"
