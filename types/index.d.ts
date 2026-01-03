export interface IChannelOptions {
    id: string
    name?: string
    description?: string
    sound?: string
    vibration?: boolean | number[]
    light?: boolean
    lightColor?: string
    importance?: 0 | 1 | 2 | 3 | 4
    badge?: boolean
    visibility?: -1 | 0 | 1
    usage?: number
    streamType?: number
}

export interface FirebasePlugin {
    // Messaging - Token
    getId(
        success: (value: string) => void,
        error: (err: string) => void
    ): void
    getToken(
        success: (value: string) => void,
        error: (err: string) => void
    ): void
    onTokenRefresh(
        success: (value: string) => void,
        error: (err: string) => void): void
    getAPNSToken(
        success: (value: string) => void,
        error: (err: string) => void
    ): void
    onApnsTokenReceived(
        success: (value: string) => void,
        error: (err: string) => void
    ): void

    // Messaging - Messages
    onMessageReceived(
        success: (value: object) => void,
        error: (err: string) => void
    ): void
    onOpenSettings(
        success: () => void,
        error: (err: string) => void
    ): void

    // Messaging - Permissions
    grantPermission(
        success: (value: boolean) => void,
        error: (err: string) => void,
        requestWithProvidesAppNotificationSettings?: boolean
    ): void
    hasPermission(
        success: (value: boolean) => void,
        error: (err: string) => void
    ): void
    grantCriticalPermission(
        success: (value: boolean) => void,
        error: (err: string) => void
    ): void
    hasCriticalPermission(
        success: (value: boolean) => void,
        error: (err: string) => void
    ): void

    // Messaging - Registration
    unregister(): void
    subscribe(
        topic: string,
        success?: () => void,
        error?: (err: string) => void
    ): void
    unsubscribe(
        topic: string,
        success?: () => void,
        error?: (err: string) => void
    ): void
    isAutoInitEnabled(
        success: (enabled: boolean) => void,
        error?: (err: string) => void
    ): void
    setAutoInitEnabled(
        enabled: boolean,
        success?: () => void,
        error?: (err: string) => void
    ): void

    // Messaging - Badge (iOS)
    setBadgeNumber(
        badgeNumber: number
    ): void
    getBadgeNumber(
        success: (badgeNumber: number) => void,
        error: (err: string) => void
    ): void
    clearAllNotifications(): void

    // Messaging - Channels (Android)
    createChannel(
        channel: IChannelOptions,
        success: () => void,
        error: (err: string) => void
    ): void
    setDefaultChannel(
        channel: IChannelOptions,
        success: () => void,
        error: (err: string) => void
    ): void
    deleteChannel(
        channel: string,
        success: () => void,
        error: (err: string) => void
    ): void
    listChannels(
        success: (list: { id: string; name: string }[]) => void,
        error: (err: string) => void
    ): void

    // Installations
    getInstallationId(
        success: (id: string) => void,
        error: (err: string) => void
    ): void
    getInstallationToken(
        success: (token: string) => void,
        error: (err: string) => void
    ): void
    deleteInstallationId(
        success: () => void,
        error: (err: string) => void
    ): void
    registerInstallationIdChangeListener(
        fn: (installationId: string) => void,
    ): void

    // iOS App Lifecycle
    registerApplicationDidBecomeActiveListener(
        fn: () => void,
    ): void
    registerApplicationDidEnterBackgroundListener(
        fn: () => void,
    ): void
}

declare global {
    const FirebasePlugin: FirebasePlugin;
}
