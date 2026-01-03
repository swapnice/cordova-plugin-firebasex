#import "AppDelegate.h"

@import UserNotifications;

@interface AppDelegate (FirebasePlugin) <UIApplicationDelegate>
+ (AppDelegate *_Nonnull) instance;
@property (nonatomic, strong) NSNumber * _Nonnull applicationInBackground;
@end
