# FSDeltaMonitor

Linux 磁盘空间增长实时监测脚本（零第三方依赖）。

## 特性

- 单文件脚本，`bash` 直接运行
- 支持监测目录或文件
- 支持目录深度、扫描间隔、Top N
- 支持 `include/exclude` 路径过滤
- 终端实时图形化（TUI）展示增长排行
- 支持按 `q` 退出

## 一行命令运行

```bash
bash fsdelta.sh --path /data --mode dir --depth 3 --interval 2 --top 20
```

## 参数

- `--path <PATH>`: 必填，监测目标（目录或文件）
- `--mode <dir|file|auto>`: 模式，默认 `dir`
- `--depth <N>`: 目录扫描深度，默认 `2`（仅 `dir` 模式生效）
- `--interval <SEC>`: 扫描间隔秒数，默认 `2`
- `--top <N>`: 显示增长 Top N，默认 `10`
- `--include <PATTERN>`: 包含模式，可重复
- `--exclude <PATTERN>`: 排除模式，可重复
- `--once`: 执行一轮后退出
- `--no-color`: 关闭彩色输出
- `--help`: 查看帮助

## 示例

```bash
# 目录模式（推荐）
bash fsdelta.sh --path /var --mode dir --depth 2 --interval 2 --top 10

# 自动模式（path 为文件时自动切换 file）
bash fsdelta.sh --path /var/log/syslog --mode auto --once

# include / exclude 组合
bash fsdelta.sh --path /data --mode dir --include "/data/app/*" --exclude "*/cache/*"
```

## 兼容性说明

- 依赖常见 Linux 工具：`du/find/stat/awk/sort/head/date/tput`
- `du -d` 不可用时，会自动回退到 `find + du -sk`
- 默认状态文件路径：`/tmp/fsdelta_<uid>_<hash>.state`，进程退出自动清理

## 验证建议

```bash
# 语法检查
bash -n fsdelta.sh

# 快速功能验证
mkdir -p /tmp/fsdelta-demo/a
bash fsdelta.sh --path /tmp/fsdelta-demo --mode dir --depth 2 --interval 2 --top 5
# 另开终端执行:
dd if=/dev/zero of=/tmp/fsdelta-demo/a/grow.bin bs=1M count=20 oflag=append conv=notrunc
```

## 常见问题

```bash
# 如果脚本在 Linux 上提示 Windows 行尾（CRLF）问题，可执行：
sed -i 's/\r$//' fsdelta.sh
chmod +x fsdelta.sh
```
