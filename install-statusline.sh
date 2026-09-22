#!/usr/bin/env bash
#
# 迁移/安装 statusline 配置到本机（macOS）。
#
# 用法：
#   1) 把源机的这 3 个文件拷到目标机的某个临时目录，例如 ~/Downloads/statusline-src/
#      （statusline-command.sh  credits-fetch.py  settings.json）
#   2) 在目标机运行：
#      bash ~/Downloads/statusline-src/install-statusline.sh
#
# 脚本会：
#   - 把 statusline-command.sh / credits-fetch.py 复制到 ~/.codebuddy/
#   - 把 settings.json 里的 statusLine.command 绝对路径改成目标机的 $HOME
#   - 检测 CodeBuddy 认证文件是否存在（不存在则提示先登录，但不阻塞）
#
# 注意：credits-fetch.py 读取的认证文件路径用 ~/Library/...（macOS 一致），
# 无需修改。缓存 /tmp/statusline-credits.cache 首次运行自动生成。

set -euo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
DEST_DIR="$HOME/.codebuddy"

echo "源目录: $SRC_DIR"
echo "目标目录: $DEST_DIR"

# 1) 复制脚本文件
mkdir -p "$DEST_DIR"
for f in statusline-command.sh credits-fetch.py; do
  if [ -f "$SRC_DIR/$f" ]; then
    cp "$SRC_DIR/$f" "$DEST_DIR/$f"
    chmod +x "$DEST_DIR/$f"
    echo "✓ 已复制 $f"
  else
    echo "✗ 源目录缺少 $f，跳过" >&2
  fi
done

# 2) 修正 settings.json 里的 statusLine.command 绝对路径
if [ -f "$SRC_DIR/settings.json" ]; then
  cp "$SRC_DIR/settings.json" "$DEST_DIR/settings.json.tmp"
  # 用 python 安全改写 JSON，把 command 里的旧绝对路径替换为目标机 $HOME。
  python3 - "$DEST_DIR/settings.json.tmp" "$DEST_DIR/settings.json" <<'PY'
import json, sys, os
tmp, out = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")
d = json.load(open(tmp))
changed = False
if "statusLine" in d and isinstance(d["statusLine"], dict):
    cmd = d["statusLine"].get("command", "")
    # 把任何旧的 /Users/<谁>/.codebuddy/statusline-command.sh 换成目标机路径
    # 直接写脚本绝对路径（不加 bash 前缀）：App 是把它当可执行文件 exec 的，
    # 所以上面的 chmod +x 是硬要求。写成 "bash <path>" 会与 README 声明的合同
    # 不一致，也会掩盖丢失可执行位这一失败模式。
    if "statusline-command.sh" in cmd:
        d["statusLine"]["command"] = f"{home}/.codebuddy/statusline-command.sh"
        changed = True
json.dump(d, open(out, "w"), indent=2, ensure_ascii=False)
print("✓ settings.json 已写入，statusLine.command 路径" + ("已更新为目标机" if changed else "无需更改"))
PY
  rm -f "$DEST_DIR/settings.json.tmp"
else
  echo "✗ 源目录缺少 settings.json，跳过（请手动在 CodeBuddy 设置里配置 statusLine.command）" >&2
fi

# 3) 检测认证文件（积分/昵称数据源）
AUTH="$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
if [ -f "$AUTH" ]; then
  echo "✓ 检测到 CodeBuddy 登录态，昵称与积分将自动显示"
else
  echo "⚠ 未检测到 CodeBuddy 登录态（$AUTH 不存在）"
  echo "  请先在目标机登录 CodeBuddy / WorkBuddy，重启 CLI 后状态栏即可显示真实昵称与积分。"
fi

echo ""
echo "完成。重启 CodeBuddy CLI 即可生效（或新开一个会话）。"
