#import "include/ObjCExceptionCatcher.h"
#import <fcntl.h>

NSException * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

NSString * _Nullable ObjCSafePasteboardString(
    NSPasteboard *pasteboard,
    NSPasteboardType type,
    NSInteger * _Nullable changeCount,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        if (changeCount != NULL) {
            *changeCount = pasteboard.changeCount;
        }
        if (pasteboard == nil || type == nil) {
            return nil;
        }

        // Read via the high-level accessor, which copies the value in a single
        // call. Enumerating `pasteboardItems` and holding NSPasteboardItem
        // references across `-types` / `-dataForType:` calls can crash with
        // EXC_BAD_ACCESS / "EXC_BREAKPOINT: retain" when another process mutates
        // the system pasteboard mid-read. Those are Mach exceptions that this
        // surrounding @try/@catch cannot trap, so minimize that window.
        return [pasteboard stringForType:type];
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return nil;
    }
}

NSArray<NSPasteboardItem *> *ObjCSafePasteboardItems(
    NSPasteboard *pasteboard,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        return pasteboard.pasteboardItems ?: @[];
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return @[];
    }
}

NSArray<NSPasteboardType> *ObjCSafePasteboardTypes(
    NSPasteboardItem *item,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        return item.types ?: @[];
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return @[];
    }
}

NSData * _Nullable ObjCSafePasteboardItemData(
    NSPasteboardItem *item,
    NSPasteboardType type,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        return [item dataForType:type];
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return nil;
    }
}

NSData * _Nullable ObjCSafeFileHandleReadData(
    NSFileHandle *handle,
    NSUInteger length,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        if (handle == nil) {
            return nil;
        }
        return [handle readDataOfLength:length];
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return nil;
    }
}

BOOL ObjCSafeFileHandleWriteData(
    NSFileHandle *handle,
    NSData *data,
    NSException * _Nullable * _Nullable exception
) {
    @try {
        if (exception != NULL) {
            *exception = nil;
        }
        if (handle == nil || data == nil) {
            return NO;
        }
        (void)fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1);
        [handle writeData:data];
        return YES;
    } @catch (NSException *caughtException) {
        if (exception != NULL) {
            *exception = caughtException;
        }
        return NO;
    }
}
