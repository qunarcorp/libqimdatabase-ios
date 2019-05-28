//
//  QIMDataBaseQueueManager.h
//  QIMDataBase
//
//  Created by lilu on 2019/5/28.
//

#if QIMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else
#import <sqlite3.h>
#endif

#import "QIMDataBaseQueueManager.h"
#import "Database.h"

@interface QIMDataBaseQueueManager ()

@property (nonatomic, strong) dispatch_queue_t lockQueue;
@property (nonatomic, strong) NSMutableArray   *databaseInPool;
@property (nonatomic, strong) NSMutableArray   *databaseOutPool;

- (void)pushDatabaseBackInPool:(DatabaseOperator*)db;
- (DatabaseOperator*)db;

@end


@implementation QIMDataBaseQueueManager

static QIMDataBaseQueueManager *_dbQueueManager = nil;
+ (instancetype)databasePoolWithPath:(NSString *)aPath {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dbQueueManager = [[QIMDataBaseQueueManager alloc] initWithPath:aPath];
    });
    return _dbQueueManager;
}

- (instancetype)initWithPath:(NSString*)aPath {
    
    self = [super init];
    
    if (self != nil) {
        _path               = [aPath copy];
        _lockQueue          = dispatch_queue_create([[NSString stringWithFormat:@"qimdb.%@", self] UTF8String], NULL);
        _databaseInPool     = [NSMutableArray arrayWithCapacity:3];
        _databaseOutPool    = [NSMutableArray arrayWithCapacity:3];
        _maximumNumberOfDatabasesToCreate = 10;
        [self addObserver:self forKeyPath:@"self.databaseInPool" options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld context:nil];
        [self addObserver:self forKeyPath:@"self.databaseOutPool" options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld context:nil];
    }
    
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context
{
    if (object == self && [keyPath isEqualToString:@"self.databaseInPool"]) {
        NSLog(@"change : %@", change);
    } else if ([keyPath isEqualToString:@"self.databaseOutPool"]) {
        NSLog(@"change : %@", change);
    } else {
        
    }
}

- (instancetype)init {
    return [self initWithPath:nil];
}

+ (Class)databaseClass {
    return [DatabaseOperator class];
}

- (void)executeLocked:(void (^)(void))aBlock {
    dispatch_sync(_lockQueue, aBlock);
}

- (void)pushDatabaseBackInPool:(Database*)db {
    
    if (!db) { // db can be null if we set an upper bound on the # of databases to create.
        return;
    }
    
    [self executeLocked:^() {
        
        if ([self.databaseInPool containsObject:db]) {
            [[NSException exceptionWithName:@"Database already in pool" reason:@"The QIMDatabase being put back into the pool is already present in the pool" userInfo:nil] raise];
        }
        
        [self.databaseInPool addObject:db];
        [self.databaseOutPool removeObject:db];
        
    }];
}

- (BOOL)OpenByFullPath:(NSString *)dbFilePath {
    return YES;
    /*
    if ([[_databaseMapping allKeys] containsObject:dbFilePath])
        return YES;
    
    BOOL opened = NO;
    Database *db = [[Database alloc] init];
    DatabaseOperator *database = [[DatabaseOperator alloc] initWithDatabase:db];
    if ([db open:dbFilePath usingCurrentThread:NO]) {
        [_databaseMapping setObject:database forKey:dbFilePath];
        opened = YES;
    } else {
        NSLog(@"Failed to open database: %s", sqlite3_errmsg(database));
    }
    
    NSLog(@"sqlite3_libversion : %s", sqlite3_libversion());
    NSLog(@"sqlite3_threadsafe : %d", sqlite3_threadsafe());
    
    [db release];
    [database release];
    return opened;
    */
}

- (BOOL)CloseByFullPath:(NSString *)dbFilePath {
    /*
    if ([[_databaseMapping allKeys] containsObject:dbFilePath]) {
        DatabaseOperator *db = [_databaseMapping objectForKey:dbFilePath];
        BOOL ret = [[db database] close];
        [_databaseMapping removeObjectForKey:dbFilePath];
        return ret;
    }
     */
    return YES;
}

- (DatabaseOperator *)db {
    
    __block DatabaseOperator *db;
    
    
    [self executeLocked:^() {
        db = [self.databaseInPool lastObject];
        
        BOOL shouldNotifyDelegate = NO;
        
        if (db) {
            [self.databaseOutPool addObject:db];
            [self.databaseInPool removeLastObject];
        } else {
            
            if (self.maximumNumberOfDatabasesToCreate) {
                NSUInteger currentCount = [self.databaseOutPool count] + [self.databaseInPool count];
                
                if (currentCount >= self.maximumNumberOfDatabasesToCreate) {
                    NSLog(@"Maximum number of databases (%ld) has already been reached!", (long)currentCount);
                    return;
                }
            }
            Database *database = [[Database alloc] init];
            db = [[DatabaseOperator alloc] initWithDatabase:database];
            shouldNotifyDelegate = YES;
        }
        BOOL success = [db.database open:self.path usingCurrentThread:NO];
        if (success) {
            //It should not get added in the pool twice if lastObject was found
            if (![self.databaseOutPool containsObject:db]) {
                [self.databaseOutPool addObject:db];
            }
        } else {
            NSLog(@"Could not open up the database at path %@", self.path);
            db = nil;
        }
    }];
    
    return db;
}

- (NSUInteger)countOfCheckedInDatabases {
    
    __block NSUInteger count;
    
    [self executeLocked:^() {
        count = [self.databaseInPool count];
    }];
    
    return count;
}

- (NSUInteger)countOfCheckedOutDatabases {
    
    __block NSUInteger count;
    
    [self executeLocked:^() {
        count = [self.databaseOutPool count];
    }];
    
    return count;
}

- (NSUInteger)countOfOpenDatabases {
    __block NSUInteger count;
    
    [self executeLocked:^() {
        count = [self.databaseOutPool count] + [self.databaseInPool count];
    }];
    
    return count;
}

- (void)releaseAllDatabases {
    [self executeLocked:^() {
        [self.databaseOutPool removeAllObjects];
        [self.databaseInPool removeAllObjects];
    }];
}

- (DatabaseOperator *)getDatabaseOperator {
    
    DatabaseOperator *db = [self db];
    
    [self pushDatabaseBackInPool:db];
    return db;
}

- (void)closeDataBase {
    
}

@end
