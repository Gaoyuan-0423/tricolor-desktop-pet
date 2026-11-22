#import "PetLoginItem.h"
#import <ServiceManagement/ServiceManagement.h>
#import <CoreServices/CoreServices.h>

static PetLoginStatus convertStatus(SMAppServiceStatus status) API_AVAILABLE(macos(13.0)) {
    switch (status) {
        case SMAppServiceStatusEnabled: return PetLoginOn;
        case SMAppServiceStatusRequiresApproval: return PetLoginNeedsApproval;
        case SMAppServiceStatusNotRegistered: return PetLoginOff;
        default: return PetLoginUnavailable;
    }
}

static BOOL updateService(SMAppService *service, BOOL enable, NSError **error) API_AVAILABLE(macos(13.0)) {
    PetLoginStatus status = convertStatus(service.status);
    if (enable && (status == PetLoginOn || status == PetLoginNeedsApproval)) return YES;
    if (!enable && status == PetLoginOff) return YES;
    return enable ? [service registerAndReturnError:error] : [service unregisterAndReturnError:error];
}

// macOS 12 exposes the user's Login Items list through Launch Services.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSArray *matchingItems(LSSharedFileListRef list) {
    if (!list) return nil;
    NSArray *snapshot = CFBridgingRelease(LSSharedFileListCopySnapshot(list, NULL));
    if (!snapshot) return nil;
    NSURL *bundle = NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    NSMutableArray *matches = [NSMutableArray array];
    for (id entry in snapshot) {
        NSURL *url = CFBridgingRelease(LSSharedFileListItemCopyResolvedURL((__bridge LSSharedFileListItemRef)entry,
                           kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL));
        if ([url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path isEqualToString:bundle.path])
            [matches addObject:entry];
    }
    return matches;
}

static PetLoginStatus legacyStatus(void) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL,kLSSharedFileListSessionLoginItems,NULL);
    NSArray *items = matchingItems(list);
    if (list) CFRelease(list);
    return !items ? PetLoginUnavailable : items.count ? PetLoginOn : PetLoginOff;
}

static BOOL updateLegacy(BOOL enable, NSError **error) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL,kLSSharedFileListSessionLoginItems,NULL);
    NSArray *items = matchingItems(list);
    OSStatus result = items ? noErr : paramErr;
    if (items && enable && !items.count) {
        LSSharedFileListItemRef newItem = LSSharedFileListInsertItemURL(list,kLSSharedFileListItemLast,
            NULL,NULL,(__bridge CFURLRef)NSBundle.mainBundle.bundleURL,NULL,NULL);
        if (newItem) CFRelease(newItem);
        else result = paramErr;
    } else if (items && !enable) {
        for (id item in items) {
            result = LSSharedFileListItemRemove(list,(__bridge LSSharedFileListItemRef)item);
            if (result != noErr) break;
        }
    }
    if (list) CFRelease(list);
    if (result != noErr && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:nil];
    return result == noErr;
}
#pragma clang diagnostic pop

PetLoginStatus PetLoginItemStatus(void) {
    if (@available(macOS 13, *)) return convertStatus(SMAppService.mainAppService.status);
    return legacyStatus();
}

BOOL PetSetLoginItemEnabled(BOOL enabled, NSError **error) {
    if (@available(macOS 13, *)) return updateService(SMAppService.mainAppService,enabled,error);
    return updateLegacy(enabled,error);
}

void PetOpenLoginItemSettings(void) {
    if (@available(macOS 13, *)) [SMAppService openSystemSettingsLoginItems];
}
