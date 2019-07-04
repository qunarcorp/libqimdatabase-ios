//
//  QIMDataBaseQueue.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "QIMDataBaseQueue.h"
#import "QIMDataBase.h"

#if QIMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else

#import <sqlite3.h>

#endif

typedef NS_ENUM(NSInteger, QIMDBTransaction) {
    QIMDBTransactionExclusive,
    QIMDBTransactionDeferred,
    QIMDBTransactionImmediate,
};

/*
 
 Note: we call [self retain]; before using dispatch_sync, just incase
 QIMDataBaseQueue is released on another thread and we're in the middle of doing
 something in dispatch_sync
 
 */

/*
 * A key used to associate the QIMDataBaseQueue object with the dispatch_queue_t it uses.
 * This in turn is used for deadlock detection by seeing if inDatabase: is called on
 * the queue's dispatch queue, which should not happen and causes a deadlock.
 */
static const void *const kDispatchQueueSpecificKey = &kDispatchQueueSpecificKey;
static const void *const kDispatchWriteQueueSpecificKey = &kDispatchWriteQueueSpecificKey;

@interface QIMDataBaseQueue () {
    dispatch_queue_t _queue;
    dispatch_queue_t _writeQueue;
    QIMDataBase *_db;
}
@end

@implementation QIMDataBaseQueue

+ (instancetype)databaseQueueWithPath:(NSString *)aPath {
    QIMDataBaseQueue *q = [[self alloc] initWithPath:aPath];

    QIMDBAutorelease(q);

    return q;
}

+ (instancetype)databaseQueueWithURL:(NSURL *)url {
    return [self databaseQueueWithPath:url.path];
}

+ (instancetype)databaseQueueWithPath:(NSString *)aPath flags:(int)openFlags {
    QIMDataBaseQueue *q = [[self alloc] initWithPath:aPath flags:openFlags];

    QIMDBAutorelease(q);

    return q;
}

+ (instancetype)databaseQueueWithURL:(NSURL *)url flags:(int)openFlags {
    return [self databaseQueueWithPath:url.path flags:openFlags];
}

+ (Class)databaseClass {
    return [QIMDataBase class];
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags vfs:(NSString *)vfsName {
    return [self initWithPath:url.path flags:openFlags vfs:vfsName];
}

- (instancetype)initWithPath:(NSString *)aPath flags:(int)openFlags vfs:(NSString *)vfsName {
    self = [super init];

    if (self != nil) {

        _db = [[[self class] databaseClass] databaseWithPath:aPath];
        QIMDBRetain(_db);

#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:openFlags vfs:vfsName];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"Could not create database queue for path %@", aPath);
            QIMDBRelease(self);
            return 0x00;
        }

        _path = QIMDBReturnRetained(aPath);

        _queue = dispatch_queue_create([[NSString stringWithFormat:@"qimdb.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, kDispatchQueueSpecificKey, (__bridge void *) self, NULL);
        _writeQueue = dispatch_queue_create([[NSString stringWithFormat:@"qimdb-write.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_writeQueue, kDispatchWriteQueueSpecificKey, (__bridge void *) self, NULL);

        _openFlags = openFlags;
        _vfsName = [vfsName copy];
    }

    return self;
}

- (instancetype)initWithPath:(NSString *)aPath flags:(int)openFlags {
    return [self initWithPath:aPath flags:openFlags vfs:nil];
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags {
    return [self initWithPath:url.path flags:openFlags vfs:nil];
}

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithPath:url.path];
}

- (instancetype)initWithPath:(NSString *)aPath {
    // default flags for sqlite3_open
    return [self initWithPath:aPath flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX vfs:nil];
}

- (instancetype)init {
    return [self initWithPath:nil];
}

- (void)dealloc {
    QIMDBRelease(_db);
    QIMDBRelease(_path);
    QIMDBRelease(_vfsName);

    if (_queue) {
        QIMDBDispatchQueueRelease(_queue);
        _queue = 0x00;
    }
    if (_writeQueue) {
        QIMDBDispatchQueueRelease(_writeQueue);
        _writeQueue = 0x00;
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)close {
    QIMDBRetain(self);
    dispatch_sync(_queue, ^() {
        [self->_db close];
        QIMDBRelease(_db);
        self->_db = 0x00;
    });
    QIMDBRelease(self);
}

- (void)interrupt {
    [[self database] interrupt];
}

- (QIMDataBase *)database {
    if (![_db isOpen]) {
        if (!_db) {
            _db = QIMDBReturnRetained([[[self class] databaseClass] databaseWithPath:_path]);
        }

#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:_openFlags vfs:_vfsName];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"QIMDataBaseQueue could not reopen database for path %@", _path);
            QIMDBRelease(_db);
            _db = 0x00;
            return 0x00;
        }
    }

    return _db;
}

- (void)inDatabase:(__attribute__((noescape)) void (^)(QIMDataBase *db))block {
#ifndef NDEBUG
    /* Get the currently executing queue (which should probably be nil, but in theory could be another DB queue
     * and then check it against self to make sure we're not about to deadlock. */
    QIMDataBaseQueue *currentSyncQueue = (__bridge id) dispatch_get_specific(kDispatchQueueSpecificKey);
    assert(currentSyncQueue != self && "inDatabase: was called reentrantly on the same queue, which would lead to a deadlock");
#endif

    QIMDBRetain(self);

    dispatch_sync(_queue, ^() {

        QIMDataBase *db = [self database];

        block(db);

        if ([db hasOpenResultSets]) {
            NSLog(@"Warning: there is at least one open result set around after performing [QIMDataBaseQueue inDatabase:]");

#if defined(DEBUG) && DEBUG
            NSSet *openSetCopy = QIMDBReturnAutoreleased([[db valueForKey:@"_openResultSets"] copy]);
            for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy) {
                DataReader *rs = (DataReader *) [rsInWrappedInATastyValueMeal pointerValue];
                NSLog(@"query: '%@'", [rs query]);
            }
#endif
        }
    });

    QIMDBRelease(self);
}

- (void)beginTransaction:(QIMDBTransaction)transaction withBlock:(void (^)(QIMDataBase *db, BOOL *rollback))block {
    QIMDBRetain(self);
    dispatch_sync(_writeQueue, ^() {

        BOOL shouldRollback = NO;

        switch (transaction) {
            case QIMDBTransactionExclusive:
                [[self database] beginTransaction];
                break;
            case QIMDBTransactionDeferred:
                [[self database] beginDeferredTransaction];
                break;
            case QIMDBTransactionImmediate:
                [[self database] beginImmediateTransaction];
                break;
        }

        block([self database], &shouldRollback);

        if (shouldRollback) {
            [[self database] rollback];
        } else {
            [[self database] commit];
        }
    });

    QIMDBRelease(self);
}

- (void)inTransaction:(__attribute__((noescape)) void (^)(QIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:QIMDBTransactionExclusive withBlock:block];
}

- (void)inDeferredTransaction:(__attribute__((noescape)) void (^)(QIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:QIMDBTransactionDeferred withBlock:block];
}

- (void)inExclusiveTransaction:(__attribute__((noescape)) void (^)(QIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:QIMDBTransactionExclusive withBlock:block];
}

- (void)syncUsingTransaction:(__attribute__((noescape)) void (^)(QIMDataBase *_Nonnull, BOOL *_Nonnull))block {
    [self beginTransaction:QIMDBTransactionExclusive withBlock:block];
}

- (NSError *)inSavePoint:(__attribute__((noescape)) void (^)(QIMDataBase *db, BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    static unsigned long savePointIdx = 0;
    __block NSError *err = 0x00;
    QIMDBRetain(self);
    dispatch_sync(_writeQueue, ^() {

        NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];

        BOOL shouldRollback = NO;

        if ([[self database] startSavePointWithName:name error:&err]) {

            block([self database], &shouldRollback);

            if (shouldRollback) {
                // We need to rollback and release this savepoint to remove it
                [[self database] rollbackToSavePointWithName:name error:&err];
            }
            [[self database] releaseSavePointWithName:name error:&err];

        }
    });
    QIMDBRelease(self);
    return err;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"QIMDB", nil);
    if (_db.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"QIMDataBase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

- (BOOL)checkpoint:(QIMDBCheckpointMode)mode error:(NSError *__autoreleasing *)error {
    return [self checkpoint:mode name:nil logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(QIMDBCheckpointMode)mode name:(NSString *)name error:(NSError *__autoreleasing *)error {
    return [self checkpoint:mode name:name logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(QIMDBCheckpointMode)mode name:(NSString *)name logFrameCount:(int *_Nullable)logFrameCount checkpointCount:(int *_Nullable)checkpointCount error:(NSError *__autoreleasing _Nullable

* _Nullable)error
{
    __block BOOL result;
    __block NSError *blockError;

    QIMDBRetain(self);
    dispatch_sync(_writeQueue, ^() {
        result = [self.database checkpoint:mode name:name logFrameCount:logFrameCount checkpointCount:checkpointCount error:&blockError];
    });
    QIMDBRelease(self);

    if (error) {
        *error = blockError;
    }
    return result;
}

@end
