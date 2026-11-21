#import "AtlasFiles.h"
#import "MemoryArchive.h"

static NSFileManager *FM(void) {
    return NSFileManager.defaultManager;
}
NSURL *AFBase(void) {
    return [[FM() URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"Atlas"
                        isDirectory:YES];
}
NSURL *AFChild(NSURL *base, NSString *p) {
    return [base URLByAppendingPathComponent:p];
}
NSURL *AFProfile(NSString *uuid) {
    return AFChild(AFChild(AFBase(), @"Profiles"), uuid);
}
NSError *AFError(NSString *s) {
    return [NSError errorWithDomain:@"IELTSAtlas"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : s ?: @"操作失败"}];
}
BOOL AFMake(NSURL *p, NSError **e) {
    return [FM() createDirectoryAtURL:p withIntermediateDirectories:YES attributes:nil error:e];
}
NSURL *AFTemp(NSError **e) {
    NSURL *u =
        AFChild([NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES], NSUUID.UUID.UUIDString);
    return AFMake(u, e) ? u : nil;
}
BOOL AFSafePart(NSString *s) {
    return s.length && ![s isEqual:@"."] && ![s isEqual:@".."] &&
           [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\0"]]
                   .location == NSNotFound;
}
static BOOL useFolder(NSURL *u, BOOL writing, void (^op)(NSURL *, NSError **), NSError **e) {
    BOOL scoped = [u startAccessingSecurityScopedResource];
    __block NSError *io = nil;
    NSError *coord = nil;
    NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    if (writing)
        [c coordinateWritingItemAtURL:u
                              options:NSFileCoordinatorWritingForMerging
                                error:&coord
                           byAccessor:^(NSURL *p) {
                               op(p, &io);
                           }];
    else
        [c coordinateReadingItemAtURL:u
                              options:0
                                error:&coord
                           byAccessor:^(NSURL *p) {
                               op(p, &io);
                           }];
    if (scoped)
        [u stopAccessingSecurityScopedResource];
    if (e)
        *e = coord ?: io;
    return !coord && !io;
}
// The desktop release also accepts resources copied beside index.html. Mount just the three upstream
// resource trees.
static NSString *extensionPath(NSString *path) {
    NSArray<NSString *> *components = path.pathComponents;
    for (NSUInteger i = 0; i + 1 < components.count; i++) {
        NSString *part = components[i];
        NSArray *tail = [components subarrayWithRange:NSMakeRange(i, components.count - i)];
        if ([part isEqual:@"ReadingPractice"] || [part isEqual:@"ListeningPractice"])
            return [NSString pathWithComponents:tail];
        if ([part isEqual:@"listening-exams"] &&
            (i == 0 || (i >= 1 && [components[i - 1] isEqual:@"generated"])))
            return
                [@"assets/generated" stringByAppendingPathComponent:[NSString pathWithComponents:tail]];
    }
    if ([components.firstObject isEqual:@"PDF"] && [path.pathExtension.lowercaseString isEqual:@"pdf"])
        return [@"ReadingPractice" stringByAppendingPathComponent:path];
    return nil;
}
static NSURL *extensionIndex(NSURL *materials) {
    return AFChild(materials, @"extensions.plist");
}
NSDictionary<NSString *, NSURL *> *AFExtensionFiles(NSURL *materials) {
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfURL:extensionIndex(materials)];
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    for (id key in index) {
        id path = index[key];
        if (![key isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class] ||
            ![extensionPath(key) isEqual:key])
            continue;
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        if (parts.count < 2 || ![[NSUUID alloc] initWithUUIDString:parts.firstObject])
            continue;
        BOOL ok = YES;
        for (NSString *part in parts)
            if (!AFSafePart(part)) {
                ok = NO;
                break;
            }
        if (ok)
            files[key] = AFChild(materials, path);
    }
    return files.copy;
}
NSDictionary *AFImportFolder(NSURL *folder, NSURL *materials, BOOL extensionsOnly, NSError **e) {
    NSString *volume = NSUUID.UUID.UUIDString;
    NSURL *dest = AFChild(materials, volume);
    if (!AFMake(dest, e))
        return nil;
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableDictionary *mounts = [NSMutableDictionary dictionary];
    NSString *name = folder.lastPathComponent.precomposedStringWithCanonicalMapping;
    if (!AFSafePart(name)) {
        if (e)
            *e = AFError(@"题库文件夹名称无效");
        return nil;
    }
    BOOL ok = useFolder(
        folder, NO,
        ^(NSURL *src, NSError **err) {
            __block NSError *enumerationError = nil;
            NSArray *keys = @[ NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLIsDirectoryKey ];
            NSDirectoryEnumerator *items = [FM() enumeratorAtURL:src
                                      includingPropertiesForKeys:keys
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                    errorHandler:^BOOL(NSURL *url, NSError *issue) {
                                                        enumerationError = issue;
                                                        return NO;
                                                    }];
            NSString *prefix =
                [src.path hasSuffix:@"/"] ? src.path : [src.path stringByAppendingString:@"/"];
            for (NSURL *f in items) {
                @autoreleasepool {
                    NSDictionary *v = [f resourceValuesForKeys:keys error:err];
                    if (!v)
                        return;
                    if ([v[NSURLIsSymbolicLinkKey] boolValue]) {
                        [items skipDescendants];
                        continue;
                    }
                    if (![v[NSURLIsRegularFileKey] boolValue])
                        continue;
                    if (![f.path hasPrefix:prefix]) {
                        *err = AFError(@"题库路径无效");
                        return;
                    }
                    NSString *rel =
                        [[name stringByAppendingPathComponent:[f.path substringFromIndex:prefix.length]]
                            precomposedStringWithCanonicalMapping];
                    NSString *mount = extensionPath(rel);
                    if (extensionsOnly && !mount)
                        continue;
                    for (NSString *part in rel.pathComponents) {
                        if (!AFSafePart(part)) {
                            *err = AFError(@"题库文件名无效");
                            return;
                        }
                    }
                    NSURL *out = AFChild(dest, rel);
                    if (!AFMake(out.URLByDeletingLastPathComponent, err) || ![FM() copyItemAtURL:f
                                                                                           toURL:out
                                                                                           error:err])
                        return;
                    [paths addObject:rel];
                    if (mount)
                        mounts[mount] = [volume stringByAppendingPathComponent:rel];
                }
            }
            if (enumerationError)
                *err = enumerationError;
            else if (!paths.count)
                *err = AFError(extensionsOnly ? @"请选择包含 ListeningPractice、ReadingPractice 或 "
                                                @"assets/generated/listening-exams 的原版扩展目录。"
                                              : @"文件夹中没有可导入的文件");
        },
        e);
    if (!ok) {
        [FM() removeItemAtURL:dest error:NULL];
        return nil;
    }
    if (mounts.count) {
        NSMutableDictionary *saved =
            [[NSDictionary dictionaryWithContentsOfURL:extensionIndex(materials)] mutableCopy]
                ?: [NSMutableDictionary dictionary];
        [saved addEntriesFromDictionary:mounts];
        if (![saved writeToURL:extensionIndex(materials) error:e]) {
            [FM() removeItemAtURL:dest error:NULL];
            return nil;
        }
    }
    return @{@"volume" : volume, @"paths" : [paths sortedArrayUsingSelector:@selector(compare:)]};
}
NSDictionary *AFBindFolder(NSURL *folder, NSError **e) {
    BOOL scope = [folder startAccessingSecurityScopedResource];
    NSData *bookmark = [folder bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                        includingResourceValuesForKeys:nil
                                         relativeToURL:nil
                                                 error:e];
    if (scope)
        [folder stopAccessingSecurityScopedResource];
    if (!bookmark)
        return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    [NSUserDefaults.standardUserDefaults setObject:bookmark
                                            forKey:[@"BackupFolder." stringByAppendingString:token]];
    return @{@"name" : folder.lastPathComponent ?: @"备份", @"token" : token};
}
static BOOL diskFile(NSString *s) {
    return
        [s isKindOfClass:NSString.class] &&
        [s rangeOfString:@"^ielts-atlas-backup-(latest|[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{9})?)\\.json$"
                 options:NSRegularExpressionSearch]
                .location != NSNotFound &&
        AFSafePart(s);
}
id AFDisk(NSDictionary *r, NSError **e) {
    NSString *token = r[@"token"], *action = r[@"action"], *name = r[@"name"];
    if (![token isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:token]) {
        if (e)
            *e = AFError(@"请重新选择备份文件夹");
        return nil;
    }
    NSString *k = [@"BackupFolder." stringByAppendingString:token];
    NSData *b = [NSUserDefaults.standardUserDefaults dataForKey:k];
    BOOL stale = NO;
    NSURL *dir = b ? [NSURL URLByResolvingBookmarkData:b
                                               options:NSURLBookmarkResolutionWithoutUI
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:NULL]
                   : nil;
    if ([action isEqual:@"permission"]) {
        if (!dir)
            return @"denied";
        BOOL scope = [dir startAccessingSecurityScopedResource];
        BOOL exists = [FM() isReadableFileAtPath:dir.path];
        if (scope)
            [dir stopAccessingSecurityScopedResource];
        return exists ? @"granted" : @"denied";
    }
    if (!dir || (![action isEqual:@"list"] && !diskFile(name))) {
        if (e)
            *e = AFError(@"请重新选择备份文件夹");
        return nil;
    }
    BOOL scope = [dir startAccessingSecurityScopedResource];
    if (stale) {
        NSData *fresh = [dir bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                      includingResourceValuesForKeys:nil
                                       relativeToURL:nil
                                               error:NULL];
        if (fresh)
            [NSUserDefaults.standardUserDefaults setObject:fresh forKey:k];
    }
    __block id result = nil;
    BOOL writing = [action isEqual:@"write"];
    NSURL *target = [action isEqual:@"list"] ? dir : AFChild(dir, name);
    // A missing file is a normal result while looking for the next backup generation.
    if ([action isEqual:@"exists"])
        result = @([FM() fileExistsAtPath:target.path]);
    else
        useFolder(
            target, writing,
            ^(NSURL *p, NSError **err) {
                if ([action isEqual:@"list"]) {
                    NSArray *l = [FM() contentsOfDirectoryAtPath:p.path error:err];
                    if (l)
                        result =
                            [l filteredArrayUsingPredicate:[NSPredicate
                                                               predicateWithBlock:^BOOL(
                                                                   NSString *n, NSDictionary *bindings) {
                                                                   return diskFile(n);
                                                               }]];
                } else if ([action isEqual:@"read"])
                    result = [NSString stringWithContentsOfURL:p
                                                      encoding:NSUTF8StringEncoding
                                                         error:err];
                else if (writing && [r[@"text"] isKindOfClass:NSString.class]) {
                    if ([r[@"text"] writeToURL:p atomically:YES encoding:NSUTF8StringEncoding error:err])
                        result = @YES;
                } else
                    *err = AFError(@"未知的备份操作");
            },
            e);
    if (scope)
        [dir stopAccessingSecurityScopedResource];
    return result;
}
NSURL *AFPrepareRestore(NSURL *src, NSURL *profile, NSError **e) {
    if (!AFMake(AFChild(profile, @"materials"), e))
        return nil;
    NSURL *state = AFChild(profile, @"atlas-state.json");
    BOOL json = [src.pathExtension.lowercaseString isEqual:@"json"];
    BOOL ok = useFolder(
        src, NO,
        ^(NSURL *p, NSError **err) {
            if (json) {
                [FM() copyItemAtURL:p toURL:state error:err];
                return;
            }
            NSDictionary *space = [FM() attributesOfFileSystemForPath:profile.path error:err];
            if (!space)
                return;
            char msg[256] = {0};
            if (!AtlasExtract(p.fileSystemRepresentation, profile.fileSystemRepresentation,
                              [space[NSFileSystemFreeSize] unsignedLongLongValue], msg, sizeof(msg)))
                *err = AFError([NSString stringWithUTF8String:msg]);
        },
        e);
    return ok ? state : nil;
}
NSURL *AFPack(NSString *state, NSURL *profile, NSError **e) {
    NSURL *tmp = AFTemp(e);
    if (!tmp)
        return nil;
    NSURL *json = AFChild(tmp, @"atlas-state.json");
    if (![state writeToURL:json atomically:YES encoding:NSUTF8StringEncoding error:e]) {
        [FM() removeItemAtURL:tmp error:NULL];
        return nil;
    }
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *name =
        [NSString stringWithFormat:@"IELTS-Atlas_%@.atlasbackup", [f stringFromDate:NSDate.date]];
    NSURL *out = AFChild(tmp, name);
    char msg[256] = {0};
    int ok = AtlasPack(out.fileSystemRepresentation, json.fileSystemRepresentation,
                       AFChild(profile, @"materials").fileSystemRepresentation, msg, sizeof(msg));
    [FM() removeItemAtURL:json error:NULL];
    if (!ok) {
        if (e)
            *e = AFError([NSString stringWithUTF8String:msg]);
        [FM() removeItemAtURL:tmp error:NULL];
        return nil;
    }
    return out;
}
