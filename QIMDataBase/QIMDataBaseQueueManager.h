//
//  QIMDataBaseQueueManager.h
//  QIMDataBase
//
//  Created by lilu on 2019/5/28.
//

#import <Foundation/Foundation.h>
#import "Database.h"

NS_ASSUME_NONNULL_BEGIN

@interface QIMDataBaseQueueManager : NSObject

@property (atomic, copy, nullable) NSString *path;

/** Delegate object */

/** Maximum number of databases to create */

@property (atomic, assign) NSUInteger maximumNumberOfDatabasesToCreate;

+ (instancetype)databasePoolWithPath:(NSString *)aPath;

- (void)releaseAllDatabases;

- (DatabaseOperator *)getDatabaseOperator;

- (void)closeDataBase;

@end

NS_ASSUME_NONNULL_END
