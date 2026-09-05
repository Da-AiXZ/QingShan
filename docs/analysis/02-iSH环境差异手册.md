# iSH 环境差异与适配规则手册

> 适用对象：青山（iPad 本地 AI Agent，SwiftUI 宿主 + iSH ARM64 模拟沙箱）的工具设计与命令执行。
> 依据：iSH 源码 `repos/ish-arm64/ish-arm64-master/`、宿主桥 `QingShan/Platform/ISHKernel.m`、`ISHShellExecutor.m`、执行层 `QingShan/QingShan/AgentCore/`。所有"源码证据"均给出文件与行号，可复核。
> 本手册区分两条执行通路（二者差异巨大，工具设计必须先问自己走的是哪条）：
> - **PTY 通路**（PersistentShell，Agent 主通路）：常驻 `/bin/sh -l` 挂在伪终端上，输入经 `sendInputString` 注入，输出经文件协议（`/tmp/.qs_o`、`/tmp/.qs_r`、`/tmp/.qs_done`）回收。
> - **管道通路**（ISHShellExecutor）：每命令新建进程，`/bin/sh -c`，stdin=/dev/null 或 pipe，stdout/stderr=宿主管道，**没有 tty**。

---

## 1. tty/PTY

### 1.1 输入缓冲上限 4096 字节，且注入是非阻塞的
- **差异**：guest tty 输入缓冲只有 4096 字节。宿主注入调用 `tty_input(..., blocking=false)`（非阻塞），缓冲满时**静默丢弃剩余部分，不报错、不回调错误**。
- **源码证据**：`fs/tty.h:112`（`#define TTY_BUF_SIZE 4096`）；`fs/tty.c:219-229`（`tty_push_char` 满时非阻塞路径返回 `_EAGAIN`，外层直接 break）；`fs/tty.c:274-346`（canonical 循环中 `done_size--` 后退出，丢数据无信号）；`ISHKernel.m` `sendInput:`（`tty_input(_consoleTTY, data.bytes, data.length, false)`——最后一个参数 `false` 即非阻塞）。
- **影响**：任何经 PTY 注入的长命令（heredoc 写大文件、长单行命令）超过约 4KB 即被截断，且**截断是静默的**——Agent 以为命令完整，实际只执行了前缀。已实证的 17KB 截断是同一机制（shell 逐行消费使缓冲边排边进，撑到 ~17KB 后彻底堵死）。
- **适配规则**：
  1. 单次 PTY 注入的命令文本 ≤ 2KB（留安全余量）。
  2. 大内容一律走宿主直写：Swift 写 `Documents/root/data/tmp/`（= guest `/tmp`），shell 只执行一条短 `cp`。`write_file` 已如此实现（`AgentSession.swift:471-478`），所有工具照此办理。
  3. 永远不要用 heredoc/`echo`/`printf` 经 PTY 写大于 2KB 的文件。

### 1.2 行规则默认 canonical + ISIG：注入内容里的控制字符会被劫持
- **差异**：tty 默认 `ISIG|ICANON|ECHO|...`（`fs/tty.c:39`）。注入字节流中 `\x03`(VINTR)、`\x1c`(VQUIT)、`\x1a`(VSUSP)、`\x04`(VEOF)、`\x7f`(VERASE) 会被行规则解释，不会到达 shell 的输入。
- **源码证据**：`fs/tty.c:235-257`（`tty_send_input_signal` 拦截 VINTR/VQUIT/VSUSP 并向前台进程组发信号）；`fs/tty.c:41`（cc 默认表）；`fs/tty.c:290-312`（VERASE 删字符——注入内容里的 0x7f 会删掉前面已注入的字符）。
- **影响**：① 注入含 0x7f/0x03 等字节的文本会被改写或触发信号；② `\r` 因 ICRNL 被转成 `\n`（`fs/tty.c:282`）；③ PersistentShell 超时发 `\x03` 杀前台命令正是利用此机制——反过来说，前台跑着长命令时，**队列里排队的注入若含控制字符会先触发信号**。
- **适配规则**：命令文本只允许可打印 ASCII/UTF-8 + `\n`；二进制内容禁止经 PTY；超时中断依赖 `\x03` 是既有约定，工具不要注入其他控制字符。

### 1.3 回显、输出 OPOST/ONLCR
- **差异**：默认 ECHO 开（注入的命令文本会回显进输出流）；输出侧 `OPOST|ONLCR` 把 `\n` 变 `\r\n`（`fs/tty.c:37,568`）。PersistentShell 启动即发 `stty -echo` 抑制回显，但首条命令前窗口期回显仍在。
- **源码证据**：`fs/tty.c:39`；`PersistentShell.swift:31`；`fs/tty.c:558-573`。
- **影响**：输出流里混有回显与 `\r`；对输出做标记解析不可靠（已踩坑：标记同行、退出码丢失、首字符回显）。
- **适配规则**：读输出一律走文件协议（`.qs_o/.qs_r`），解析前先剥离 `\r`；不要基于 PTY 流做任何行级协议/标记匹配。

### 1.4 窗口大小固定 24×200
- **源码证据**：`ISHKernel.m:937`（`winsize = {.row=24, .col=200}`）。
- **影响**：依赖 `$COLUMNS`/`tput`/自适应宽度的程序（busybox top/ps、diff 的宽度对齐）按 200 列排版；环境里 `TERM=xterm-256color` 但尺寸固定。
- **适配规则**：不要让输出排版依赖终端宽度；解析宽表输出时按内容切分而非列位置。

### 1.5 管道通路下根本没有 tty
- **差异**：ISHShellExecutor 把 stdout/stderr 接到宿主 pipe、stdin 接 /dev/null（`ISHShellExecutor.m:389-448`）。`isatty(0/1/2)` 全为假，虽然 `TERM` 仍被设成 xterm-256color。
- **影响**：TTY 检测类行为（颜色、进度条、交互确认）在两条通路上**不一致**——同一条命令在 PTY 通路有 tty、在管道通路没有。交互式程序（apk add 的确认、passwd）在管道通路直接失败。
- **适配规则**：所有命令按非交互写法：`apk add -y`...（busybox apk 无 -y 时用 `yes |`，但注意管道退出码）、禁止依赖 stdin 的命令；颜色类行为统一显式关（环境已设 `NO_COLOR=1`，工具层不要依赖）。

### 1.6 退出/超时的宿主侧窗口
- **差异**：进程退出后宿主有 200ms drain 窗口再 finalize（`ISHShellExecutor.m:947-954`）；reader 500ms 轮询、4096B 读缓冲（`ISHShellExecutor.m:1028,1065`）。
- **影响**：管道通路上退出码前一刻的海量输出尾部可能截断；输出按行重组，**无换行结尾的最后一行仍会进 buffer**（`processLines` 后 flush `lineBuffer`，`ISHShellExecutor.m:1150-1161`）。
- **适配规则**：命令结尾显式 `echo` 换行或保证最后输出带 `\n`；大输出靠文件落盘再取，不要依赖流。

---

## 2. shell：ash vs bash 差异清单

/bin/sh 是 busybox ash（dash 家族）。以下条目均为 ash 与 bash 的实证差异（结合 `ISHShellExecutor.m:289-304` 的 [T-heredoc-trailing-newline] 注释与 ash 语义）：

| # | bash 写法 | ash 表现 | 适配 |
|---|---|---|---|
| 2.1 | `eval -- '...'` | `eval` 不接受 `--`，报 `--: not found`（已踩坑） | `eval '...'` 直接用 |
| 2.2 | heredoc 终止符后无换行 | `unexpected end of file`，100% 失败（`ISHShellExecutor.m:289-298`，宿主已自动补 `\n`，但多命令拼接时仍要自己保证） | heredoc 结束行后必有换行；能不用则不用 |
| 2.3 | 数组 `a=(1 2)`、`${a[@]}` | 不支持 | 用空格分隔字符串 + `for x in $list` |
| 2.4 | `[[ ]]`、`=~`、`< >` 比较 | 不支持（`[ ]` only） | POSIX `[ ]` + `case` |
| 2.5 | `$(< file)` | 不支持 | `cat file` |
| 2.6 | `$'...'` ANSI-C 引号 | 不支持 | `printf` |
| 2.7 | 进程替换 `<(...)` `>(...)` | 不支持 | 临时文件中转 |
| 2.8 | `set -o pipefail` | **不支持**——管道退出码只看最后一个命令 | 管道中间环节失败会被吞；关键管道用临时文件分步 |
| 2.9 | `${var,,}` `${var^}` 大小写变换、`&>>`、`local -n`、`coproc`、`shopt`、`declare -i/-A` | 均不支持 | POSIX 化 |
| 2.10 | `**` 递归 glob | 不支持 | `find` |
| 2.11 | `RANDOM` | busybox ash 有条件支持，不可依赖 | 用 `$RANDOM` 前先赋值测试或用 `date +%s` |
| 2.12 | `function f {}` | 不支持 `function` 关键字 | `f() {}`（`local` 关键字 ash 支持） |
| 2.13 | `echo -e` | busybox 内建支持，但转义集与 bash 有差 | 统一用 `printf '%s\n'` |
| 2.14 | `exit` | **会杀死持久 shell 本身**——Agent 通路是常驻 shell，`eval 'exit'` 后所有状态、后续命令全灭 | 工具层命令黑名单：`exit`、`logout`、`reboot`、`poweroff`、`kill -9 1`；子 shell 里退出用 `( exit 1 )` |
| 2.15 | PersistentShell 的 `eval '<cmd>'` 包装 | 命令文本经过一层单引号 + eval 二次解析（`PersistentShell.swift:49-51`）。含单引号已自动转义，但**多行命令中行内的 `~` 展开、别名行为与直接执行等价；注意别在命令里再嵌套产生不平衡引号** | 工具层对命令做引号平衡校验后再下发 |
| 2.16 | `$BASH_VERSION`、`$UID` | 不存在 | 探测环境用 `uname -a`（Linux 4.20.69-ish aarch64，`kernel/uname.c:24-27`） |

---

## 3. busybox vs GNU 常用命令差异

Alpine rootfs 用户态全部来自 busybox + musl。逐条：

| 命令 | 差异 | 适配规则 |
|---|---|---|
| `ls` | tty 下 busybox ls 输出 ANSI 颜色转义（已踩坑）；无 `--author`、`--full-time` 等 | 始终 `ls --color=never`，或持久 shell 里 `alias ls='ls --color=never'`；机器解析用 `ls -1` 或 `find -maxdepth 1` |
| `grep` | 无 `-P`（PCRE）；`--include/--exclude` 无；`-r` 可用 | 正则用 ERE（`grep -E`）；文件过滤交给 find |
| `sed` | 无 `-z`、无 GNU `\b`/`\xHH` 部分转义、`-i` 需要（busybox `-i` 可无后缀，但 GNU 脚本 `-i.bak` 形式不同） | sed 脚本保持 POSIX；替换复杂文本用 awk 或宿主写文件 |
| `awk` | busybox awk：无 `asort/gensub/@include/-e`、无多维数组下标逗号语义差异 | 按 POSIX awk 写；格式化依赖 `printf` |
| `cp`/`mv` | cp 有 `-a`；mv 无 `--backup`、`-n` 语义有 | 覆盖保护自己用 `[ -e ]` 判断 |
| `xargs` | 有 `-0 -r -n -I`；`-P` 并行支持不全 | 分批用 `-n` |
| `timeout` | **存在**（busybox applet），`timeout 10 cmd` 可用 | 长任务优先包 `timeout`，别只靠工具层超时 |
| `date` | `-d` 解析子集（GNU `date -d 'yesterday'` 部分可用，复杂表达式不行）；无 `%:z` 等 | 时间运算用 `awk`/Python |
| `tar` | 无 `--sort`、`--transform`、`--numeric-owner` 部分选项 | 基础 `czf/xzf` 即可 |
| `stat` | 格式符子集（`%Y %s %F` 有） | 少用花哨格式串 |
| `df` | fakefs 上报的是宿主容器数字，`-h` 可用但总/用量为假象 | 只看可用空间 |
| `head`/`tail` | `tail -f` 是**轮询实现**，不依赖 inotify——可用 | `tail -f` 可放心用于日志跟踪 |
| `ping` | **不可用**：raw socket 被拒（见 §6.3） | 网络探测用 `nc -z host port`、`wget -q --spider` |
| `man`、`make`、`bash`、`git`、`python3` | 非 busybox：git/python3 等需 `apk add` 预装（环境里已装 python3、node（jitless）） | 工具描述里注明可用运行时；缺的先 `apk add` |
| `find` | `-printf` 部分支持、`-samefile` 有 | 复杂 find 输出用 `-exec` 直接处理 |

---

## 4. fakefs（guest / ↔ 宿主 Documents/root/data）

### 4.1 权限模型：root 玩具 + chown 失败被吞
- **源码证据**：`fs/fake.c:882`（"iSH runs as a non-root iOS app; host chown will EPERM"——chown 静默失败）；chmod 落到宿主 `chmod`（`fs/fake.c:877,931`）；symlink mode 恒 `0777`（`fs/fake.c:675`）。
- **影响**：一切以 root 身份运行，权限位是装饰；`chown` 不报错但无效；`chmod +x` 真实生效（宿主 APFS 支持）。
- **适配规则**：不要用权限位做访问控制或判断（`[ -w ]` 恒真）；可执行位可以设。

### 4.2 符号链接
- **差异**：guest symlink 在宿主侧是"普通文件 + meta.db 标记"，宿主真实目录挂载（bind mount）走相对 symlink（绝对 symlink 在 iOS 沙箱内 openat 会失败）。
- **源码证据**：`fs/fake.c:643-651, 1080-1116, 1185-1291`。
- **影响**：指向 guest 内部的 symlink 可用；跨 bind mount 边界的路径重定向由 fakefs 路径翻译层处理。宿主侧（Swift/FileManager 直写）看到的 symlink 是 host 相对链接，**宿主直写 `data/tmp/` 下的文件路径时必须用真路径而非 guest 路径**。
- **适配规则**：双端共享数据固定走 `guest /tmp` ↔ 宿主 `Documents/root/data/tmp` 这一已验证通道。

### 4.3 mmap 语义：MAP_PRIVATE 文件映射写不回
- **源码证据**：`fs/real.c:331-363`——`MAP_SHARED|PROT_WRITE` 走真实文件 mmap；其余（MAP_PRIVATE 文件映射）退化为匿名映射拷贝；`kernel/mmap.c:344-359`——`MAP_SHARED|MAP_ANONYMOUS` 不支持。
- **影响**：依赖 mmap 私有映射回写文件、或共享匿名映射做 IPC 的程序（部分 JIT、共享内存库）行为异常。sqlite 自身 mmap 模式需关闭（环境已设 `PYTHONMALLOC=malloc` 等规避）。
- **适配规则**：涉及 sqlite 时确保 `PRAGMA mmap_size=0`；不要用共享内存 IPC。

### 4.4 inotify 是纯 stub——必然坑到的暗雷
- **源码证据**：`kernel/inotify.c:31-33`（`inotify_add_watch` "Return a dummy watch descriptor. We don't actually monitor anything." 返回恒 1）；`kernel/inotify.c:45-54`（read 永远无事件，非阻塞恒 EAGAIN，阻塞则永久挂起）；`kernel/inotify.c:56-59`（poll 永不可读）。
- **影响**：一切基于 inotify 的机制**永久挂起或空转**：`npm run watch`、nodemon、`fs.watch`（node 转 inotify）、Python watchdog、`inotifywait`。它们不会报错，只会"不触发"。
- **适配规则**：文件变更检测一律改轮询（`while :; do [ file 变了 ] && ...; sleep 1; done`）；工具层发现命令含 `watch|nodemon|inotify` 时提示 Agent 该机制不可用。`tail -f`（busybox 轮询实现）是安全的。

### 4.5 大小写敏感性：guest 文件系统实际不区分大小写
- **差异**：fakefs 落盘到 iOS app 容器（APFS 大小写不敏感卷），`Foo.txt` 与 `foo.txt` 是同一文件；`git mv` 大小写改名、解压含 `A/a` 的 tar 都会冲突。
- **源码证据**：挂载点 `ISHKernel.m:494-548`（`mount_root(&fakefs, _dataPath...)`，dataPath 在 Documents 下）；iOS 容器卷属性。
- **影响**：跨平台脚本按 Linux 习惯假设大小写敏感会静默出错；git 仓库可能报"文件已存在"。
- **适配规则**：生成文件名统一小写；工具校验：目标路径与已有文件仅大小写不同时告警。

### 4.6 文件锁与随机写
- **差异**：`flock` 走宿主真实 flock（`fs/fake.c:1411` `.flock = realfs_flock`）——可用；随机 seek 写是真实宿主文件，性能尚可，但每次 open/close 附加 fakefs 路径翻译 + meta.db 开销。
- **适配规则**：多进程并发写同一文件可用 flock 协调；海量小文件操作（如解包几千个文件）显著慢于 Linux，考虑打包整体落盘。

---

## 5. 进程模型

### 5.1 fork/clone 支持与内存闸门
- **源码证据**：`kernel/fork.c:306-311`（fork/vfork 均实现，clone 支持 `CLONE_VM|FILES|FS|SIGHAND|THREAD|VFORK` 子集，`fork.c:51`）；宿主 fork 内存闸门 `ISHKernel.m:56-250`（app 内存超限/系统压力时 `fork()` 停顿等待，busybox 不会重试失败的 fork——被闸门改为"慢"而不是"失败"）。
- **影响**：突发大量 fork（`make -j`、并行构建）会显著变慢但不失败；Go/Node 多线程 OK（GOMAXPROCS=2 已设）。
- **适配规则**：并行任务数压到 ≤2；`make` 用 `-j2` 以下。

### 5.2 信号、进程组与超时击杀
- **源码证据**：`kernel/signal.c:39-48`（默认处置含 SIGTTIN/TTOU/TSTP）；宿主击杀 `ISHShellExecutor.m:760-833`（按 pgid + 祖先链双匹配 SIGTERM→200ms→SIGKILL；ash 会给子 shell `setpgid` 新进程组，所以光按 pgid 会漏杀——这正是 Stop 按钮杀不死 `sleep` 的根因，已修）；kill 拒绝 pid≤1。
- **影响**：工具层超时击杀**基本可靠**但需 ~200ms+ 窗口；guest 内 `kill -1` 不会伤害宿主。
- **适配规则**：工具层击杀后不要立即复用同一 pid 做判断；命令自限优先 `timeout N`。

### 5.3 僵尸与孤儿
- **源码证据**：`kernel/exit.c:147-175`（父死后 reparent 到 pid 1，`pid_get_task(1)`）。
- **影响**：与 Linux 一致，daemon 化（`setsid`）语法上可行——但见 5.4。
- **适配规则**：无需特殊处理。

### 5.4 App 生命周期：退后台冻结一切（最大暗雷之一）
- **差异**：iOS 切后台 → 宿主进程整体挂起，**所有 guest 线程、定时器、网络连接同时冻结**；后台超过系统宽限或内存吃紧 → jetsam 直接杀宿主 = 整个 guest 世界消失，持久 shell 的 cd/export/后台任务全部丢失。nohup/setsid/disown 在 guest 内毫无意义。
- **源码证据**：iOS 平台语义（非 iSH 代码）；iSH 的 `init` 即宿主进程（`kernel/exit.c:402-455` "init dying means we're shutting down completely"）。
- **适配规则**：① 长任务命令必须在单次工具调用的超时窗口内前台完成（配 `timeout`），不要拆成"后台跑+轮询"；② 恢复会话时工具层要能重建 shell 状态（当前 /bin/sh -l 常驻进程若 app 被杀，需重新 boot）；③ 提示用户长任务期间保持前台。

---

## 6. 网络

### 6.1 DNS：/etc/resolv.conf 是宿主 bind mount
- **源码证据**：`ISHKernel.m:847-897`（`fakefs_bind_mount("/etc/resolv.conf", Library/MinisChat/dns/resolv.conf)`，系统 DNS 刷新 + 8.8.8.8/8.8.4.4 兜底，含 search 域）。
- **影响**：guest 改写 `/etc/resolv.conf` 实际改宿主文件且会被刷新覆盖；DNS 与宿主同源。
- **适配规则**：DNS 问题排查别改 resolv.conf（会被覆盖）；需要特定解析时用 `--resolve`(curl)/hosts 方案或让宿主侧处理。

### 6.2 socket 全部转译为宿主 BSD socket
- **源码证据**：`fs/sock.c:38-64`（socket() 直接 host socket()）；IPv6 支持（AF_INET6）。
- **影响**：TCP/UDP 正常，走 iOS 网络栈（无 ATX 限制于原生 socket）；带宽/时延即宿主。
- **适配规则**：下载类工具用 wget/curl；重试与超时按慢速移动网络设。

### 6.3 raw socket 禁用、ping 不可用
- **源码证据**：`fs/sock.c:48-50`（`SOCK_RAW+IPPROTO_RAW` 显式拒绝；ICMP raw 亦然）。
- **影响**：`ping` 失败（不是网络不通）——Agent 极易误判"网络挂了"。
- **适配规则**：连通性探测规范：`nc -z -w3 host port` 或 `wget -q --spider URL`；工具层可拦截 ping 并改写。

### 6.4 AF_UNIX：bind 路径是假象
- **源码证据**：`ISHKernel.m:767-780`（guest unix socket 地址被翻译为宿主 `<sock_tmp_prefix><pid>.<socket_id>`，[T-ios-ish-af-unix-sandbox GH#175]）；`fs/sock.c:348`（bind /tmp EPERM 兜底处理）。
- **影响**：`bind('/tmp/x.sock')` 后 `/tmp/x.sock` **不会作为文件出现**，`ls` 看不到，基于文件存在性判断 socket 的逻辑失效；两个 guest 进程间 unix socket 仍可通（经由翻译层），但路径不可见。
- **适配规则**：本地 IPC 优先用 TCP localhost；避免 unix socket 文件路径探测。

---

## 7. 资源限制

| 资源 | 现实 | 证据 | 适配 |
|---|---|---|---|
| 内存 | guest 与宿主 app 共享 footprint；jetsam 杀宿主=世界毁灭；`/proc/meminfo` 上报封顶 4GB | `fs/proc/root.c:62-66`（MEMINFO_MAX_RAM 4GB cap，防 musl/V8 按假大内存分配）；fork 闸门 reserve 400MB（ISHKernel.m:66） | 单进程内存预算按 ~数百 MB 设计；node 已限 512MB（ISHShellExecutor.m:478） |
| CPU | 单线程 JIT 模拟，约原生 1/50~1/100；GOMAXPROCS=2、Go asyncpreemptoff | `ISHShellExecutor.m:566-567` | 编译/大计算任务给足超时（240-600s）并预期失败回退 |
| 进程数 | pid 空间 MAX_PID；并发 fork 受内存闸门 | `ISHKernel.m:605`；`ISHShellExecutor.m:786` | 控制并发 ≤2 |
| fd | guest 每进程上限与 Linux 常规一致量级，但每个 guest fd 背后占宿主 fd | `fs/fd.c` | 大规模并发 IO 用文件不用多 fd |
| 磁盘 | = iOS app 容器剩余空间；`df` 可看 | §3 df 条 | 大文件下载前 `df /tmp` 预检 |
| reader 线程 | 每命令占 2 个 GCD reader 线程，泄漏 30 个命令后系统瘫（历史 bug，已有 sweeper 兜底 2h） | `ISHShellExecutor.m:29-38,183-196` | 工具层避免海量极短命令高频连发 |

---

## 8. 路径与挂载表

| guest 路径 | 本体 | 证据 |
|---|---|---|
| `/` | 宿主 `Documents/root/data`（fakefs） | `ISHKernel.m:548`；`PersistentShell.swift:20` |
| `/proc` | procfs（meminfo/cpuinfo/uptime 有，值部分为假） | `ISHKernel.m:584`；`fs/proc/root.c` |
| `/dev/pts` | devpts | `ISHKernel.m:585` |
| `/etc/resolv.conf` | bind mount → 宿主 Library/MinisChat/dns/resolv.conf | `ISHKernel.m:871` |
| `/tmp` | fakefs 内 = 宿主 `Documents/root/data/tmp`（双端共享通道） | `PersistentShell.swift:21`；`AgentSession.swift:474` |
| 动态 bind mount | 宿主任意目录可挂入 guest（fakefs_bind_mount/unmount，带 fs_context 任务组级路径翻译） | `ISHKernel.m:1122-1136, 1361-1380` |

- **大小写**：见 §4.5，不区分。
- **适配规则**：工具文档中的"沙箱路径"统一用 guest 绝对路径；宿主直写只用 `/tmp` 对应的 `data/tmp`；其他路径宿主直写会绕过 fakefs 元数据（meta.db 不同步）造成 inode 混乱——**禁止**。

---

## 9. 安全边界与不可用 syscall

- **身份**：guest 内 root，但宿主是普通 iOS app——一切操作受 iOS 沙箱约束，逃逸面为零（iSH AOT/JIT 模拟器层）。
- **明确不可用/被拒**：raw socket（sock.c:48）、`sethostname`（uname.c:49 EPERM）、共享匿名 mmap（mmap.c:359）、真实 inotify（inotify.c 全 stub）、`chown`（静默失败）。
- **uname**：`Linux 4.20.69-ish aarch64`（uname.c:24-27）——探测脚本可据此识别本环境。
- **ptrace**：guest 内可用（iSH 自带 gdb stub），但对 Agent 工具无意义。
- **适配规则**：命令黑名单（见 §2.14）+ 以下 no-op 清单写进工具系统提示：ping、inotify 系、watch 系、mount（guest 内）、ip link set。

---

## 10. 工具执行适配规则总表

### 写命令
- **Do**：POSIX sh 语法；≤2KB/次；`timeout N` 包长命令；`ls --color=never`；`nc -z` 代替 ping；`printf` 代替 `echo -e`；管道关键环节分步落盘。
- **Don't**：bashism（数组/`[[ ]]`/`$'...'`/进程替换/pipefail）；`eval --`；heredoc 写大文件；`exit/logout/reboot`；依赖 stdin 的交互命令；命令中裸控制字符。

### 读输出
- **Do**：文件协议（`.qs_o/.qs_r`）为主；解析前剥 `\r`；输出 >16KB 先 `grep/head` 缩量（AgentSession 已截断 16k，`AgentSession.swift:410-411`）；最后输出保证带换行。
- **Don't**：PTY 流行级标记匹配；依赖 ANSI 颜色/终端宽度排版；假设 stdout/stderr 交错时序。

### 写文件
- **Do**：>2KB 走宿主暂存 + `cp`（已实现）；目标路径 `mkdir -p`；文件名统一小写。
- **Don't**：经 PTY heredoc/echo 写大文件；宿主直写 `data/tmp` 之外的 guest 路径；依赖大小写区分、权限位、inotify。

### 长任务
- **Do**：单次调用前台完成（timeout 上限 600s，`AgentSession.swift:487`）；分段产出中间文件；保持 app 前台。
- **Don't**：后台 + 轮询模式；nohup/setsid/disown 期待存活；跨退后台的任务假设（冻结/被杀）；`make -j` 大并行。

### 网络任务
- **Do**：wget/curl 标准用法；连通性用 `nc -z`；DNS 交给系统；下载前 `df /tmp`。
- **Don't**：ping（必失败）；改 resolv.conf（会被覆盖）；unix socket 文件路径探测；假定低延迟网络。

### Top 5 最危险差异（按坑 Agent 概率排序）
1. **PTY 输入 >4KB 静默截断 + 控制字符劫持**（§1.1/1.2）——无声失败，最阴险。
2. **inotify 纯 stub**（§4.4）——watch 类命令永久挂起直到超时，Agent 会误以为"程序在等事件"。
3. **大小写不敏感文件系统**（§4.5）——git/tar/跨平台脚本静默冲突。
4. **ping 必失败 + AF_UNIX 路径不可见**（§6.3/6.4）——网络与 IPC 误判。
5. **退后台冻结 + jetsam 杀全世**（§5.4）——长任务后台化设计全军覆没，且 nohup 无法挽救。
