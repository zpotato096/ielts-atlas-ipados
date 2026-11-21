#import <Foundation/Foundation.h>
NSURL *AFBase(void);
NSURL *AFProfile(NSString *uuid);
NSURL *AFChild(NSURL *base, NSString *part);
BOOL AFMake(NSURL *dir, NSError **error);
NSURL *AFTemp(NSError **error);
NSError *AFError(NSString *text);
BOOL AFSafePart(NSString *name);
NSDictionary *AFImportFolder(NSURL *folder, NSURL *materials, BOOL extensionsOnly, NSError **error);
NSDictionary<NSString *, NSURL *> *AFExtensionFiles(NSURL *materials);
NSDictionary *AFBindFolder(NSURL *folder, NSError **error);
id AFDisk(NSDictionary *request, NSError **error);
NSURL *AFPrepareRestore(NSURL *source, NSURL *profile, NSError **error);
NSURL *AFPack(NSString *state, NSURL *profile, NSError **error);
