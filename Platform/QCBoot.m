//
//  QCBoot.m
//  青山 · M0.2
//
//  启动编排：照 ish-arm64 app/AppDelegate.m 的 -boot 骨架裁剪（每步的"为什么"见架构方案 §6.1）。
//  裁剪项：clipboard/location 设备、iosfs 挂载、RootfsPatch、UserPreferences、hostname 覆盖。
//  保留项：mount_root → 设备节点 → exit/die hook → socket 前缀(Y2) → DNS → console stdio → PID1 exec。
//

#import "QCBoot.h"
#import "QCConsoleDriver.h"

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "fs/dyndev.h"
#include "fs/devices.h"
#include "fs/path.h"
#include "fs/fake.h"
#include "fs/sock.h"

// die_handler 声明在 kernel/log.c（无头文件导出），照 AppDelegate.m 的用法自行 extern
extern void (*die_handler)(const char *msg);

#import <Foundation/Foundation.h>
#import <arpa/nameser.h>
#import <resolv.h>

// 进程退出通知名 —— kernel/task.c 发出，QCExecutor 监听（声明在 QCBoot.h）
NSString *const QCProcessExitedNotification = @"ProcessExitedNotification";

static int _booted = 0;
static int _bootError = 0;

// ---- exit / die hooks（照 ios_handle_exit / ios_handle_die 裁剪） ----

static void qc_handle_exit(struct task *task, int code) {
    // 只关心 init 及 init 的直接子进程（对齐原实现注释）
    if (task->parent != NULL && task->parent->parent != NULL)
        return;
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QCProcessExitedNotification
                                                            object:nil
                                                          userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

static void qc_handle_die(const char *msg) {
    NSString *message = [NSString stringWithFormat:@"%s: %s", __func__, msg];
    NSLog(@"QCBoot kernel die: %@", message);
}

static void qc_configure_dns(void) {
    // 照 AppDelegate configureDns：取宿主系统 DNS 写进 guest /etc/resolv.conf
    struct __res_state res;
    if (EXIT_SUCCESS != res_ninit(&res)) {
        return;
    }
    NSMutableString *conf = [NSMutableString new];
    if (res.dnsrch[0] != NULL) {
        [conf appendString:@"search"];
        for (int i = 0; res.dnsrch[i] != NULL; i++) {
            [conf appendFormat:@" %s", res.dnsrch[i]];
        }
        [conf appendString:@"\n"];
    }
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    char address[NI_MAXHOST];
    for (int i = 0; i < found; i++) {
        union res_sockaddr_union s = servers[i];
        if (s.sin.sin_len == 0) continue;
        getnameinfo((struct sockaddr *) &s.sin, s.sin.sin_len,
                    address, sizeof(address), NULL, 0, NI_NUMERICHOST);
        [conf appendFormat:@"nameserver %s\n", address];
    }

    current = pid_get_task(1);
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, conf.UTF8String, [conf lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        fd_close(fd);
    }
}

int qc_boot(NSString *rootPath, NSString * _Nullable * _Nullable error) {
    if (_booted) return 0;

    NSString *dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    int err = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    if (err < 0) {
        if (error) *error = [NSString stringWithFormat:@"mount_root failed: %d", err];
        _bootError = err;
        return err;
    }

    // M0 裁剪：不挂 iosfs（iOS 容器互通挂载），uname 验证不需要；后续里程碑按需回补
    err = become_first_process();
    if (err < 0) {
        if (error) *error = [NSString stringWithFormat:@"become_first_process failed: %d", err];
        _bootError = err;
        return err;
    }

    // ---- 设备节点（照 AppDelegate.boot；砍 clipboard/location） ----
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty3", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/tty4", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 4));
    generic_mknodat(AT_PWD, "/dev/tty5", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/tty6", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 6));
    generic_mknodat(AT_PWD, "/dev/tty7", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 7));

    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));

    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    // 根目录权限修复（对齐原实现注释）
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // ---- exit/die hooks ----
    exit_hook = qc_handle_exit;
    die_handler = qc_handle_die;

    // ---- socket 前缀：必须早于任何 guest 进程（Y2：路径剥 /private、≤104 字节） ----
#if !TARGET_OS_SIMULATOR
    NSString *sockTmp = [NSTemporaryDirectory() stringByAppendingString:@"ishsock"];
    sock_tmp_prefix = strdup(sockTmp.UTF8String);
#endif

    // ---- console：极简驱动（QCConsoleDriver）替代 Terminal.m UI 链 ----
    tty_drivers[TTY_CONSOLE_MAJOR] = &qc_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        if (error) *error = [NSString stringWithFormat:@"create_stdio failed: %d", err];
        _bootError = err;
        return err;
    }

    qc_configure_dns();

    // ---- PID1：/bin/sh -c "uname -a"（M0 验收命令；后续里程碑改为常驻 bash） ----
    // do_execve 约定：argv/envp 均为 NUL 分隔的连续缓冲（照 AppDelegate 的 convertCommand 产物形态）
    char argv_buf[512];
    size_t pos = 0;
    const char *parts[] = {"/bin/sh", "-c",
        "uname -a; echo; echo '青山 M0.2 · Alpine/AArch64 已启动'; id; cat /etc/alpine-release"};
    for (int i = 0; i < 3; i++) {
        size_t len = strlen(parts[i]) + 1;
        memcpy(argv_buf + pos, parts[i], len);
        pos += len;
    }
    argv_buf[pos] = '\0'; // 双 NUL 收尾
    const char *envp =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "PYTHONMALLOC=malloc\0"
        ;
    err = do_execve(argv_buf, 3, argv_buf, envp);
    if (err < 0) {
        if (error) *error = [NSString stringWithFormat:@"do_execve failed: %d", err];
        _bootError = err;
        return err;
    }
    task_start(current);

    _booted = 1;
    return 0;
}

BOOL qc_booted(void) {
    return _booted;
}
