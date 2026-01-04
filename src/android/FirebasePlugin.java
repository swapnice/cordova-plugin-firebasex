package org.apache.cordova.firebase;

import android.app.Activity;
import android.app.NotificationManager;
import android.app.NotificationChannel;
import android.content.ContentResolver;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.RingtoneManager;
import android.net.Uri;
import android.media.AudioAttributes;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import android.util.Log;

import com.google.android.gms.tasks.OnCompleteListener;
import com.google.android.gms.tasks.Task;
import com.google.firebase.FirebaseApp;
import com.google.firebase.installations.FirebaseInstallations;
import com.google.firebase.installations.InstallationTokenResult;
import com.google.firebase.messaging.FirebaseMessaging;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.Set;

import static android.content.Context.MODE_PRIVATE;

public class FirebasePlugin extends CordovaPlugin {

    protected static FirebasePlugin instance = null;
    private static CordovaInterface cordovaInterface = null;
    protected static Context applicationContext = null;
    private static Activity cordovaActivity = null;
    private static boolean pluginInitialized = false;
    private static boolean onPageFinished = false;
    private static ArrayList<String> pendingGlobalJS = null;
    protected static final String TAG = "FirebasePlugin";
    protected static final String JS_GLOBAL_NAMESPACE = "FirebasePlugin.";
    protected static final String SETTINGS_NAME = "settings";

    protected static final String POST_NOTIFICATIONS = "POST_NOTIFICATIONS";
    protected static final int POST_NOTIFICATIONS_PERMISSION_REQUEST_ID = 1;

    private static boolean inBackground = true;
    private static boolean immediateMessagePayloadDelivery = false;
    private static ArrayList<Bundle> notificationStack = null;
    private static CallbackContext notificationCallbackContext;
    private static CallbackContext tokenRefreshCallbackContext;
    private static CallbackContext postNotificationPermissionRequestCallbackContext;

    private static NotificationChannel defaultNotificationChannel = null;
    public static String defaultChannelId = null;
    public static String defaultChannelName = null;

    @Override
    protected void pluginInitialize() {
        instance = this;
        cordovaActivity = this.cordova.getActivity();
        applicationContext = cordovaActivity.getApplicationContext();
        final Bundle extras = cordovaActivity.getIntent().getExtras();
        FirebasePlugin.cordovaInterface = this.cordova;
        this.cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    Log.d(TAG, "Starting Firebase plugin");

                    immediateMessagePayloadDelivery = getPluginVariableFromConfigXml("FIREBASE_MESSAGING_IMMEDIATE_PAYLOAD_DELIVERY").equals("true");

                    FirebaseApp.initializeApp(applicationContext);

                    if (extras != null && extras.size() > 1) {
                        if (FirebasePlugin.notificationStack == null) {
                            FirebasePlugin.notificationStack = new ArrayList<Bundle>();
                        }
                        if (extras.containsKey("google.message_id")) {
                            extras.putString("messageType", "notification");
                            extras.putString("tap", "background");
                            notificationStack.add(extras);
                            Log.d(TAG, "Notification message found on init: " + extras.toString());
                        }
                    }
                    defaultChannelId = getStringResource("default_notification_channel_id");
                    defaultChannelName = getStringResource("default_notification_channel_name");
                    createDefaultChannel();
                    pluginInitialized = true;
                    // If the webview has already reported page finished, flush any pending global JS
                    if (onPageFinished) {
                        executePendingGlobalJavascript();
                    }

                } catch (Exception e) {
                    handleExceptionWithoutContext(e);
                }
            }
        });
    }

    @Override
    public Object onMessage(String id, Object data){
        if (id == null) {
            return super.onMessage(id, data);
        }
        if("onPageFinished".equals(id)){
            Log.d(TAG, "Page ready init javascript");
            onPageFinished = true;
            executePendingGlobalJavascript();
            return null;
        }
        return super.onMessage(id, data);
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        try {
            switch (action) {
                case "getId":
                    this.getInstallationId(args, callbackContext);
                    break;
                case "getToken":
                    this.getToken(args, callbackContext);
                    break;
                case "hasPermission":
                    this.hasPermission(callbackContext);
                    break;
                case "grantPermission":
                    this.grantPermission(callbackContext);
                    break;
                case "subscribe":
                    this.subscribe(callbackContext, args.getString(0));
                    break;
                case "unsubscribe":
                    this.unsubscribe(callbackContext, args.getString(0));
                    break;
                case "isAutoInitEnabled":
                    this.isAutoInitEnabled(callbackContext);
                    break;
                case "setAutoInitEnabled":
                    this.setAutoInitEnabled(callbackContext, args.getBoolean(0));
                    break;
                case "unregister":
                    this.unregister(callbackContext);
                    break;
                case "onMessageReceived":
                    this.onMessageReceived(callbackContext);
                    break;
                case "onTokenRefresh":
                    this.onTokenRefresh(callbackContext);
                    break;
                case "clearAllNotifications":
                    this.clearAllNotifications(callbackContext);
                    break;
                case "createChannel":
                    this.createChannel(callbackContext, args.getJSONObject(0));
                    break;
                case "deleteChannel":
                    this.deleteChannel(callbackContext, args.getString(0));
                    break;
                case "listChannels":
                    this.listChannels(callbackContext);
                    break;
                case "setDefaultChannel":
                    this.setDefaultChannel(callbackContext, args.getJSONObject(0));
                    break;
                case "deleteInstallationId":
                    this.deleteInstallationId(callbackContext);
                    break;
                case "getInstallationId":
                    this.getInstallationId(args, callbackContext);
                    break;
                case "getInstallationToken":
                    this.getInstallationToken(callbackContext);
                    break;
                // iOS-only stubs
                case "grantCriticalPermission":
                case "hasCriticalPermission":
                case "setBadgeNumber":
                case "getBadgeNumber":
                case "onOpenSettings":
                case "onApnsTokenReceived":
                case "getAPNSToken":
                    callbackContext.success();
                    break;
                default:
                    callbackContext.error("Invalid action: " + action);
                    return false;
            }
        } catch (Exception e) {
            handleExceptionWithContext(e, callbackContext);
            return false;
        }
        return true;
    }

    @Override
    public void onPause(boolean multitasking) {
        FirebasePlugin.inBackground = true;
    }

    @Override
    public void onResume(boolean multitasking) {
        FirebasePlugin.inBackground = false;
        if (FirebasePlugin.notificationCallbackContext != null) {
            sendPendingNotifications();
        }
    }

    @Override
    public void onReset() {
        FirebasePlugin.notificationCallbackContext = null;
        FirebasePlugin.tokenRefreshCallbackContext = null;
    }

    @Override
    public void onDestroy() {
        instance = null;
        cordovaActivity = null;
        cordovaInterface = null;
        applicationContext = null;
        onReset();
        super.onDestroy();
    }

    /**
     * Get a string from resources without importing the .R package
     *
     * @param name Resource Name
     * @return Resource
     */
    private String getStringResource(String name) {
        return applicationContext.getString(
                applicationContext.getResources().getIdentifier(
                        name, "string", applicationContext.getPackageName()
                )
        );
    }

    private void onMessageReceived(final CallbackContext callbackContext) {
        FirebasePlugin.notificationCallbackContext = callbackContext;
        sendPendingNotifications();
    }

    private synchronized void sendPendingNotifications() {
        if (FirebasePlugin.notificationStack != null) {
            this.cordova.getThreadPool().execute(new Runnable() {
                public void run() {
                    try {
                        for (Bundle bundle : FirebasePlugin.notificationStack) {
                            FirebasePlugin.sendMessage(bundle, applicationContext);
                        }
                        FirebasePlugin.notificationStack.clear();
                    } catch (Exception e) {
                        handleExceptionWithoutContext(e);
                    }
                }
            });
        }
    }

    private void onTokenRefresh(final CallbackContext callbackContext) {
        FirebasePlugin.tokenRefreshCallbackContext = callbackContext;

        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    FirebaseMessaging.getInstance().getToken().addOnCompleteListener(new OnCompleteListener<String>() {
                        @Override
                        public void onComplete(@NonNull Task<String> task) {
                            try {
                                if (task.isSuccessful() || task.getException() == null) {
                                    String currentToken = task.getResult();
                                    if (currentToken != null) {
                                        FirebasePlugin.sendToken(currentToken);
                                    }
                                } else if (task.getException() != null) {
                                    callbackContext.error(task.getException().getMessage());
                                } else {
                                    callbackContext.error("Task failed for unknown reason");
                                }
                            } catch (Exception e) {
                                handleExceptionWithContext(e, callbackContext);
                            }
                        }
                    });
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    public static void sendMessage(Bundle bundle, Context context) {
        if (!FirebasePlugin.hasNotificationsCallback() || (inBackground && !immediateMessagePayloadDelivery)) {
            String packageName = context.getPackageName();
            if (FirebasePlugin.notificationStack == null) {
                FirebasePlugin.notificationStack = new ArrayList<Bundle>();
            }
            notificationStack.add(bundle);

            return;
        }

        final CallbackContext callbackContext = FirebasePlugin.notificationCallbackContext;
        if (bundle != null) {
            // Pass the message bundle to the receiver manager so any registered receivers can decide to handle it
            boolean wasHandled = FirebasePluginMessageReceiverManager.sendMessage(bundle);
            if (wasHandled) {
                Log.d(TAG, "Message bundle was handled by a registered receiver");
            } else if (callbackContext != null) {
                JSONObject json = new JSONObject();
                Set<String> keys = bundle.keySet();
                for (String key : keys) {
                    try {
                        json.put(key, bundle.get(key));
                    } catch (JSONException e) {
                        handleExceptionWithContext(e, callbackContext);
                        return;
                    }
                }
                FirebasePlugin.instance.sendPluginResultAndKeepCallback(json, callbackContext);
            }
        }
    }

    public static void sendToken(String token) {
        if (FirebasePlugin.tokenRefreshCallbackContext == null) {
            return;
        }

        final CallbackContext callbackContext = FirebasePlugin.tokenRefreshCallbackContext;
        if (callbackContext != null && token != null) {
            FirebasePlugin.instance.sendPluginResultAndKeepCallback(token, callbackContext);
        }
    }

    public static boolean inBackground() {
        return FirebasePlugin.inBackground;
    }

    public static boolean hasNotificationsCallback() {
        return FirebasePlugin.notificationCallbackContext != null;
    }

    @Override
    public void onNewIntent(Intent intent) {
        try {
            super.onNewIntent(intent);
            final Bundle data = intent.getExtras();
            if (data != null && data.containsKey("google.message_id")) {
                data.putString("messageType", "notification");
                data.putString("tap", "background");
                Log.d(TAG, "Notification message on new intent: " + data.toString());
                FirebasePlugin.sendMessage(data, applicationContext);
            }
        } catch (Exception e) {
            handleExceptionWithoutContext(e);
        }
    }


    private void getToken(JSONArray args, final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    FirebaseMessaging.getInstance().getToken().addOnCompleteListener(new OnCompleteListener<String>() {
                        @Override
                        public void onComplete(@NonNull Task<String> task) {
                            try {
                                if (task.isSuccessful() || task.getException() == null) {
                                    String currentToken = task.getResult();
                                    callbackContext.success(currentToken);
                                } else if (task.getException() != null) {
                                    callbackContext.error(task.getException().getMessage());
                                } else {
                                    callbackContext.error("Task failed for unknown reason");
                                }
                            } catch (Exception e) {
                                handleExceptionWithContext(e, callbackContext);
                            }
                        }
                    });

                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void hasPermission(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    NotificationManagerCompat notificationManagerCompat = NotificationManagerCompat.from(cordovaActivity);
                    boolean areNotificationsEnabled = notificationManagerCompat.areNotificationsEnabled();

                    boolean hasRuntimePermission = true;
                    if (Build.VERSION.SDK_INT >= 33) { // Android 13+
                        hasRuntimePermission = hasRuntimePermission(POST_NOTIFICATIONS);
                    }

                    callbackContext.success(conformBooleanForPluginResult(areNotificationsEnabled && hasRuntimePermission));
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void grantPermission(final CallbackContext callbackContext) {
        CordovaPlugin plugin = this;
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    if (Build.VERSION.SDK_INT >= 33) { // Android 13+
                        boolean hasRuntimePermission = hasRuntimePermission(POST_NOTIFICATIONS);
                        if (!hasRuntimePermission) {
                            String[] permissions = new String[]{qualifyPermission(POST_NOTIFICATIONS)};
                            postNotificationPermissionRequestCallbackContext = callbackContext;
                            requestPermissions(plugin, POST_NOTIFICATIONS_PERMISSION_REQUEST_ID, permissions);
                            sendEmptyPluginResultAndKeepCallback(callbackContext);
                        }
                    } else {
                        // No runtime permission required on Android 12 and below
                        callbackContext.success(1);
                    }

                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void subscribe(final CallbackContext callbackContext, final String topic) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    handleTaskOutcome(FirebaseMessaging.getInstance().subscribeToTopic(topic), callbackContext);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void unsubscribe(final CallbackContext callbackContext, final String topic) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    handleTaskOutcome(FirebaseMessaging.getInstance().unsubscribeFromTopic(topic), callbackContext);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void unregister(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    handleTaskOutcome(FirebaseMessaging.getInstance().deleteToken(), callbackContext);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void isAutoInitEnabled(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    boolean isEnabled = FirebaseMessaging.getInstance().isAutoInitEnabled();
                    callbackContext.success(conformBooleanForPluginResult(isEnabled));
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void setAutoInitEnabled(final CallbackContext callbackContext, final boolean enabled) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    FirebaseMessaging.getInstance().setAutoInitEnabled(enabled);
                    callbackContext.success();
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void clearAllNotifications(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
                    notificationManager.cancelAll();
                    callbackContext.success();
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    // Notification Channels
    private void createDefaultChannel() {
        this.createChannel(null, defaultChannelId, defaultChannelName, null, null, null, null, null, null, null, null);
    }

    private void createChannel(final CallbackContext callbackContext, final JSONObject options) {
        String id = null, name = null, description = null, sound = null, lightColor = null;
        Integer importance = null, visibility = null, usage = null, streamType = null;
        Boolean vibration = null, light = null, badge = null;

        try {
            id = options.getString("id");
            name = options.getString("name");
        } catch (JSONException e) {
            // Minimum required options not specified
        }

        try {
            description = options.getString("description");
        } catch (JSONException e) {}
        try {
            sound = options.getString("sound");
        } catch (JSONException e) {}
        try {
            importance = options.getInt("importance");
        } catch (JSONException e) {}
        try {
            visibility = options.getInt("visibility");
        } catch (JSONException e) {}
        try {
            vibration = options.getBoolean("vibration");
        } catch (JSONException e) {}
        try {
            light = options.getBoolean("light");
        } catch (JSONException e) {}
        try {
            lightColor = options.getString("lightColor");
        } catch (JSONException e) {}
        try {
            badge = options.getBoolean("badge");
        } catch (JSONException e) {}
        try {
            usage = options.getInt("usage");
        } catch (JSONException e) {}
        try {
            streamType = options.getInt("streamType");
        } catch (JSONException e) {}

        this.createChannel(callbackContext, id, name, description, sound, importance, visibility, vibration, light, lightColor, badge);
    }

    private void createChannel(final CallbackContext callbackContext, final String id, final String name, final String description, final String sound, final Integer importance, final Integer visibility, final Boolean vibration, final Boolean light, final String lightColor, final Boolean badge) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        int _importance = importance != null ? importance : NotificationManager.IMPORTANCE_DEFAULT;
                        boolean _vibration = vibration != null ? vibration : true;
                        boolean _light = light != null ? light : true;
                        boolean _badge = badge != null ? badge : true;

                        NotificationChannel channel = new NotificationChannel(id, name, _importance);
                        channel.setDescription(description);
                        channel.enableVibration(_vibration);
                        channel.enableLights(_light);
                        channel.setShowBadge(_badge);

                        if (visibility != null) {
                            channel.setLockscreenVisibility(visibility);
                        }

                        if (lightColor != null) {
                            channel.setLightColor(android.graphics.Color.parseColor(lightColor));
                        }

                        AudioAttributes audioAttributes = new AudioAttributes.Builder()
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                                .build();

                        if (sound != null && !sound.contentEquals("default")) {
                            Uri soundUri = Uri.parse(ContentResolver.SCHEME_ANDROID_RESOURCE + "://" + applicationContext.getPackageName() + "/raw/" + sound);
                            channel.setSound(soundUri, audioAttributes);
                        } else if (sound == null || sound.contentEquals("default")) {
                            Uri defaultSoundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
                            channel.setSound(defaultSoundUri, audioAttributes);
                        }

                        NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
                        notificationManager.createNotificationChannel(channel);

                        if (id.equals(defaultChannelId)) {
                            defaultNotificationChannel = channel;
                        }
                    }

                    if (callbackContext != null) {
                        callbackContext.success();
                    }
                } catch (Exception e) {
                    if (callbackContext != null) {
                        handleExceptionWithContext(e, callbackContext);
                    } else {
                        handleExceptionWithoutContext(e);
                    }
                }
            }
        });
    }

    private void deleteChannel(final CallbackContext callbackContext, final String channelID) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
                        notificationManager.deleteNotificationChannel(channelID);
                    }
                    callbackContext.success();
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void listChannels(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    JSONArray channels = new JSONArray();
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
                        for (NotificationChannel channel : notificationManager.getNotificationChannels()) {
                            JSONObject channelInfo = new JSONObject();
                            channelInfo.put("id", channel.getId());
                            channelInfo.put("name", channel.getName());
                            channels.put(channelInfo);
                        }
                    }
                    callbackContext.success(channels);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void setDefaultChannel(final CallbackContext callbackContext, final JSONObject options) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        // Delete existing default channel
                        NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
                        notificationManager.deleteNotificationChannel(defaultChannelId);
                    }
                    // Create new one
                    createChannel(callbackContext, options);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    // Installations
    private void getInstallationId(JSONArray args, final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    FirebaseInstallations.getInstance().getId().addOnCompleteListener(new OnCompleteListener<String>() {
                        @Override
                        public void onComplete(@NonNull Task<String> task) {
                            try {
                                if (task.isSuccessful()) {
                                    callbackContext.success(task.getResult());
                                } else if (task.getException() != null) {
                                    callbackContext.error(task.getException().getMessage());
                                } else {
                                    callbackContext.error("Task failed for unknown reason");
                                }
                            } catch (Exception e) {
                                handleExceptionWithContext(e, callbackContext);
                            }
                        }
                    });
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void getInstallationToken(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    FirebaseInstallations.getInstance().getToken(false).addOnCompleteListener(new OnCompleteListener<InstallationTokenResult>() {
                        @Override
                        public void onComplete(@NonNull Task<InstallationTokenResult> task) {
                            try {
                                if (task.isSuccessful()) {
                                    callbackContext.success(task.getResult().getToken());
                                } else if (task.getException() != null) {
                                    callbackContext.error(task.getException().getMessage());
                                } else {
                                    callbackContext.error("Task failed for unknown reason");
                                }
                            } catch (Exception e) {
                                handleExceptionWithContext(e, callbackContext);
                            }
                        }
                    });
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private void deleteInstallationId(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    handleTaskOutcome(FirebaseInstallations.getInstance().delete(), callbackContext);
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    /*
     * Permissions
     */
    public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) throws JSONException {
        try {
            if (requestCode == POST_NOTIFICATIONS_PERMISSION_REQUEST_ID) {
                boolean permissionGranted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
                postNotificationPermissionRequestCallbackContext.success(conformBooleanForPluginResult(permissionGranted));
            }
        } catch (Exception e) {
            handleExceptionWithoutContext(e);
        }
    }

    private boolean hasRuntimePermission(String permission) throws Exception {
        boolean result = true;
        String qualifiedPermission = qualifyPermission(permission);
        java.lang.reflect.Method method = null;
        try {
            method = cordova.getClass().getMethod("hasPermission", String.class);
            result = (Boolean) method.invoke(cordova, qualifiedPermission);
        } catch (NoSuchMethodException e) {
            Log.w(TAG, "Cordova v6.4+ is required to handle " + permission);
        }
        return result;
    }

    private void requestPermissions(CordovaPlugin plugin, int requestCode, String[] permissions) throws Exception {
        try {
            java.lang.reflect.Method method = cordova.getClass().getMethod("requestPermissions", org.apache.cordova.CordovaPlugin.class, int.class, String[].class);
            method.invoke(cordova, plugin, requestCode, permissions);
        } catch (NoSuchMethodException e) {
            Log.w(TAG, "Cordova v6.4+ is required to handle runtime permissions");
        }
    }

    private String qualifyPermission(String permission) {
        return "android.permission." + permission;
    }

    /*
     * Helper methods
     */
    private String getPluginVariableFromConfigXml(String key) {
        int resourceId = applicationContext.getResources().getIdentifier(key.toLowerCase(), "string", applicationContext.getPackageName());
        if (resourceId != 0) {
            return applicationContext.getString(resourceId);
        }
        return "";
    }

    private void handleTaskOutcome(Task task, CallbackContext callbackContext) {
        task.addOnCompleteListener(new OnCompleteListener() {
            @Override
            public void onComplete(@NonNull Task task) {
                try {
                    if (task.isSuccessful() || task.getException() == null) {
                        callbackContext.success();
                    } else if (task.getException() != null) {
                        callbackContext.error(task.getException().getMessage());
                    } else {
                        callbackContext.error("Task failed for unknown reason");
                    }
                } catch (Exception e) {
                    handleExceptionWithContext(e, callbackContext);
                }
            }
        });
    }

    private int conformBooleanForPluginResult(boolean value) {
        return value ? 1 : 0;
    }

    private void sendPluginResultAndKeepCallback(Object result, CallbackContext callbackContext) {
        PluginResult pluginResult;
        if (result instanceof String) {
            pluginResult = new PluginResult(PluginResult.Status.OK, (String) result);
        } else if (result instanceof JSONObject) {
            pluginResult = new PluginResult(PluginResult.Status.OK, (JSONObject) result);
        } else if (result instanceof JSONArray) {
            pluginResult = new PluginResult(PluginResult.Status.OK, (JSONArray) result);
        } else {
            pluginResult = new PluginResult(PluginResult.Status.OK);
        }
        pluginResult.setKeepCallback(true);
        callbackContext.sendPluginResult(pluginResult);
    }

    private void sendEmptyPluginResultAndKeepCallback(CallbackContext callbackContext) {
        PluginResult pluginResult = new PluginResult(PluginResult.Status.NO_RESULT);
        pluginResult.setKeepCallback(true);
        callbackContext.sendPluginResult(pluginResult);
    }

    private static void handleExceptionWithContext(Exception e, CallbackContext callbackContext) {
        Log.e(TAG, e.getMessage());
        e.printStackTrace();
        callbackContext.error(e.getMessage());
    }

    public static void handleExceptionWithoutContext(Exception e) {
        Log.e(TAG, e.getMessage());
        e.printStackTrace();
    }

    public static boolean channelExists(String channelId) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager notificationManager = (NotificationManager) applicationContext.getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel channel = notificationManager.getNotificationChannel(channelId);
            return channel != null;
        }
        return false;
    }

    private void executeGlobalJavascript(final String jsString) {
        cordovaActivity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    webView.loadUrl("javascript:" + jsString);
                } catch (Exception e) {
                    handleExceptionWithoutContext(e);
                }
            }
        });
    }

    private void executePendingGlobalJavascript() {
        if (pendingGlobalJS == null) {
            Log.d(TAG, "No pending global JS calls");
            return;
        }
        Log.d(TAG, "Executing " + pendingGlobalJS.size() + " pending global JS calls");
        for (String jsString : pendingGlobalJS) {
            executeGlobalJavascript(jsString);
        }
        pendingGlobalJS = null;
    }

    public static void sendInstallationIdChange(String installationId) {
        if (instance != null) {
            instance.executeGlobalJavascript(JS_GLOBAL_NAMESPACE + "_onInstallationIdChangeCallback(\"" + installationId + "\")");
        }
    }
}
