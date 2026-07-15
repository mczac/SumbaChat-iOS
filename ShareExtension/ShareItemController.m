/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <MobileCoreServices/MobileCoreServices.h>

#import "ShareItemController.h"
#import "NextcloudTalk-Swift.h"

@interface ShareItemController ()

@property (nonatomic, strong) NSString *tempDirectoryPath;
@property (nonatomic, strong) NSURL *tempDirectoryURL;
@property (nonatomic, strong) NSMutableArray *internalShareItems;
@property (nonatomic, strong) MediaUploadCompressionSettings *mediaUploadCompressionSettings;
@property (nonatomic, strong) dispatch_queue_t preparationQueue;
@property (nonatomic, assign, readwrite) NSInteger preparingItemCount;

@end

@implementation ShareItemController

- (instancetype)init
{
    return [self initWithMediaUploadCompressionSettings:[[MediaUploadCompressionSettings alloc] init]];
}

- (instancetype)initWithMediaUploadCompressionSettings:(MediaUploadCompressionSettings *)settings
{
    self = [super init];
    if (self) {
        self.mediaUploadCompressionSettings = settings;
        self.internalShareItems = [[NSMutableArray alloc] init];
        self.preparationQueue = dispatch_queue_create("com.spl.SumbaChat.media-upload-preparation", DISPATCH_QUEUE_SERIAL);
        [self initTempDirectory];
    }
    return self;
}

- (NSArray<ShareItem *> *)shareItems {
    return [self.internalShareItems copy];
}

- (void)initTempDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    self.tempDirectoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"/upload/"];
    
    if (![fileManager fileExistsAtPath:self.tempDirectoryPath]) {
        // Make sure our upload directory exists
        [fileManager createDirectoryAtPath:self.tempDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    } else {
        // Clean up any temporary files from a previous upload
        NSArray *previousFiles = [fileManager contentsOfDirectoryAtPath:self.tempDirectoryPath error:nil];
        
        for (NSString *previousFile in previousFiles) {
            [fileManager removeItemAtPath:[self.tempDirectoryPath stringByAppendingPathComponent:previousFile] error:nil];
        }
    }
    
    self.tempDirectoryURL = [NSURL fileURLWithPath:self.tempDirectoryPath isDirectory:YES];
}

- (void)beginPreparingItem
{
    NSAssert(NSThread.isMainThread, @"Preparing item count must be updated on the main thread");
    self.preparingItemCount += 1;
    [self.delegate shareItemControllerPreparingItemsChanged:self];
}

- (void)endPreparingItem
{
    NSAssert(NSThread.isMainThread, @"Preparing item count must be updated on the main thread");
    if (self.preparingItemCount <= 0) {
        return;
    }

    self.preparingItemCount -= 1;
    [self.delegate shareItemControllerPreparingItemsChanged:self];
}

- (NSURL *)getFileLocalURL:(NSString *)fileName
{
    NSURL *fileLocalURL = [self.tempDirectoryURL URLByAppendingPathComponent:fileName];
    
    if ([NSFileManager.defaultManager fileExistsAtPath:fileLocalURL.path]) {
        NSString *extension = [fileName pathExtension];
        NSString *nameWithoutExtension = [fileName stringByDeletingPathExtension];
        
        NSString *newFileName = [NSString stringWithFormat:@"%@%.f.%@", nameWithoutExtension, [[NSDate date] timeIntervalSince1970] * 1000, extension];
        fileLocalURL = [self.tempDirectoryURL URLByAppendingPathComponent:newFileName];
    }
    
    return fileLocalURL;
}

- (void)addItemWithURL:(NSURL *)fileURL
{
    [self addItemWithURLAndName:fileURL withName:fileURL.lastPathComponent];
}

- (BOOL)prepareFileForUploadingAtURL:(NSURL *)fileURL toLocalURL:(NSURL *)fileLocalURL withCoordinatorOption:(NSFileCoordinatorReadingOptions)options
{
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *error;

    // Make a local copy to prevent bug where file is removed after some time from inbox
    // See: https://stackoverflow.com/a/48007752/2512312
    [coordinator coordinateReadingItemAtURL:fileURL options:options error:&error byAccessor:^(NSURL *newURL) {
        if ([NSFileManager.defaultManager fileExistsAtPath:fileLocalURL.path]) {
            [NSFileManager.defaultManager removeItemAtPath:fileLocalURL.path error:nil];
        }

        [NSFileManager.defaultManager moveItemAtPath:newURL.path toPath:fileLocalURL.path error:nil];
    }];

    BOOL success = (error == nil);
    return success;
}

- (void)addShareItemWithLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName isImage:(BOOL)fileIsImage
{
    NSLog(@"Adding shareItem: %@ %@", fileName, fileLocalURL);

    ShareItem *item = [ShareItem initWithURL:fileLocalURL withName:fileName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:fileIsImage];
    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)finalizeImageItemFromLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    NSString *jpegName = [[fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
    NSURL *jpegURL = [self getFileLocalURL:jpegName];
    MediaUploadCompressionSettings *settings = self.mediaUploadCompressionSettings;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        NSURL *finalURL = fileLocalURL;
        NSString *finalName = fileName;

        if ([MediaUploadPreprocessor compressImageAtURL:fileLocalURL
                                       toDestinationURL:jpegURL
                                               settings:settings]) {
            [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
            finalURL = jpegURL;
            finalName = jpegName;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            [strongSelf addShareItemWithLocalURL:finalURL fileName:finalName isImage:YES];
            [strongSelf endPreparingItem];
        });
    });
}

- (void)finalizeVideoItemFromLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    NSString *mp4Name = [[fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
    NSURL *mp4URL = [self getFileLocalURL:mp4Name];

    __weak typeof(self) weakSelf = self;
    [MediaUploadPreprocessor compressVideoAtURL:fileLocalURL
                               toDestinationURL:mp4URL
                                       settings:self.mediaUploadCompressionSettings
                                     completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            NSURL *finalURL = fileLocalURL;
            NSString *finalName = fileName;

            if (success) {
                [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
                finalURL = mp4URL;
                finalName = mp4Name;
            } else {
                [NSFileManager.defaultManager removeItemAtURL:mp4URL error:nil];
                NSLog(@"Video compression failed, uploading original file");
            }

            [strongSelf addShareItemWithLocalURL:finalURL fileName:finalName isImage:NO];
            [strongSelf endPreparingItem];
        });
    }];
}

- (void)addItemWithURLAndName:(NSURL *)fileURL withName:(NSString *)fileName
{
    [self beginPreparingItem];

    NSURL *fileLocalURL = [self getFileLocalURL:fileName];

    // First try to prepare the file with NSFileCoordinatorReadingForUploading
    BOOL preparedSuccessfully = [self prepareFileForUploadingAtURL:fileURL toLocalURL:fileLocalURL withCoordinatorOption:NSFileCoordinatorReadingForUploading];

    if (!preparedSuccessfully) {
        // We failed to prepare the file with NSFileCoordinatorReadingForUploading, use NSFileCoordinatorReadingWithoutChanges as a fallback
        preparedSuccessfully = [self prepareFileForUploadingAtURL:fileURL toLocalURL:fileLocalURL withCoordinatorOption:NSFileCoordinatorReadingWithoutChanges];

        if (!preparedSuccessfully) {
            NSLog(@"Failed to prepare file for sharing");
            [self endPreparingItem];
            return;
        }
    }

    NSString *extension = fileLocalURL.pathExtension.lowercaseString;
    BOOL fileIsImage = (extension.length > 0 && [NCUtils isImageWithFileExtension:extension]);

    if (fileIsImage) {
        [self finalizeImageItemFromLocalURL:fileLocalURL fileName:fileName];
        return;
    }

    if (extension.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:extension]) {
        [self finalizeVideoItemFromLocalURL:fileLocalURL fileName:fileName];
        return;
    }

    [self addShareItemWithLocalURL:fileLocalURL fileName:fileName isImage:fileIsImage];
    [self endPreparingItem];
}

- (void)addItemWithImage:(UIImage *)image
{
    NSString *imageName = [NSString stringWithFormat:@"IMG_%.f.jpg", [[NSDate date] timeIntervalSince1970] * 1000];
    [self addItemWithImageAndName:image withName:imageName];
}

- (void)addItemWithImageAndName:(UIImage *)image withName:(NSString *)imageName
{
    [self beginPreparingItem];

    MediaUploadCompressionSettings *settings = self.mediaUploadCompressionSettings;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        NSData *jpegData = [MediaUploadPreprocessor compressedJPEGDataFromImage:image settings:settings];
        NSString *jpegName = [[imageName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];

        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            if (!jpegData) {
                NSLog(@"Failed to compress image for upload");
                [strongSelf endPreparingItem];
                return;
            }

            [strongSelf addItemWithImageDataAndName:jpegData withName:jpegName];
            [strongSelf endPreparingItem];
        });
    });
}

- (void)addItemWithImageDataAndName:(NSData *)data withName:(NSString *)imageName
{
    NSURL *fileLocalURL = [self getFileLocalURL:imageName];
    [data writeToFile:fileLocalURL.path atomically:YES];

    NSLog(@"Adding shareItem with image: %@ %@", imageName, fileLocalURL);

    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:imageName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (UIImage *)getImageFromItem:(ShareItem *)item
{
    if (!item || !item.fileURL) {
        return nil;
    }
        
    return [UIImage imageWithContentsOfFile:item.filePath];
}

- (void)addItemWithContactData:(NSData *)data
{
    NSString *vCardFileName = [NSString stringWithFormat:@"Contact_%.f.vcf", [[NSDate date] timeIntervalSince1970] * 1000];
    [self addItemWithContactDataAndName:data withName:vCardFileName];
}

- (void)addItemWithContactDataAndName:(NSData *)data withName:(NSString *)vCardFileName
{
    NSURL *fileLocalURL = [self getFileLocalURL:vCardFileName];
    NSString* vcString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [vcString writeToFile:fileLocalURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
    NSLog(@"Adding shareItem with contact: %@ %@", vCardFileName, fileLocalURL);
    
    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:vCardFileName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)updateItem:(ShareItem *)item withURL:(NSURL *)fileURL
{
    // This is called when an item was edited in quicklook and we want to use the edited image
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *error;
    
    [coordinator coordinateReadingItemAtURL:fileURL options:NSFileCoordinatorReadingForUploading error:&error byAccessor:^(NSURL *newURL) {
        if ([NSFileManager.defaultManager fileExistsAtPath:item.filePath]) {
            [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
        }
        
        [NSFileManager.defaultManager moveItemAtPath:newURL.path toPath:item.filePath error:nil];
    }];
    
    NSLog(@"Updating shareItem: %@ %@", item.fileName, item.fileURL);

    NSString *extension = item.fileURL.pathExtension.lowercaseString;
    if (extension.length > 0 && [NCUtils isImageWithFileExtension:extension] && ![extension isEqualToString:@"gif"]) {
        NSURL *jpegURL = [self getFileLocalURL:[[item.fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"]];
        if ([MediaUploadPreprocessor compressImageAtURL:item.fileURL
                                       toDestinationURL:jpegURL
                                               settings:self.mediaUploadCompressionSettings]) {
            [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
            item.fileURL = jpegURL;
            item.filePath = jpegURL.path;
            item.fileName = jpegURL.lastPathComponent;
        }
    }
    
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)updateItem:(ShareItem *)item withImage:(UIImage *)image
{
    NSData *jpegData = [MediaUploadPreprocessor compressedJPEGDataFromImage:image settings:self.mediaUploadCompressionSettings];
    if (!jpegData) {
        NSLog(@"Failed to compress updated image for upload");
        return;
    }

    [jpegData writeToFile:item.filePath atomically:YES];
    
    NSLog(@"Updating shareItem with Image: %@ %@", item.fileName, item.fileURL);
    
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)removeItem:(ShareItem *)item
{
    [self removeItems:@[item]];
}

- (void)removeItems:(NSArray<ShareItem *> *)items
{
    for (ShareItem *item in items) {
        [self cleanupItem:item];

        NSLog(@"Removing shareItem: %@ %@", item.fileName, item.fileURL);
        [self.internalShareItems removeObject:item];
    }

    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)cleanupItem:(ShareItem *)item
{
    if ([NSFileManager.defaultManager fileExistsAtPath:item.filePath]) {
        [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
    }
}

- (void)removeAllItems
{
    for (ShareItem *item in self.internalShareItems) {
        [self cleanupItem:item];
    }
    
    [self.internalShareItems removeAllObjects];
}

- (UIImage *)getPlaceholderImageForFileURL:(NSURL *)fileURL
{
    NSString *previewImage = [NCUtils previewImageForFileExtension:[fileURL pathExtension]];
    return [UIImage imageNamed:previewImage];
}

@end
