//
//  QCBoot.h
//  青山 · M0.2
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动 iSH 内核（照 AppDelegate.boot 骨架裁剪）。
/// @param rootPath fakefs 根目录（内含 data/ 与 meta.db，来自首启解包）
/// @param error 失败信息（可空传入）
/// @return 0 成功，负数为内核错误码
int qc_boot(NSString *rootPath, NSString * _Nullable * _Nullable error);

/// 内核是否已启动
BOOL qc_booted(void);

NS_ASSUME_NONNULL_END
