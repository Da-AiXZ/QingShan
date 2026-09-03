//
//  QCExecutor.h
//  青山 · M0.2
//
//  命令执行桥：照 ish-arm64 app/ISHShellExecutor.h 原样裁剪（去 AppDelegate 依赖）。
//  后续里程碑（ExecCoordinator/超时四层兜底/PTY 持久会话）在此文件基础上演进。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, QCExecutorError) {
    QCExecutorErrorNone = 0,
    QCExecutorErrorProcessCreationFailed = -1,
    QCExecutorErrorExecFailed = -2,
    QCExecutorErrorTimeout = -3,
    QCExecutorErrorCancelled = -4,
};

@interface QCExecutionResult : NSObject
@property (nonatomic, readonly) int exitCode;
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) QCExecutorError error;
@property (nonatomic, readonly, copy) NSString *output;
@property (nonatomic, readonly, copy) NSString *errorOutput;
@property (nonatomic, readonly) NSTimeInterval duration;
@end

typedef void (^QCLineCallback)(NSString *line, BOOL isStdErr);
typedef void (^QCCompletionCallback)(QCExecutionResult *result);

@interface QCExecutor : NSObject

+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable QCLineCallback)lineCallback
           completion:(nullable QCCompletionCallback)completion;

+ (nullable QCExecutionResult *)executeCommandSync:(NSString *)command
                                           timeout:(NSTimeInterval)timeout
                                      lineCallback:(nullable QCLineCallback)lineCallback;

+ (BOOL)killProcess:(int)pid withSignal:(int)signal;

@end

NS_ASSUME_NONNULL_END
