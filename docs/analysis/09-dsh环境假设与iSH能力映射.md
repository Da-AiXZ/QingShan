# 09 · dsh 环境假设 ↔ iSH 能力映射

> 生成：2026-09-05 · 分析员：env-mapping-dsh-ish
> 核心问题：**dsh 的每个能力/环境假设，迁到 iSH（iOS App 内嵌 ARM64 模拟器：Alpine + busybox + 自研 tty + fakefs + iOS 约束）时，是"直接可行 / 需要适配 / 根本不可行"？**
> 方法：以 dsh 源码（`repos/deepseek-harness/deepseek-harness-master/packages/`）提炼能力清单为行，以 iSH 源码 + 青山执行层（02 号手册已固化，本文引用其章节号）为列逐条判定；dsh 侧证据均亲自读取源码行号。
> 判定图例：✅ 直接可行 ｜ 🟡 需适配（写明怎么适配）｜ ❌ 不可行（写明原因与替代方案）｜ ❓ 待实证（验证命令见文末）。
> 前提提醒（02 号手册 §0）：青山有两条执行通路——PTY 通路（PersistentShell，Agent 主通路）与管道通路（ISHShellExecutor，无 tty）。同一 dsh 假设在两条通路上判定可能不同，表中注明。

---

## 映射大表

### A. shell 生态

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| A1 | 命令经 `bash -c` 执行，bash 全量语义可用 | bash-local/src/index.ts:3 "run as `bash -c` in a managed process group" | 🟡 | guest 只有 busybox ash。默认按 POSIX sh 适配（02 §2 已固化 16 条差异）；如需真 bash 可 `apk add bash`（aarch64 包存在），代价是模拟器下再慢一截、二进制体积大 | ISHShellExecutor.m:289-304；02 §2 |
| A2 | bashism（数组、`[[ ]]`、`$''`、进程替换、`${var,,}`）对模型可用 | dsh 工具层自身不发射 bashism，但依赖 bash 存在使模型输出不被拒 | 🟡 | 系统提示/工具描述显式约束为 POSIX（青山已做）；关键管道分步落盘，勿依赖 `set -o pipefail`（见 ❓V7 复核） | 02 §2.3-2.8 |
| A3 | GNU 工具链（grep -P、sed -z、date -d、tar --sort 等） | 隐含于标准 Linux 环境 | 🟡 | busybox 子集即可覆盖 Agent 常用操作；02 §3 已逐命令固化适配规则（`grep -E`、`printf`、`find` 代替 `**`） | 02 §3 |
| A4 | ENV_OVERRIDES=NO_COLOR/TERM=dumb/PAGER=cat/GIT_PAGER=cat | bash-local/src/index.ts:27-32 | 🟡 | 与环境无关的宿主侧差距：青山未注入（01 号 P2-11）。PersistentShell 启动包装里 export 同款变量即可 | 01 §二（P2 行） |
| A5 | heredoc / `echo` 经 PTY 写文件 | dsh 无此限制（node-pty 写入无 4KB 上限） | ❌ | iSH tty 输入缓冲 4096B 且非阻塞注入，满则**静默丢弃**。替代：>2KB 内容一律宿主直写 `data/tmp` + 短 `cp`（write_file 已实现） | 02 §1.1；AgentSession.swift:471-478 |
| A6 | `timeout N cmd` 包裹长命令 | 无硬依赖但为推荐用法 | ✅ | busybox timeout applet 存在 | 02 §3 timeout 条 |
| A7 | 注入命令含单引号的转义（eval 包装） | dsh 直发 `bash -c`，无二次解析 | ✅（已适配） | PersistentShell `eval '<cmd>'` 单引号包装 + 自动转义已实现，命令需引号平衡校验 | 02 §2.15；PersistentShell.swift:49-51 |

### B. PTY / 终端

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| B1 | node-pty 同步写输入（任意长度、任意字节） | subprocess-local/src/terminal.ts:76 "node-pty writes synchronously" | 🟡 | iSH `tty_input(..., blocking=false)` 非阻塞、4096B 缓冲、满则静默丢 + 控制字符被行规则劫持（\x03/\x7f/\x04）。适配：单次注入 ≤2KB、只允许可打印字符 + `\n`、二进制走文件 | 02 §1.1/1.2；fs/tty.h:112 |
| B2 | PTY 输出流式读取 + scrollback 回读（1000 行分页） | tool-bash-persistent SCROLLBACK_PAGE_LINES=1000（01 表 3） | ✅（已适配） | 青山改为文件协议（`.qs_o/.qs_r/.qs_done`）60ms 轮询 + 16k 截断，语义对齐 | 01 表 3；PersistentShell.swift:58,68-69 |
| B3 | 动态 winsize（node-pty resize，模型可感知 COLUMNS） | node-pty IPty 标准 API | 🟡 | iSH 固定 24×200（`ISHKernel.m:937`）。短期：禁止输出排版依赖宽度，解析按内容切分；宿主理论可改 winsize 暴露但暂无需求 | 02 §1.4 |
| B4 | SIGINT 投递前台（Ctrl-C 中断长命令） | tool-bash 超时处置 / terminal.ts:107（pty 信号） | ✅（已适配） | iSH 行规则 ISIG 把注入 `\x03` 转成 SIGINT 发前台进程组——PersistentShell 超时即发 `\x03`，机制成立 | 02 §1.2；fs/tty.c:235-257 |
| B5 | 进程树 SIGTERM→grace→SIGKILL 升级链 + ps 巡查成员 | terminal.ts:100-149,188-229；process-inspector.ts（ps-based） | ✅（不同实现，语义达成） | iSH 宿主已实现 pgid+祖先链双匹配 SIGTERM→200ms→SIGKILL（还修了 ash setpgid 漏杀）；guest 内 `kill` 亦可用。差异：grace 200ms vs dsh 3s、无 per-signal 任意信号投递（仅 SIGINT/SIGTERM/SIGKILL 级别足够） | ISHShellExecutor.m:760-833；02 §5.2 |
| B6 | `isatty` 行为一致（TTY 检测类程序行为可预期） | dsh 每命令都有真 pty | ❌ | 两通路不一致：PTY 通路有 tty、管道通路 isatty 全假但 TERM 仍设 xterm。适配：所有命令按非交互写法（`apk add -y`、禁交互确认），颜色显式关 | 02 §1.5 |

### C. 进程管理

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| C1 | `run_in_background`：后台进程脱离工具调用存活，job_output 等待/唤醒 | bash-local "background process stays managed even across an executor reload"；jobs-local/index.ts:146,215 | 🟡（受限可用，勿当长任务） | `cmd >log 2>&1 &` + 轮询日志文件在 **App 前台 + 会话存续期**内成立（guest 进程确实继续跑）；但 App 退后台→全冻结、jetsam→全灭，**nohup/setsid/disown 无意义**。dsh 的"跨调用长后台任务 + 完成唤醒"语义降级为"前台单次调用内完成（timeout ≤600s）"；完成唤醒可用宿主轮询重建但价值有限 | 02 §5.4；AgentSession.swift:487 |
| C2 | 进程树托管：composition teardown / host exit 时 terminate-and-join | subprocess-local index.ts:26-41（prependListener exit + disposeManagedProcesses） | ✅（语义更强） | iOS 下"宿主退出 = 整个 guest 世界消失"（iSH init 即宿主进程），终结是天然的、彻底的 | 02 §5.4；kernel/exit.c:402-455 |
| C3 | 并行工具调用 maxParallelToolCalls=10 | core/agent-loop/src/constants.ts:6 | ❌ | PTY 单通道 + fork 内存闸门决定串行（青山已串行执行）。替代：串行 + 重复工具软提醒弥补效率 | 01 表二；AgentSession.swift:347；02 §7 |
| C4 | 每 owner 10 并发后台 job | jobs/jobs-local/src/index.ts:28 | ❌ | 同 C1 边界 + 内存闸门（并发 ≤2）。替代：单次调用前台完成；job 系统列 backlog 不急 | 02 §5.1/5.4 |
| C5 | fork 密集并行（make -j 大并发构建） | 无硬依赖（标准 Linux 假设） | 🟡 | 宿主 fork 内存闸门把"失败"变"慢"，busybox 不会重试成功语义破坏但不会死。适配：`-j2` 以下、并行任务 ≤2 | 02 §5.1；ISHKernel.m:56-250 |

### D. 文件系统

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| D1 | 常规 POSIX 文件读写/目录树 | fs/* 能力面 | ✅ | fakefs 落真实宿主文件，随机 seek 写真实有效 | 02 §4.6 |
| D2 | inotify / fs.watch / chokidar 文件监听（dsh 用于 credentials watcher、hmr） | credentials-local/src/index.ts（watcher.spec）；client/hmr | ❌ | iSH inotify 是纯 stub：add_watch 返回恒 1、read 永无事件——watch 类命令**永久挂起不报错**。替代：一律轮询（`tail -f` 是 busybox 轮询实现，安全） | 02 §4.4；kernel/inotify.c:31-59 |
| D3 | mmap（私有映射回写、共享匿名 IPC；sqlite 默认 mmap） | 无显式依赖，属 Node/底层默认假设 | 🟡 | MAP_PRIVATE 文件映射写不回、共享匿名不支持。适配：sqlite `PRAGMA mmap_size=0`；禁共享内存 IPC | 02 §4.3；fs/real.c:331-363 |
| D4 | 路径大小写敏感 | 标准 Linux 假设 | ❌ | fakefs 落 APFS 大小写不敏感卷：`Foo.txt`=`foo.txt`，git 大小写改名/含 `A/a` 的 tar 静默冲突。替代：文件名统一小写 + 工具层大小写冲突告警 | 02 §4.5 |
| D5 | 符号链接 | 标准 Linux 假设 | ✅（受限成立） | guest 内 symlink 可用（宿主侧是 meta.db 标记文件）；跨 bind mount 由翻译层处理；宿主直写必须走 `/tmp`↔`data/tmp` 已验证通道 | 02 §4.2、§8 |
| D6 | chmod/chown/权限位语义 | 标准 Linux 假设 | 🟡 | guest 内 root：chown 静默失败、权限位是装饰（`[ -w ]` 恒真）；chmod +x 真实生效。适配：不用权限位做判断/访问控制 | 02 §4.1 |
| D7 | flock 文件锁 | 标准 Linux 假设 | ✅ | 走宿主真实 flock（fake.c:1411），多进程协调可用 | 02 §4.6 |
| D8 | fsync / 原子 rename（崩溃一致性，sqlite WAL 依赖） | node:sqlite 默认 journal 假设 | ❓ | fakefs 落真实 APFS 文件，预期语义保留，但 meta.db 与文件的双写一致性未见文档。验证见 V1 | fs/fake.c（路径翻译层） |
| D9 | 海量小文件 IO（解包几千文件的依赖安装） | npm/pip 常规假设 | 🟡 | 每次 open/close 附加路径翻译 + meta.db 开销，显著慢于原生 Linux。适配：打包整体落盘、避免高频极短命令 | 02 §4.6、§7 reader 线程条 |

### E. 网络

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| E1 | 任意 TCP 出站（LLM API、web-fetch-http、exa/perplexity 搜索） | web/web-fetch-http 等包 | ✅ | guest socket 直接转译宿主 BSD socket，走 iOS 网络栈；青山 LLM 请求更是在 Swift 宿主层直连（不经 iSH） | 02 §6.2；fs/sock.c:38-64 |
| E2 | localhost 多端口监听（host/webserver 127.0.0.1、MCP HTTP） | host/webserver/src/index.ts:61,126 | ✅（附注） | 监听可用（宿主 socket）；iOS 退后台即断，且 0.0.0.0 对外暴露受 iOS 同一沙箱约束——只当会话内临时服务用 | 02 §6.2、§5.4 |
| E3 | DNS 解析（系统级、可配置） | 隐含假设 | ✅（受限成立） | resolv.conf 是宿主 bind mount，与宿主同源；**不可在 guest 改写**（会被刷新覆盖）。特定解析用 hosts/`--resolve` 或宿主处理 | 02 §6.1；ISHKernel.m:847-897 |
| E4 | raw socket / ICMP（ping 探测） | 无显式依赖，生态默认可用 | ❌ | iSH 显式拒绝 SOCK_RAW（含 ICMP）。替代规范：`nc -z -w3 host port`、`wget -q --spider URL`；工具层可拦截 ping 改写 | 02 §6.3；fs/sock.c:48-50 |
| E5 | AF_UNIX socket 文件路径可见性（bind 后 ls 可见、按路径连接） | 生态默认假设 | ❌ | bind 地址被翻译为 `<sock_tmp_prefix><pid>.<id>`，**文件不出现**在 /tmp。替代：本地 IPC 一律 TCP localhost | 02 §6.4；ISHKernel.m:767-780 |
| E6 | SSE 流式下载/大文件上传吞吐（128MB 级） | llm file-store/files-api 上限 | 🟡 | 带宽=宿主，但 guest CPU 是 1/50~1/100 模拟，guest 侧解密/解析成瓶颈。适配：大文件落盘少解析、重试按慢速移动网络设 | 02 §7 CPU 条、§6.2 |

### F. 持久化

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| F1 | SQLite 状态库（storage-sqlite kv facet） | storage-sqlite/src/index.ts:10 `import type { DatabaseSync } from 'node:sqlite'` | ✅ | dsh 的 DB 在 Node 宿主进程内；青山对应物是 Swift 宿主，SQLite3.framework 原生更强。guest 侧如需 CLI sqlite 再 `apk add`（见 V1） | storage-sqlite 源码 |
| F2 | 会话日志 JSONL + zstd 压缩（解压走 node:zlib 纯 API） | session-persistence-jsonl zstd-public-decoder.ts:15 `zstdDecompressSync` | ✅ | 无 native 二进制依赖。青山当前明文 JSONL（单机 iPad 合理，01 已判保留）；要压缩时 Apple Compression（zstd/lzfse）原生可用 | session-persistence-jsonl 源码；01 表二 |
| F3 | 输出溢写临时文件（64KB 内存 → 64MB spill） | bash-local/src/index.ts:38,109-110 | ✅ | 纯文件操作；注意青山读侧仍需 16k 前缀截断防内存（01 P2-10） | bash-local 源码 |
| F4 | 实时写批（200ms 合并延迟） | storage.ts:34 LIVE_WRITE_BATCH_MAX_DELAY_MS | ✅ | Swift 定时器/DispatchSource 等价实现，宿主侧能力 | 01 表 10 |

### G. Node 宿主特有能力

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| G1 | AbortController 协作式取消（工具超时、请求中止） | core/tools + guard/timeout-policy | ✅ | Swift Task cancellation / structured concurrency 完全等价 | 青山 AgentSession 已实践 |
| G2 | worker_threads 隔离执行模型生成代码 | code-runtime/code-runtime-worker-thread/src/index.ts | 🟡 | iSH 里 node（jitless）理论上有 worker_threads 但 jitless 极慢（见 V6）；Swift 侧无等价 JS 隔离。替代：guest 子进程隔离（iSH fork/clone 可用）跑模型代码，或整层降级为"guest shell 即执行环境" | code-runtime 源码；02 §5.1 |
| G3 | async 高并发 IO（多请求、并发 fetch） | agent-loop、web 包 | ✅ | Swift Concurrency/GCD 等价；但**并行度受 C3/C4 环境约束压到 1-2**，非能力缺失 | 02 §7 |
| G4 | npm 生态全家桶（dsh 自身依赖海量包） | dsh package.json 体系 | 🟡 | 宿主功能必须在 Swift 重写（青山已做）；guest 内 node 仅适合轻脚本。npm install 慢 + native 模块需编译（1/50 速度）基本不现实 | 02 §3、§7 |
| G5 | 事件循环低延迟轮询（POLL_INTERVAL_MS=25） | tool-bash-persistent index.ts:22 | ✅ | 青山 60ms 文件轮询，iSH 下足够，语义对齐 | 01 表 3 |
| G6 | ps/procfs 进程巡查（识别进程树成员） | subprocess-local process-inspector（ps-based） | ✅（已适配） | 击杀链在宿主侧已实现（pgid+祖先链）；guest 内 `ps` 可用（宽度排版注意 200 列） | B5；02 §1.4 |

### H. 终端 UI / 输出形态

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| H1 | 全屏 TUI（vim/htop/交互式向导）经 pty 正常工作 | dsh 真 pty + 用户终端渲染 | ❌ | 青山把输出当文本采集（文件协议），光标寻址序列只会产生乱流。替代：强制 CLI 模式（对齐 dsh ENV_OVERRIDES 精神：PAGER=cat、GIT_PAGER=cat、`busybox vi` 禁用） | 02 §1.3/§10 |
| H2 | ANSI 颜色/光标控制可解析 | dsh 用 TERM=dumb+NO_COLOR 规避 | 🟡 | 环境已设 NO_COLOR=1 但 PTY 回显与 `\r\n` 仍污染输出。适配：解析前剥 `\r`、不做 PTY 流行级标记匹配（已踩坑固化） | 02 §1.3/§10 |
| H3 | scrollback 分页回读 | SCROLLBACK_PAGE_LINES=1000 | ✅（已适配） | 文件协议全量 + 16k 截断（数值对齐 dsh maxOutputChars） | 01 表 3 |
| H4 | 输出按 64KB 内存封顶 + 溢写 | maxOutputBytes/spill 机制 | 🟡 | 机制青山未实现（读入后才截断，超大输出会先打爆内存）。适配：读侧 prefix(16_001) 截断（01 P2-10）——环境无碍，纯实现差距 | 01 表二 P2 行 |

### I. 包生态 / 工具链可得性

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| I1 | `apk add` 安装软件包（网络可达 dl-cdn） | 环境已装 python3、node（jitless） | ✅ | HTTPS 出站可用，apk 正常；交互确认按非交互写法 | 02 §1.5、§3 |
| I2 | git 可用（版本控制类任务） | dsh 假设 git 存在 | 🟡 | `apk add git` 可用；但大小写不敏感（D4）+ 性能（D9）限制大仓库。适配：小仓库可用，提醒大小写陷阱 | 02 §3、§4.5 |
| I3 | gcc/make 编译链 | dsh 环境默认编译可用且快 | 🟡 | Alpine 可装 gcc/make，但模拟 1/50~1/100 速度 + fork 闸门：小工具可编译（配 240-600s 超时），大项目不现实。预期失败回退 | 02 §7 |
| I4 | Go 运行时/工具链 | 生态默认 | ❓ | GOMAXPROCS=2 已设说明宿主预留过 go，但 go runtime 对 clone/mmap 的需求在 iSH 的兼容性未实证。验证见 V3 | 02 §7 |
| I5 | pip / npm 装纯解释型包 | 生态默认 | 🟡 | 纯 Python 包基本可用（python3 已装）；JS 包受 jitless node 限制。海量小文件 IO 慢（D9） | 02 §3、§7 |

### J. 安全模型

| # | dsh 能力/假设 | dsh 实现证据 | iSH 判定 | 适配方案 / 替代 | 证据 |
|---|---|---|---|---|---|
| J1 | per-command 沙箱降级：seatbelt/bwrap/landlock/windows-acl 多后端、enforcement=full | sandbox-local/src/index.ts:141,160-161,179-180；node-addon-landlock-run | ❌ | iSH 内 guest 是 root 单沙箱，无 per-command OS 级降级手段（busybox 无 bwrap、无 landlock、无 seatbelt）。替代：**整个 guest 即 iOS 沙箱**（逃逸面为零）+ 青山 ApprovalService 审批制（三策略+白名单+危险正则，fail-closed）+ 命令黑名单。安全边界从"进程级强制"降级为"App 级强制 + 模型侧审批" | sandbox-local 源码；01 表二；02 §9 |
| J2 | 凭据擦除（subprocess spawn 时 scrub env） | subprocess-local spawn.ts "credential-scrubbed environment" | ✅（宿主侧） | 凭据管在 Swift 宿主（Keychain/UserDefaults），iSH 命令拿到的是显式注入的最小 env | 青山执行层实践 |
| J3 | guest 内进程隔离与调试（ptrace/gdb） | iSH 自带 gdb stub | ✅（不适用） | 能力存在但对 Agent 工具无意义；guest 内 `kill` 不会伤害宿主 | 02 §9 |
| J4 | no-op 系统命令的失败可解释性（dsh 真环境自然成功） | 隐含假设 | 🟡 | ping/mount/inotify/watch/ip link set 在 iSH 是必败或 no-op，Agent 会误判。适配：工具系统提示写入 no-op 清单 + 拦截改写 | 02 §9/§10 |

---

## 不可行清单（❌ 汇总——决定青山与 dsh 的能力边界）

1. **经 PTY 写大文件 / 任意长度命令注入**（A5）——4KB 缓冲静默截断，替代：宿主直写 + cp。
2. **文件监听类一切机制**（D2）——inotify stub 永不触发且不报错，替代：轮询。`npm run watch`、nodemon、fs.watch 永久失效。
3. **大小写敏感路径**（D4）——APFS 卷决定，替代：小写命名规范 + 校验。
4. **raw socket / ping**（E4）——iSH 源码显式拒绝，替代：`nc -z` / `wget --spider`。
5. **AF_UNIX socket 路径可见性**（E5）——bind 地址翻译层使路径不可见，替代：TCP localhost IPC。
6. **并行工具调用与并发 job 系统**（C3/C4）——PTY 单通道 + 内存闸门，替代：串行 + 前台单次完成。
7. **跨退后台的后台任务存活**（C1 的长任务面）——iOS 冻结/jetsam，nohup/setsid/disown 无意义，替代：单次调用前台完成 + 提示用户保前台。
8. **全屏 TUI**（H1）——文本采集管线无光标渲染，替代：CLI 化 + ENV_OVERRIDES。
9. **per-command OS 沙箱降级**（J1）——guest 内无 seatbelt/bwrap/landlock，替代：iOS 整体沙箱 + 审批制（安全语义降级，需在产品叙述中明确）。

> 边界结论：青山在**进程并行度、长后台任务、文件监听、网络诊断（ping）、TUI** 五个面上达不到 dsh 的能力；其中 1/2/7 是"静默失败"型（最阴险），必须靠工具层约束兜底。

## 需实证清单（❓ 与若干高风险 🟡 的验证命令）

| # | 假设 | 验证命令（iSH guest 内） | 预期与判定影响 |
|---|---|---|---|
| V1 | fakefs 上 fsync/rename 原子性 + sqlite 完整性（D8） | `apk add sqlite && sqlite3 /tmp/t.db 'pragma journal_mode=wal; create table t(a); insert into t values(1); pragma integrity_check;'`；进程 kill -9 后重开复查 | integrity_check 通过→D8 升 ✅；失败→宿主侧 SQLite 更必要 |
| V2 | busybox ash 对 `set -o pipefail` 的实际支持（02 手册判不支持，新版 busybox ash ≥1.34 已实现） | `set -o pipefail; false \| true; echo $?`（输出 1=支持） | 若支持，A2 适配面收窄，02 §2.8 需修订 |
| V3 | Go 工具链可运行性（I4） | `apk add go && go version && printf 'package main\nfunc main(){println("hi")}' > /tmp/h.go && cd /tmp && go run h.go` | 能跑→I4 升 🟡；clone/mmap panic→I4 转 ❌ |
| V4 | gcc 编译可行性 + 耗时（I3） | `apk add gcc musl-dev && time gcc /tmp/hello.c -o /tmp/hello && /tmp/hello` | 记录编译耗时基线，决定编译类工具是否写进工具描述 |
| V5 | guest 侧 zstd CLI（如需在 guest 压缩会话产物） | `apk add zstd && zstd -V && echo hi \| zstd \| zstd -d` | 一般 ✅；仅 guest 侧需要时才装 |
| V6 | jitless node 的 worker_threads（G2） | `node -e "const {Worker}=require('worker_threads'); new Worker('console.log(1)',{eval:true})"` | 能跑→G2 多一个（慢）选项；崩溃→维持"guest 子进程隔离"替代方案 |
| V7 | bash 安装后进程替换/`/dev/fd`（A1/A2） | `apk add bash && bash -c 'diff <(echo a) <(echo b)'` | 可用→可选装 bash 恢复高级语义；仍判 ❌（如报 /dev/fd 错） |
| V8 | `apk add bash` 后 pipefail 同 V2 | `bash -c 'set -o pipefail; false \| true; echo $?'` | 决定"可选装 bash"路线的收益 |

---

## 统计

映射条目共 **56 条**（A7 + B6 + C5 + D9 + E6 + F4 + G6 + H4 + I5 + J4）。

| 判定 | 条数 | 占比 |
|---|---|---|
| ✅ 直接可行（含"已适配达成"） | 24 | 43% |
| 🟡 需适配 | 20 | 36% |
| ❌ 不可行 | 10 | 18% |
| ❓ 待实证 | 2（D8、I4） | 4% |

> 注：✅ 中约一半是"语义已由青山以不同机制达成"（文件协议、击杀链、宿主侧 SQLite/zstd），不是零成本达成；🟡 中约 5 条（A4、H4 等）属环境无碍的实现差距，可低成本补齐；❌ 中 B6、C3 属"以串行/非交互约定绕过"型。

## 最意外的三个发现

1. **C1 后台任务其实"半可行"**：guest 进程在 App 前台期间确实继续跑，`cmd &` + 轮询日志能撑起分钟级后台作业——真正不可行的只是"跨退后台存活"，不是后台本身。dsh 的 job 语义可以降级移植而非整体砍掉。
2. **J1 安全语义的降级幅度**：dsh 是 per-command 强制沙箱（四后端、enforcement=full），iSH 里连一个对应物都没有；青山的审批制是**模型侧软约束**而非进程侧硬约束——这是边界表里唯一"安全能力实质性倒退"的条目。
3. **F2 zstd 不需要任何替代方案**：dsh 的 zstd 走 `node:zlib` 纯 API（无 native 依赖），意味着会话日志压缩语义可 1:1 移植（Swift Compression 原生支持 zstd），此前"青山明文 JSONL 是妥协"的判断可以升级为"随时可无痛加密压"。
