var exec = require('cordova/exec');

var ensureBooleanFn = function (callback){
    return function(result){
        callback(ensureBoolean(result));
    }
};

var ensureBoolean = function(value){
    if(value === "true"){
        value = true;
    }else if(value === "false"){
        value = false;
    }
    return !!value;
};

var onInstallationIdChangeCallback = function(){};
var onApplicationDidBecomeActiveCallback = function(){};
var onApplicationDidEnterBackgroundCallback = function(){};

/***********************
 * Protected internals
 ***********************/
exports._onInstallationIdChangeCallback = function(installationId){
    onInstallationIdChangeCallback(installationId);
};

// iOS only
exports._applicationDidBecomeActive = function(){
    onApplicationDidBecomeActiveCallback();
};

exports._applicationDidEnterBackground = function(){
    onApplicationDidEnterBackgroundCallback();
};

/**************
 * Public API
 **************/

// Notifications
exports.getToken = function (success, error) {
  exec(success, error, "FirebasePlugin", "getToken", []);
};

exports.getAPNSToken = function (success, error) {
  exec(success, error, "FirebasePlugin", "getAPNSToken", []);
};

exports.onMessageReceived = function (success, error) {
  exec(success, error, "FirebasePlugin", "onMessageReceived", []);
};

exports.onTokenRefresh = function (success, error) {
  exec(success, error, "FirebasePlugin", "onTokenRefresh", []);
};

exports.onApnsTokenReceived = function (success, error) {
    exec(success, error, "FirebasePlugin", "onApnsTokenReceived", []);
};

exports.subscribe = function (topic, success, error) {
  exec(success, error, "FirebasePlugin", "subscribe", [topic]);
};

exports.unsubscribe = function (topic, success, error) {
  exec(success, error, "FirebasePlugin", "unsubscribe", [topic]);
};

exports.unregister = function (success, error) {
  exec(success, error, "FirebasePlugin", "unregister", []);
};

exports.isAutoInitEnabled = function (success, error) {
    exec(success, error, "FirebasePlugin", "isAutoInitEnabled", []);
};

exports.setAutoInitEnabled = function (enabled, success, error) {
    exec(success, error, "FirebasePlugin", "setAutoInitEnabled", [!!enabled]);
};

// Notifications - iOS-only
exports.onOpenSettings = function (success, error) {
  exec(success, error, "FirebasePlugin", "onOpenSettings", []);
};

exports.setBadgeNumber = function (number, success, error) {
    exec(success, error, "FirebasePlugin", "setBadgeNumber", [number]);
};

exports.getBadgeNumber = function (success, error) {
    exec(success, error, "FirebasePlugin", "getBadgeNumber", []);
};

exports.grantPermission = function (success, error, requestWithProvidesAppNotificationSettings) {
    exec(ensureBooleanFn(success), error, "FirebasePlugin", "grantPermission", [ensureBoolean(requestWithProvidesAppNotificationSettings)]);
};

exports.grantCriticalPermission = function (success, error) {
    exec(ensureBooleanFn(success), error, "FirebasePlugin", "grantCriticalPermission", []);
};

exports.hasPermission = function (success, error) {
    exec(ensureBooleanFn(success), error, "FirebasePlugin", "hasPermission", []);
};

exports.hasCriticalPermission = function (success, error) {
    exec(ensureBooleanFn(success), error, "FirebasePlugin", "hasCriticalPermission", []);
};

// Notifications - Android-only
exports.setDefaultChannel = function (options, success, error) {
    exec(success, error, "FirebasePlugin", "setDefaultChannel", [options]);
};

exports.createChannel = function (options, success, error) {
    exec(success, error, "FirebasePlugin", "createChannel", [options]);
};

exports.deleteChannel = function (channelID, success, error) {
    exec(success, error, "FirebasePlugin", "deleteChannel", [channelID]);
};

exports.listChannels = function (success, error) {
    exec(success, error, "FirebasePlugin", "listChannels", []);
};

exports.clearAllNotifications = function (success, error) {
  exec(success, error, "FirebasePlugin", "clearAllNotifications", []);
};

// Installations
exports.getId = function (success, error) {
    exec(success, error, "FirebasePlugin", "getId", []);
};

exports.getInstallationId = function (success, error) {
    exec(success, error, "FirebasePlugin", "getInstallationId", []);
};

exports.getInstallationToken = function (success, error) {
    exec(success, error, "FirebasePlugin", "getInstallationToken", []);
};

exports.deleteInstallationId = function (success, error) {
    exec(success, error, "FirebasePlugin", "deleteInstallationId", []);
};

exports.registerInstallationIdChangeListener = function(fn){
    if(typeof fn !== "function") throw "The specified argument must be a function";
    onInstallationIdChangeCallback = fn;
};

// iOS App Lifecycle
exports.registerApplicationDidBecomeActiveListener = function(fn){
    if(typeof fn !== "function") throw "The specified argument must be a function";
    onApplicationDidBecomeActiveCallback = fn;
};

exports.registerApplicationDidEnterBackgroundListener = function(fn){
    if(typeof fn !== "function") throw "The specified argument must be a function";
    onApplicationDidEnterBackgroundCallback = fn;
};
