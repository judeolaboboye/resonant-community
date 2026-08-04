#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block and catches any NSException, returning it instead of crashing.
/// Returns nil if the block executed without throwing.
FOUNDATION_EXTERN NSException * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^block)(void));

/// Reads a pasteboard string entirely inside Objective-C exception handling.
/// Swift frames inside an Objective-C @try block can still terminate on some
/// exceptions, so callers should prefer this wrapper for NSPasteboard reads.
FOUNDATION_EXTERN NSString * _Nullable ObjCSafePasteboardString(
    NSPasteboard *pasteboard,
    NSPasteboardType type,
    NSInteger * _Nullable changeCount,
    NSException * _Nullable * _Nullable exception
);

FOUNDATION_EXTERN NSArray<NSPasteboardItem *> *ObjCSafePasteboardItems(
    NSPasteboard *pasteboard,
    NSException * _Nullable * _Nullable exception
);

FOUNDATION_EXTERN NSArray<NSPasteboardType> *ObjCSafePasteboardTypes(
    NSPasteboardItem *item,
    NSException * _Nullable * _Nullable exception
);

FOUNDATION_EXTERN NSData * _Nullable ObjCSafePasteboardItemData(
    NSPasteboardItem *item,
    NSPasteboardType type,
    NSException * _Nullable * _Nullable exception
);

/// Reads from / writes to NSFileHandle entirely inside Objective-C exception
/// handling. FileHandle's Swift APIs can still surface Objective-C exceptions
/// for broken pipes and invalid handles.
FOUNDATION_EXTERN NSData * _Nullable ObjCSafeFileHandleReadData(
    NSFileHandle *handle,
    NSUInteger length,
    NSException * _Nullable * _Nullable exception
);

FOUNDATION_EXTERN BOOL ObjCSafeFileHandleWriteData(
    NSFileHandle *handle,
    NSData *data,
    NSException * _Nullable * _Nullable exception
);

NS_ASSUME_NONNULL_END
