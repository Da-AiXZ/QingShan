//
//  QCExecutor.m
//  青山 · M0.2
//
//  改造自 ish-arm64 app/ISHShellExecutor.m：
//   - 移除 AppDelegate.h 依赖（原文件仅 import 未使用）
//   - 通知名换 QCProcessExitedNotification（kernel/task.c 发出的同一事件流）
//   - 其余执行路径（become_new_init_child + fd 重定向 + 双 reader 线程）保持原样
//

#import "QCExecutor.h"
#import "QCBoot.h"

#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/init.h"
#include "kernel/signal.h"
#include "fs/devices.h"
#include "fs/real.h"

#import <UIKit/UIKit.h>   // UIApplication idle 窥探主线程活性（原文件即如此）

// ---- ISHShellExecutionResult 等价实现 ----

@interface QCExecutionResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) QCExecutorError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
@end

@implementation QCExecutionResult
@end

#pragma mark - Execution Context

@interface QCExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy) QCLineCallback lineCallback;
@property (nonatomic, copy) QCCompletionCallback completion;
@property (nonatomic) NSMutableString *stdoutBuffer;
@property (nonatomic) NSMutableString *stderrBuffer;
@property (nonatomic) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) QCExecutionResult *result;
@property (atomic) BOOL isCompleted;

- (int *)stdoutPipe;
- (int *)stderrPipe;
@end

@implementation QCExecutionContext
- (int *)stdoutPipe { return _stdoutPipe; }
- (int *)stderrPipe { return _stderrPipe; }
- (instancetype)init {
    if (self = [super init]) {
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
        _stdoutPipe[0] = -1; _stdoutPipe[1] = -1;
        _stderrPipe[0] = -1; _stderrPipe[1] = -1;
        _result = [[QCExecutionResult alloc] init];
        _result.error = QCExecutorErrorNone;
    }
    return self;
}
- (void)cleanup {
    if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
    if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
    if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
    if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
}
@end

static NSMutableDictionary<NSNumber *, QCExecutionContext *> *_activeExecutions;
static dispatch_queue_t _readerQueue;
static dispatch_once_t _onceToken;

// Y8：按完整 UTF-8 序列截断（M0 简化版：渐进解码失败退 Latin1）
static NSString * QCDecodeChunk(NSData *chunk, NSMutableString *pending) {
    if (chunk.length == 0) return @"";
    NSMutableData *data = [pending mutableCopy] ?: [NSMutableData data];
    [data appendData:chunk];
    [pending setString:@""];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;
    // 尝试去掉尾部不完整序列（最多回退 3 字节）
    for (NSUInteger back = 1; back <= 3 && data.length > back; back++) {
        NSData *head = [data subdataWithRange:NSMakeRange(0, data.length - back)];
        NSString *headStr = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
        if (headStr) {
            NSString *tail = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(data.length - back, back)] encoding:NSISOLatin1StringEncoding] ?: @"";
            [pending appendString:tail];   // 交给下一块拼
            return headStr;
        }
    }
    NSString *fallback = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    return fallback;
}

@implementation QCExecutor

+ (void)initialize {
    if (self == [QCExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        dispatch_once(&_onceToken, ^{
            _readerQueue = dispatch_queue_create("com.qingshan.executor.reader", DISPATCH_QUEUE_CONCURRENT);
        });
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:QCProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable QCLineCallback)lineCallback
           completion:(nullable QCCompletionCallback)completion {
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", command]
                       environment:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(nullable QCLineCallback)lineCallback
           completion:(nullable QCCompletionCallback)completion {

    QCExecutionContext *ctx = [[QCExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];

    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"QCExecutor: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return QCExecutorErrorProcessCreationFailed;
    }

    fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK);
    fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK);

    struct task *saved_current = current;

    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"QCExecutor: become_new_init_child failed: %d", err);
        return QCExecutorErrorProcessCreationFailed;
    }

    struct task *task = current;

    // stdin = /dev/null；stdout/stderr = 管道
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd) {
        stdin_fd->real_fd = open("/dev/null", O_RDONLY);
        task->files->files[0] = stdin_fd;
    }
    struct fd *stdout_fd = adhoc_fd_create(&realfs_fdops);
    if (stdout_fd) {
        stdout_fd->real_fd = dup([ctx stdoutPipe][1]);
        task->files->files[1] = stdout_fd;
    }
    struct fd *stderr_fd = adhoc_fd_create(&realfs_fdops);
    if (stderr_fd) {
        stderr_fd->real_fd = dup([ctx stderrPipe][1]);
        task->files->files[2] = stderr_fd;
    }

    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // argv：NUL 分隔连续缓冲（do_execve 约定）
    NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
    if (arguments) [fullArgs addObjectsFromArray:arguments];

    char argv_buf[4096];
    size_t pos = 0;
    for (NSString *arg in fullArgs) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len + 1 >= sizeof(argv_buf)) {
            current = saved_current;
            [ctx cleanup];
            NSLog(@"QCExecutor: argv too long");
            return QCExecutorErrorExecFailed;
        }
        memcpy(argv_buf + pos, str, len);
        pos += len;
    }
    argv_buf[pos] = '\0';

    // envp：NUL 分隔字面量
    NSMutableString *envp_str = [NSMutableString string];
    [envp_str appendString:@"TERM=xterm-256color\0"];
    [envp_str appendString:@"HOME=/root\0"];
    [envp_str appendString:@"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"];
    [envp_str appendString:@"PYTHONMALLOC=malloc\0"];
    if (environment) {
        for (NSString *key in environment) {
            [envp_str appendFormat:@"%@=%@\0", key, environment[key]];
        }
    }
    [envp_str appendString:@"\0"];

    err = do_execve(executable.UTF8String, fullArgs.count, argv_buf, envp_str.UTF8String);
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"QCExecutor: do_execve failed: %d", err);
        return QCExecutorErrorExecFailed;
    }

    ctx.guestPid = task->pid;
    ctx.result.pid = ctx.guestPid;
    task_start(task);
    current = saved_current;

    @synchronized (_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
    }

    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];

    return ctx.guestPid;
}

+ (nullable QCExecutionResult *)executeCommandSync:(NSString *)command
                                           timeout:(NSTimeInterval)timeout
                                      lineCallback:(nullable QCLineCallback)lineCallback {
    QCExecutionContext *ctx = [[QCExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.waitSemaphore = dispatch_semaphore_create(0);
    ctx.startTime = [NSDate date];

    __block QCExecutionResult *result = nil;
    int pid = [self executeCommand:command
                      lineCallback:lineCallback
                        completion:^(QCExecutionResult *r) { result = r; dispatch_semaphore_signal(ctx.waitSemaphore); }];
    if (pid < 0) {
        result = [[QCExecutionResult alloc] init];
        result.error = (QCExecutorError)pid;
        result.exitCode = -1;
        return result;
    }
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    if (dispatch_semaphore_wait(ctx.waitSemaphore, waitTime) != 0) {
        [self killProcess:pid withSignal:SIGKILL_];   // guest 信号值（kernel/signal.h）
        result = [[QCExecutionResult alloc] init];
        result.error = QCExecutorErrorTimeout;
        result.pid = pid;
        result.exitCode = -1;
        result.output = @"";
        result.errorOutput = @"";
    }
    return result;
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task) send_signal(task, signal, info);
    unlock(&pids_lock);
    return task != NULL;
}

#pragma mark - Readers

+ (void)startReaderForPipe:(int)fd context:(QCExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    dispatch_async(_readerQueue, ^{
        NSMutableString *accumulated = isStdErr ? ctx.stderrBuffer : ctx.stdoutBuffer;
        NSMutableString *pendingUtf8 = [NSMutableString string];
        char buf[4096];
        ssize_t n;
        while (true) {
            n = read(fd, buf, sizeof(buf));
            if (n > 0) {
                NSString *chunk = QCDecodeChunk([NSData dataWithBytes:buf length:n], pendingUtf8);
                if (chunk.length) {
                    [accumulated appendString:chunk];
                    if (ctx.lineCallback) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [chunk enumerateSubstringsInRange:NSMakeRange(0, chunk.length)
                                                     options:NSStringEnumerationByLines
                                                  usingBlock:^(NSString *line, NSRange r, NSRange *, BOOL *stop) {
                                if (r.location != NSNotFound) [ctx.lineCallback(line, isStdErr)];
                            }];
                        });
                    }
                }
            } else if (n == 0) {
                break;                       // 写端关闭
            } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                [NSThread sleepForTimeInterval:0.02];   // 25ms 轮询语义（对齐 dsh）
            } else {
                break;                       // 其他错误退出
            }
        }
        close(fd);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishContext:ctx];
        });
    });
}

+ (void)finishContext:(QCExecutionContext *)ctx {
    if (ctx.isCompleted) return;
    // 等待 exit 通知带出 exitCode；此处仅在两管道都读尽后兜底 finalize
    ctx.result.output = [ctx.stdoutBuffer copy];
    ctx.result.errorOutput = [ctx.stderrBuffer copy];
    ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];
    if (ctx.result.exitCode == 0 && ctx.result.error == QCExecutorErrorNone) {
        // exit 通知未达时（防御）：按完成处理，避免悬挂
        ctx.isCompleted = YES;
        if (ctx.completion) ctx.completion(ctx.result);
    }
}

#pragma mark - Process Exit

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    QCExecutionContext *ctx;
    @synchronized (_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
        if (!ctx) return;
        [_activeExecutions removeObjectForKey:@(pid)];
    }
    if (ctx.isCompleted) return;
    ctx.isCompleted = YES;

    ctx.result.exitCode = exitCode;
    ctx.result.output = [ctx.stdoutBuffer copy];
    ctx.result.errorOutput = [ctx.stderrBuffer copy];
    ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];
    if (exitCode != 0) ctx.result.error = QCExecutorErrorNone;  // 非零 exit 是正常语义，不是执行器错误

    if (ctx.completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ ctx.completion(ctx.result); });
    }
}

@end
