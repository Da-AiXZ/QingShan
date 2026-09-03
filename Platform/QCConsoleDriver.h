//
//  QCConsoleDriver.h
//  青山 · M0.2
//
//  极简 console TTY 驱动：替代 iSH 的 Terminal.m UI 链。
//  PID1 的 /dev/console 输出 → 内存缓冲 + NSNotification（Swift 侧读取显示）。
//  参照 app/Terminal.m 的 ios_tty_ops 三函数接口。
//

#import <Foundation/Foundation.h>

// console 驱动本体（定义在 QCConsoleDriver.m，QCBoot.m 注册进 tty_drivers[]）
struct tty_driver;
extern struct tty_driver qc_console_driver;

NS_ASSUME_NONNULL_BEGIN

/// console 新输出通知（userInfo: @"text" = NSString 增量）
extern NSString *const QCConsoleOutputNotification;

/// 自启动以来的全部 console 输出（主线程外调用需自行加锁，内部已串行队列保护）
NSString * qcConsoleBuffer(void);

/// 清空 console 缓冲
void qcConsoleBufferClear(void);

NS_ASSUME_NONNULL_END
