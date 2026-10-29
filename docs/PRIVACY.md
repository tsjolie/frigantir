# Frigantir — Privacy Policy

*Effective date: October 29, 2026*

This policy explains how **Frigantir** (the "app"), an iOS client for the Frigate network video recorder,
handles your information. Frigantir is developed by Tristan Sjolie ("I", "me").

## Summary

- **I don't collect any of your data.** The app has no accounts, analytics, advertising, tracking or crash
  reporting, and it never sends anything to me or to any third party chosen by me.
- The app talks only to **servers you choose**: your own Frigate server and, if you turn on notifications,
  a notification server. Apple delivers notifications through its push service.
- Your settings and passwords stay **on your device**. Deleting the app deletes them.

## Information I collect

None. I don't operate any server that the app contacts, and I have no way to see your cameras, recordings,
events, server addresses, passwords or usage of the app.

## Information stored on your device

| What | Where | Why |
|---|---|---|
| Your Frigate server address and display preferences | App settings on the device | To connect to your server and remember your choices |
| Your Frigate username and password | iOS Keychain | To sign in to your Frigate server |
| Notification server address and access token | iOS Keychain / app settings | To register for notifications, only if you turn them on |
| Notification thumbnails | Temporary storage on the device | To show a picture in a notification |
| Export videos you download | The app's cache on the device | To play, save or share them without downloading again; removed when you delete the export in the app |

This data stays on your device. It is not shared with me. Deleting the app removes it.

## Who the app communicates with

**Your Frigate server.** The app connects directly to the Frigate server at the address you enter to show
live video, audio, recordings, events and camera snapshots, and to sign in. That server is run by you (or by
whoever gave you access to it), and its operator controls the data on it.

**A notification server (optional).** If you turn on notifications, the app sends the notification server
you enter:

- your device's push notification token,
- whether the app is a development or App Store build,
- your device's name (for example "Alex's iPhone"), and
- which cameras and alert types you want to be notified about.

The notification server uses this only to send you notifications. When it sends one, the notification can
contain the camera name, what was detected (for example "Person" or "Car"), the zones involved, and — if your
Frigate server uses face or licence-plate recognition — the **recognised name or plate**. It can also include
a link to the event's thumbnail image, which your device downloads from the notification server. Thumbnail
links are signed and expire after one hour.

The notification server is software you run yourself (or that the person who runs your Frigate server
provides). Its operator controls this data. If you use a notification server run by someone else, their
privacy practices apply to it. You can unregister at any time by turning notifications off in the app.

**Apple Push Notification service (APNs).** Notifications are delivered to your device by Apple. The
notification text described above passes through Apple's servers in order to reach your device, and is
handled under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

Apart from these, the app makes no network connections.

**Sharing.** When you share an exported video, it goes only where you send it from the iOS share sheet (for
example Messages, AirDrop or Files).

## Information I don't collect

The app does not collect or access your location, contacts, microphone or camera, health data, advertising
identifier, browsing history or any usage, diagnostic or crash data. It can't see the photos in your library:
its only Photos access is adding a video when you ask it to (see Permissions). It contains no third-party
analytics, advertising or tracking code, and it does not track you across other apps or websites.

## Permissions

- **Local Network** — to connect to a Frigate or notification server on your home network.
- **Notifications** — only if you turn on notifications, to show alerts from your notification server.
- **Photos (add only)** — only when you tap Download on an export, to save that video to your photo library.
  This permission lets the app add videos, not see your existing photos.

You can change these at any time in the iOS Settings app.

## Security

Passwords and tokens are stored in the iOS Keychain. Connections to servers on the internet must use HTTPS;
the app allows unencrypted HTTP only to addresses on your local network. The security of your Frigate and
notification servers is the responsibility of whoever runs them.

## Retention and deletion

Because I don't receive your data, I have none to retain or delete. Data on your device is removed when you
delete the app. Data held by your Frigate or notification server is kept and deleted by that server's
operator; the reference notification server removes a device when it is unregistered or when Apple reports
the device token as no longer valid, and keeps its record of which events it has already sent for 24 hours.

## Children

The app is not directed at children under 13 (or the equivalent age in your country), and I don't knowingly
collect information from anyone, including children.

## Your rights

Depending on where you live, you may have rights to access, correct or delete personal data held about you.
I hold no personal data about users of the app. For data on a Frigate or notification server, please contact
that server's operator. You are welcome to contact me with any privacy question.

## Changes to this policy

If this policy changes, the updated version will be published at the address above with a new effective date.
Significant changes will also be mentioned in the app's release notes.

## Contact

Tristan Sjolie — [tsjolie@gmail.com](mailto:tsjolie@gmail.com)
