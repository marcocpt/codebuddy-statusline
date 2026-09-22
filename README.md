# codebuddy-statusline

CodeBuddy Code 的状态栏（status line）脚本。仓库里的这两个脚本部署后被 CLI 直接执行：

| 本仓库 | 部署位置 | 作用 |
|---|---|---|
| `statusline-command.sh` | `~/.codebuddy/statusline-command.sh` | 状态栏本体。`~/.codebuddy/settings.json` 的 `statusLine.command` 指向部署后的绝对路径，无 `bash ` 前缀 |
| `credits-fetch.py` | `~/.codebuddy/credits-fetch.py` | 被状态栏调用，取 CLI 当前账号的昵称与套餐额度 |

`install-statusline.sh` 是早期从临时目录安装这三个文件到 `~/.codebuddy/` 的迁移脚本（含把 `settings.json` 里的路径改成本机 `$HOME`）。

## 两个环境陷阱（都实际踩过，改脚本时别踩回去）

1. **部署副本必须有可执行位。** `statusLine.command` 直接写脚本绝对路径，App 把它当可执行文件 exec；权限为 `-rw-r--r--` 时报 `permission denied`(126)，**整条状态栏完全不渲染**（不是只缺一段）。`install-statusline.sh` 里有 `chmod +x`，但原地改文件时容易丢掉这一位。
2. **PATH 里第一个 `python3` 不一定能用。** App 的 PATH 把 `/usr/local/bin` 排在 `/usr/bin` 之前，而本机 `/usr/local/bin/python3`（Homebrew 3.14）CA 信任库为空，任何 HTTPS 调用都会 `CERTIFICATE_VERIFY_FAILED`，表现为"账号名不显示 + 积分右边是 `--`"，其余段完全正常。脚本里的 `find_python3` 会逐个候选**校验 CA 库非空**，不要简化成"按 PATH 顺序取第一个"。

## 部署

```
cp statusline-command.sh credits-fetch.py ~/.codebuddy/
chmod +x ~/.codebuddy/statusline-command.sh
```

改完建议核对两份是否一致（sha256），确保运行的就是本仓库这份。
