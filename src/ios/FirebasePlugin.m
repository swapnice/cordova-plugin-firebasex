#import "FirebasePlugin.h"
#import "FirebasePluginMessageReceiverManager.h"
#import "AppDelegate+FirebasePlugin.h"
#import <Cordova/CDV.h>
#import "AppDelegate.h"
@import FirebaseMessaging;
@import FirebaseCore;
@import FirebaseInstallations;
@import UserNotifications;

@implementation FirebasePlugin

@synthesize openSettingsCallbackId;
@synthesize notificationCallbackId;
@synthesize tokenRefreshCallbackId;
@synthesize apnsTokenRefreshCallbackId;
@synthesize notificationStack;

static NSString*const LOG_TAG = @"FirebasePlugin[native]";
static NSInteger const kNotificationStackSize = 32;
static NSString*const FIREBASEX_IOS_FCM_ENABLED = @"FIREBASEX_IOS_FCM_ENABLED";

static FirebasePlugin* firebasePlugin;
static BOOL pluginInitialized = NO;
static BOOL registeredForRemoteNotifications = NO;
static BOOL openSettingsEmitted = NO;
static BOOL immediateMessagePayloadDelivery = NO;
static NSUserDefaults* preferences;
static NSDictionary* googlePlist;
static NSMutableArray* pendingGlobalJS = nil;


+ (FirebasePlugin*) firebasePlugin {
    return firebasePlugin;
}

// @override abstract
- (void)pluginInitialize {
    NSLog(@"Starting Firebase plugin");
    firebasePlugin = self;

    @try {
        preferences = [NSUserDefaults standardUserDefaults];
        googlePlist = [NSMutableDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"]];
        immediateMessagePayloadDelivery = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"FIREBASE_MESSAGING_IMMEDIATE_PAYLOAD_DELIVERY"] boolValue];

        // We don't need `setPreferenceFlag` here as we don't allow to change this at runtime.
        _isFCMEnabled = [self getGooglePlistFlagWithDefaultValue:FIREBASEX_IOS_FCM_ENABLED defaultValue:YES];
        if (!self.isFCMEnabled) {
            [self _logInfo:@"Firebase Cloud Messaging is disabled, see IOS_FCM_ENABLED variable of the plugin"];
        }

        // Set actionable categories if pn-actions.json exist in bundle
        [self setActionableNotifications];

        // Check for permission and register for remote notifications if granted
        if (self.isFCMEnabled) {
            [self _hasPermission:^(BOOL result) {}];
        }

        pluginInitialized = YES;
        [self executePendingGlobalJavascript];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

// Dynamic actions from pn-actions.json
- (void)setActionableNotifications {

    @try {

        // Initialize installation ID change listener
        __weak __auto_type weakSelf = self;
        self.installationIDObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName: FIRInstallationIDDidChangeNotification
            object:nil
            queue:nil
            usingBlock:^(NSNotification * _Nonnull notification) {
                [weakSelf sendNewInstallationId];
            }
        ];

        // The part related to installation ID is not specific to FCM, that's why it was moved above.
        if (!self.isFCMEnabled) {
            return;
        }

        // Parse JSON
        NSString *path = [[NSBundle mainBundle] pathForResource:@"pn-actions" ofType:@"json"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if(data == nil) return;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];

        // Assign actions for categories
        NSMutableSet *categories = [[NSMutableSet alloc] init];
        NSArray *actionsArray = [dict objectForKey:@"PushNotificationActions"];
        for (NSDictionary *item in actionsArray) {
            NSMutableArray *buttons = [NSMutableArray new];
            NSString *category = [item objectForKey:@"category"];

            NSArray *actions = [item objectForKey:@"actions"];
            for (NSDictionary *action in actions) {
                NSString *actionId = [action objectForKey:@"id"];
                NSString *actionTitle = [action objectForKey:@"title"];
                UNNotificationActionOptions options = UNNotificationActionOptionNone;

                id mode = [action objectForKey:@"foreground"];
                if (mode != nil && (([mode isKindOfClass:[NSString class]] && [mode isEqualToString:@"true"]) || [mode boolValue])) {
                    options |= UNNotificationActionOptionForeground;
                }
                id destructive = [action objectForKey:@"destructive"];
                if (destructive != nil && (([destructive isKindOfClass:[NSString class]] && [destructive isEqualToString:@"true"]) || [destructive boolValue])) {
                    options |= UNNotificationActionOptionDestructive;
                }

                [buttons addObject:[UNNotificationAction actionWithIdentifier:actionId
                    title:NSLocalizedString(actionTitle, nil) options:options]];
            }

            [categories addObject:[UNNotificationCategory categoryWithIdentifier:category
                        actions:buttons intentIdentifiers:@[] options:UNNotificationCategoryOptionNone]];
        }

        // Initialize categories
        [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:categories];

    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

/*************************************************/
#pragma mark - plugin API
/*************************************************/
- (void)setAutoInitEnabled:(CDVInvokedUrlCommand *)command {
    @try {
        bool enabled = [[command.arguments objectAtIndex:0] boolValue];
        [self runOnMainThread:^{
            @try {
                [FIRMessaging messaging].autoInitEnabled = enabled;

                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithContext:exception :command];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)isAutoInitEnabled:(CDVInvokedUrlCommand *)command {
    @try {

        [self runOnMainThread:^{
            @try {
                 bool enabled =[FIRMessaging messaging].isAutoInitEnabled;

                 CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:enabled];
                 [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithContext:exception :command];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

/*
 * Remote notifications
 */

- (void)getId:(CDVInvokedUrlCommand *)command {
    [self getInstallationId:command];
}

- (void)getToken:(CDVInvokedUrlCommand *)command {
    [self _getToken:^(NSString *token, NSError *error) {
        [self handleStringResultWithPotentialError:error command:command result:token];
    }];
}

-(void)_getToken:(void (^)(NSString *token, NSError *error))completeBlock {
    @try {
        [[FIRMessaging messaging] tokenWithCompletion:^(NSString *token, NSError *error) {
            @try {
                completeBlock(token, error);
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithoutContext:exception];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

- (void)getAPNSToken:(CDVInvokedUrlCommand *)command {
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[self getAPNSToken]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString *)getAPNSToken {
    NSString* hexToken = nil;
    NSData* apnsToken = [FIRMessaging messaging].APNSToken;
    if (apnsToken) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
        // [deviceToken description] Starting with iOS 13 device token is like "{length = 32, bytes = 0xd3d997af 967d1f43 b405374a 13394d2f ... 28f10282 14af515f }"
        hexToken = [self hexadecimalStringFromData:apnsToken];
#else
        hexToken = [[apnsToken.description componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet]invertedSet]]componentsJoinedByString:@""];
#endif
    }
    return hexToken;
}

- (NSString *)hexadecimalStringFromData:(NSData *)data
{
    NSUInteger dataLength = data.length;
    if (dataLength == 0) {
        return nil;
    }

    const unsigned char *dataBuffer = data.bytes;
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    for (int i = 0; i < dataLength; ++i) {
        [hexString appendFormat:@"%02x", dataBuffer[i]];
    }
    return [hexString copy];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command {
    @try {
        [self _hasPermission:^(BOOL enabled) {
            CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:enabled];
            [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

-(void)_hasPermission:(void (^)(BOOL result))completeBlock {
    @try {
        [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
            @try {
                BOOL enabled = NO;
                if (settings.alertSetting == UNNotificationSettingEnabled) {
                    enabled = YES;
                    [self registerForRemoteNotifications];
                }
                NSLog(@"_hasPermission: %@", enabled ? @"YES" : @"NO");
                completeBlock(enabled);
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithoutContext:exception];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

- (void)grantPermission:(CDVInvokedUrlCommand *)command {
    NSLog(@"grantPermission");
    @try {
        [self _hasPermission:^(BOOL enabled) {
            @try {
                if(enabled){
                    NSString* message = @"Permission is already granted - call hasPermission() to check before calling grantPermission()";
                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                }else{
                    [UNUserNotificationCenter currentNotificationCenter].delegate = (id<UNUserNotificationCenterDelegate> _Nullable) self;
                    BOOL requestWithProvidesAppNotificationSettings = [[command argumentAtIndex:0] boolValue];
                    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge;
                    if (@available(iOS 12.0, *)) {
                        if(requestWithProvidesAppNotificationSettings) {
                            authOptions = authOptions|UNAuthorizationOptionProvidesAppNotificationSettings;
                        }
                    }

                    [[UNUserNotificationCenter currentNotificationCenter]
                     requestAuthorizationWithOptions:authOptions
                     completionHandler:^(BOOL granted, NSError * _Nullable error) {
                        @try {
                            NSLog(@"requestAuthorizationWithOptions: granted=%@", granted ? @"YES" : @"NO");
                            if (error == nil && granted) {
                                [UNUserNotificationCenter currentNotificationCenter].delegate = AppDelegate.instance;
                                [self registerForRemoteNotifications];
                            }
                            [self handleBoolResultWithPotentialError:error command:command result:granted];

                        }@catch (NSException *exception) {
                            [self handlePluginExceptionWithContext:exception :command];
                        }
                    }
                     ];
                }
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithContext:exception :command];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)hasCriticalPermission:(CDVInvokedUrlCommand *)command {
    @try {
        [self _hasCriticalPermission:^(BOOL enabled) {
            CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:enabled];
            [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)_hasCriticalPermission:(void (^)(BOOL result))completeBlock {
    @try {
        if (@available(iOS 12.0, *)) {
            [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
                @try {
                    BOOL enabled = NO;
                    if (settings.criticalAlertSetting == UNNotificationSettingEnabled) {
                        enabled = YES;
                        [self registerForRemoteNotifications];
                    }
                    NSLog(@"_hasCriticalPermission: %@", enabled ? @"YES" : @"NO");
                    completeBlock(enabled);
                }@catch (NSException *exception) {
                    [self handlePluginExceptionWithoutContext:exception];
                }
            }];
        }else{
            completeBlock(NO);
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

- (void)grantCriticalPermission:(CDVInvokedUrlCommand *)command {
    NSLog(@"grantCriticalPermission");
    @try {
        if (@available(iOS 12.0, *)) {
            [self _hasCriticalPermission:^(BOOL enabled) {
                @try {
                    if(enabled){
                        NSString* message = @"Critical permission is already granted - call hasCriticalPermission() to check before calling grantCriticalPermission()";
                        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                    }else{
                        [UNUserNotificationCenter currentNotificationCenter].delegate = (id<UNUserNotificationCenterDelegate> _Nullable) self;
                        UNAuthorizationOptions authOptions = UNAuthorizationOptionCriticalAlert;

                        [[UNUserNotificationCenter currentNotificationCenter]
                         requestAuthorizationWithOptions:authOptions
                         completionHandler:^(BOOL granted, NSError * _Nullable error) {
                            @try {
                                NSLog(@"requestAuthorizationWithOptions: granted=%@", granted ? @"YES" : @"NO");
                                [self handleBoolResultWithPotentialError:error command:command result:granted];
                            }@catch (NSException *exception) {
                                [self handlePluginExceptionWithContext:exception :command];
                            }
                        }];
                    }
                }@catch (NSException *exception) {
                    [self handlePluginExceptionWithContext:exception :command];
                }
            }];
        } else {
            [self handleBoolResultWithPotentialError:nil command:command result:false];
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)registerForRemoteNotifications {
    NSLog(@"registerForRemoteNotifications");

    if(registeredForRemoteNotifications) return;

    [self runOnMainThread:^{
        @try {
            [[UIApplication sharedApplication] registerForRemoteNotifications];
        }@catch (NSException *exception) {
            [self handlePluginExceptionWithoutContext:exception];
        }
        registeredForRemoteNotifications = YES;
    }];
}

- (void)setBadgeNumber:(CDVInvokedUrlCommand *)command {
    @try {
        int number = [[command.arguments objectAtIndex:0] intValue];
        [self runOnMainThread:^{
            @try {
                [[UIApplication sharedApplication] setApplicationIconBadgeNumber:number];
                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithContext:exception :command];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)getBadgeNumber:(CDVInvokedUrlCommand *)command {
    [self runOnMainThread:^{
        @try {
            long badge = [[UIApplication sharedApplication] applicationIconBadgeNumber];

            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:badge];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }@catch (NSException *exception) {
            [self handlePluginExceptionWithContext:exception :command];
        }
    }];
}

- (void)subscribe:(CDVInvokedUrlCommand *)command {
    @try {
        NSString* topic = [NSString stringWithFormat:@"%@", [command.arguments objectAtIndex:0]];

        [[FIRMessaging messaging] subscribeToTopic: topic completion:^(NSError * _Nullable error) {
            [self handleEmptyResultWithPotentialError:error command:command];
        }];

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)unsubscribe:(CDVInvokedUrlCommand *)command {
    @try {
        NSString* topic = [NSString stringWithFormat:@"%@", [command.arguments objectAtIndex:0]];

        [[FIRMessaging messaging] unsubscribeFromTopic: topic completion:^(NSError * _Nullable error) {
            [self handleEmptyResultWithPotentialError:error command:command];
        }];

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)unregister:(CDVInvokedUrlCommand *)command {
    @try {
        __block NSError* error = nil;
        [[FIRMessaging messaging] deleteTokenWithCompletion:^(NSError * _Nullable deleteTokenError) {
            if(error == nil && deleteTokenError != nil) error = deleteTokenError;
            if([FIRMessaging messaging].isAutoInitEnabled){
                [self _getToken:^(NSString* token, NSError* getError) {
                    if(error == nil && getError != nil) error = getError;
                    [self handleEmptyResultWithPotentialError:error command:command];
                }];
            }else{
                [self handleEmptyResultWithPotentialError:error command:command];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void) onOpenSettings:(CDVInvokedUrlCommand *)command {
    @try {
        self.openSettingsCallbackId = command.callbackId;

        if(openSettingsEmitted == YES) {
            [self sendPluginSuccessAndKeepCallback:self.openSettingsCallbackId];
            openSettingsEmitted = NO;
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void)onMessageReceived:(CDVInvokedUrlCommand *)command {
    self.notificationCallbackId = command.callbackId;
    [self sendPendingNotifications];
}

- (void)sendPendingNotifications {
    if (self.notificationCallbackId != nil && self.notificationStack != nil && [self.notificationStack count]) {
        @try {
            for (NSDictionary *userInfo in self.notificationStack) {
                [self sendNotification:userInfo];
            }
            [self.notificationStack removeAllObjects];
        } @catch (NSException *exception) {
            [self handlePluginExceptionWithoutContext:exception];
        }
    }
}

- (void)onTokenRefresh:(CDVInvokedUrlCommand *)command {
    self.tokenRefreshCallbackId = command.callbackId;
    NSString* apnsToken = [self getAPNSToken];
    if(apnsToken != nil){
        [self _getToken:^(NSString *token, NSError *error) {
            if(error == nil && token != nil){
                [self sendToken:token];
            }
        }];
    }
}

- (void)onApnsTokenReceived:(CDVInvokedUrlCommand *)command {
    self.apnsTokenRefreshCallbackId = command.callbackId;
    @try {
        NSString* apnsToken = [self getAPNSToken];
        if(apnsToken != nil){
            [self sendApnsToken:apnsToken];
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void) sendOpenNotificationSettings {
    @try {
        if(self.openSettingsCallbackId != nil) {
            [self sendPluginSuccessAndKeepCallback:self.openSettingsCallbackId];
        } else if(openSettingsEmitted != YES) {
            openSettingsEmitted = YES;
        }
    } @catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :self.commandDelegate];
    }
}

- (void)sendNotification:(NSDictionary *)userInfo {
    @try {
        if([FirebasePluginMessageReceiverManager sendNotification:userInfo]){
            [self _logMessage:@"Message handled by custom receiver"];
            return;
        }
        if (self.notificationCallbackId != nil && ([AppDelegate.instance.applicationInBackground isEqual:@(NO)] || immediateMessagePayloadDelivery )) {
            [self sendPluginDictionaryResultAndKeepCallback:userInfo command:self.commandDelegate callbackId:self.notificationCallbackId];
        } else {
            if (!self.notificationStack) {
                self.notificationStack = [[NSMutableArray alloc] init];
            }

            // stack notifications until a callback has been registered
            [self.notificationStack addObject:userInfo];

            if ([self.notificationStack count] >= kNotificationStackSize) {
                [self.notificationStack removeLastObject];
            }
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :self.commandDelegate];
    }
}

- (void)sendToken:(NSString *)token {
    @try {
        if (self.tokenRefreshCallbackId != nil) {
            [self sendPluginStringResultAndKeepCallback:token command:self.commandDelegate callbackId:self.tokenRefreshCallbackId];
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :self.commandDelegate];
    }
}

- (void)sendApnsToken:(NSString *)token {
    @try {
        if (self.apnsTokenRefreshCallbackId != nil) {
            [self sendPluginStringResultAndKeepCallback:token command:self.commandDelegate callbackId:self.apnsTokenRefreshCallbackId];
        }
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :self.commandDelegate];
    }
}

- (void)clearAllNotifications:(CDVInvokedUrlCommand *)command {
    [self runOnMainThread:^{
        @try {
            [[UIApplication sharedApplication] setApplicationIconBadgeNumber:1];
            [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];

            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }@catch (NSException *exception) {
            [self handlePluginExceptionWithContext:exception :command];
        }
    }];
}

/*
 * Installations
 */
- (void) getInstallationId:(CDVInvokedUrlCommand*)command{
    @try {
        [[FIRInstallations installations] installationIDWithCompletion:^(NSString *identifier, NSError *error) {
            [self handleStringResultWithPotentialError:error command:command result:identifier];
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void) getInstallationToken:(CDVInvokedUrlCommand*)command{
    @try {
        [[FIRInstallations installations] authTokenWithCompletion:^(FIRInstallationsAuthTokenResult *result, NSError *error) {
            [self handleStringResultWithPotentialError:error command:command result:result.authToken];
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void) deleteInstallationId:(CDVInvokedUrlCommand*)command{
    @try {
        [[FIRInstallations installations] deleteWithCompletion:^(NSError *error) {
            [self handleEmptyResultWithPotentialError:error command:command];
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithContext:exception :command];
    }
}

- (void) sendNewInstallationId{
    @try {
        [[FIRInstallations installations] installationIDWithCompletion:^(NSString *identifier, NSError *error) {
            if(error != nil){
                [self _logError:[NSString stringWithFormat:@"getInstallationId error: %@", error]];
            }else{
                [self executeGlobalJavascript:[NSString stringWithFormat:@"FirebasePlugin._onInstallationIdChangeCallback(\"%@\")", identifier]];
            }
        }];
    }@catch (NSException *exception) {
        [self handlePluginExceptionWithoutContext:exception];
    }
}

/********************************/
#pragma mark - Internals
/********************************/

- (void)sendPluginSuccess:(CDVInvokedUrlCommand*)command {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendPluginSuccessAndKeepCallback:(NSString*)callbackId {
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [commandResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:commandResult callbackId:callbackId];
}

- (void)sendPluginErrorWithMessage:(NSString*)errorMessage :(CDVInvokedUrlCommand*)command {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendPluginErrorWithError:(NSError*)error command:(CDVInvokedUrlCommand*)command {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.description];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendPluginStringResult:(NSString*)result command:(CDVInvokedUrlCommand*)command callbackId:(NSString*)callbackId {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)sendPluginBoolResult:(BOOL)result command:(CDVInvokedUrlCommand*)command callbackId:(NSString*)callbackId {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)sendPluginDictionaryResult:(NSDictionary*)result command:(CDVInvokedUrlCommand*)command callbackId:(NSString*)callbackId {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)sendPluginDictionaryResultAndKeepCallback:(NSDictionary*)result command:(id<CDVCommandDelegate>)commandDelegate callbackId:(NSString*)callbackId {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [pluginResult setKeepCallbackAsBool:YES];
    [commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)sendPluginStringResultAndKeepCallback:(NSString*)result command:(id<CDVCommandDelegate>)commandDelegate callbackId:(NSString*)callbackId {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:result];
    [pluginResult setKeepCallbackAsBool:YES];
    [commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void) handleEmptyResultWithPotentialError:(NSError*) error command:(CDVInvokedUrlCommand*)command {
     if (error) {
         [self sendPluginErrorWithError:error command:command];
     }else{
         [self sendPluginSuccess:command];
     }
}

- (void) handleStringResultWithPotentialError:(NSError*) error command:(CDVInvokedUrlCommand*)command result:(NSString*)result {
     if (error) {
         [self sendPluginErrorWithError:error command:command];
     }else{
         [self sendPluginStringResult:result command:command callbackId:command.callbackId];
     }
}

- (void) handleBoolResultWithPotentialError:(NSError*) error command:(CDVInvokedUrlCommand*)command result:(BOOL)result {
     if (error) {
         [self sendPluginErrorWithError:error command:command];
     }else{
         [self sendPluginBoolResult:result command:command callbackId:command.callbackId];
     }
}

- (void) handlePluginExceptionWithContext: (NSException*) exception :(CDVInvokedUrlCommand*)command
{
    [self handlePluginExceptionWithoutContext:exception];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:exception.reason];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) handlePluginExceptionWithoutContext: (NSException*) exception
{
    [self _logError:[NSString stringWithFormat:@"EXCEPTION: %@", exception.reason]];
}

- (void) handlePluginErrorWithoutContext: (NSError*) error
{
    [self _logError:[NSString stringWithFormat:@"ERROR: %@", error.description]];
}

- (void)executeGlobalJavascript: (NSString*)jsString
{
    if(pluginInitialized){
        [self doExecuteGlobalJavascript:jsString];
    }else{
        if(pendingGlobalJS == nil){
            pendingGlobalJS = [[NSMutableArray alloc] init];
        }
        [pendingGlobalJS addObject:jsString];
    }
}

- (void) executePendingGlobalJavascript
{
    if(pendingGlobalJS == nil){
        NSLog(@"%@ No pending global JS calls", LOG_TAG);
        return;
    }
    NSLog(@"%@ Executing %lu pending global JS calls", LOG_TAG, (unsigned long)pendingGlobalJS.count);
    for (NSString* jsString in pendingGlobalJS) {
        [self doExecuteGlobalJavascript:jsString];
    }
    pendingGlobalJS = nil;
}

- (void)doExecuteGlobalJavascript: (NSString*)jsString
{
    [self.commandDelegate evalJs:jsString];
}

- (void)_logError: (NSString*)msg
{
    NSLog(@"%@ ERROR: %@", LOG_TAG, msg);
    NSString* jsString = [NSString stringWithFormat:@"console.error(\"%@: %@\")", LOG_TAG, [self escapeJavascriptString:msg]];
    [self executeGlobalJavascript:jsString];
}

- (void)_logInfo: (NSString*)msg
{
    NSLog(@"%@ INFO: %@", LOG_TAG, msg);
    NSString* jsString = [NSString stringWithFormat:@"console.info(\"%@: %@\")", LOG_TAG, [self escapeJavascriptString:msg]];
    [self executeGlobalJavascript:jsString];
}

- (void)_logMessage: (NSString*)msg
{
    NSLog(@"%@ LOG: %@", LOG_TAG, msg);
    NSString* jsString = [NSString stringWithFormat:@"console.log(\"%@: %@\")", LOG_TAG, [self escapeJavascriptString:msg]];
    [self executeGlobalJavascript:jsString];
}

- (NSString*)escapeJavascriptString: (NSString*)str
{
    NSString* result = [str stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
    result = [result stringByReplacingOccurrencesOfString: @"\"" withString: @"\\\""];
    result = [result stringByReplacingOccurrencesOfString: @"\n" withString: @"\\\n"];
    return result;
}

- (void)runOnMainThread:(void (^)(void))completeBlock {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                completeBlock();
            }@catch (NSException *exception) {
                [self handlePluginExceptionWithoutContext:exception];
            }
        });
    } else {
        @try {
            completeBlock();
        }@catch (NSException *exception) {
            [self handlePluginExceptionWithoutContext:exception];
        }
    }
}

- (void) setPreferenceFlag:(NSString*) name flag:(BOOL)flag {
    [preferences setBool:flag forKey:name];
    [preferences synchronize];
}

- (BOOL) getPreferenceFlag:(NSString*) name {
    if([preferences objectForKey:name] == nil){
        return false;
    }
    return [preferences boolForKey:name];
}

- (BOOL) getGooglePlistFlagWithDefaultValue:(NSString*) name defaultValue:(BOOL)defaultValue {
    if([googlePlist objectForKey:name] == nil){
        return defaultValue;
    }
    id value = [googlePlist objectForKey:name];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    } else {
        // Note that `isEqualToString` would crash if the value is not a string.
        return [value isEqual:@"true"];
    }
}


# pragma mark - Stubs
- (void)createChannel:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)setDefaultChannel:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)deleteChannel:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)listChannels:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

@end

