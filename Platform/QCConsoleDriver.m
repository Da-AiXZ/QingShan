//
//  QCConsoleDriver.m
//  青山 · M0.2
//

#import "QCConsoleDriver.h"

// iSH C 接口（头路径指向 Vendor/include/ish）
#include "fs/tty.h"
#include "fs/devices.h"

NSString *const QCConsoleOutputNotification = @"QCConsoleOutputNotification";

static NSMutableString *_buffer;
static dispatch_queue_t _bufferQueue;
static struct tty *_consoleTty;

NSString * qcConsoleBuffer(void) {
    @synchronized (_buffer) {
        return [_buffer copy];
    }
}

void qcConsoleBufferClear(void) {
    @synchronized (_buffer) {
        [_buffer setString:@""];
    }
}

static void qc_append_output(const char *buf, size_t len) {
    // UTF-8 边界安全解码：失败退 Latin1（Y8 语义的简化版，M0 足够）
    NSString *s = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    if (!s) {
        s = [[NSString alloc] initWithBytes:buf length:len encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    @synchronized (_buffer) {
        [_buffer appendString:s];
        // 环形保护：缓冲超过 512KB 截头（M0 用不到长输出）
        if (_buffer.length > 512 * 1024) {
            [_buffer deleteCharactersInRange:NSMakeRange(0, _buffer.length - 256 * 1024)];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QCConsoleOutputNotification
                                                            object:nil userInfo:@{@"text": s}];
    });
}

#pragma mark - tty_driver_ops（接口对齐 app/Terminal.m ios_tty_ops）

static int qc_tty_init(struct tty *tty) {
    _consoleTty = tty;
    return 0;
}

static int qc_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void)tty; (void)blocking;
    qc_append_output(buf, len);
    return (int)len;
}

static void qc_tty_cleanup(struct tty *tty) {
    (void)tty;
    _consoleTty = NULL;
}

struct tty_driver_ops qc_tty_ops = {
    .init = qc_tty_init,
    .write = qc_tty_write,
    .cleanup = qc_tty_cleanup,
};

// TTY_CONSOLE_MAJOR 需要 fs/devices.h；这里通过 QCBoot.m 传入注册，
// 驱动本体在此定义（对齐 Terminal.m 的 DEFINE_TTY_DRIVER 用法）
DEFINE_TTY_DRIVER(qc_console_driver, &qc_tty_ops, TTY_CONSOLE_MAJOR, 64);
