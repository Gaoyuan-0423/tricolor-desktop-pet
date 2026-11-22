#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PetLoginStatus) {
    PetLoginOff, PetLoginOn, PetLoginNeedsApproval, PetLoginUnavailable
};

FOUNDATION_EXPORT PetLoginStatus PetLoginItemStatus(void);
FOUNDATION_EXPORT BOOL PetSetLoginItemEnabled(BOOL enabled, NSError **error);
FOUNDATION_EXPORT void PetOpenLoginItemSettings(void);
