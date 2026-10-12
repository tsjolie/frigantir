# Frigantir — Support

Frigantir is an iPhone and iPad app for viewing a **Frigate** network video recorder: live cameras,
recordings, events and alerts.

## Contact

Email **[tsjolie@gmail.com](mailto:tsjolie@gmail.com)** with questions, problems or feedback. Please include
your iPhone or iPad model, iOS version, Frigate version and what you were doing when the problem happened.

## You need your own Frigate server

**Frigantir doesn't include cameras, recording or a cloud service.** It connects to an existing
[Frigate](https://frigate.video) installation that you (or someone who gives you access) already run. Without
a Frigate server, the app has nothing to show.

You need:

- **Frigate 0.14 or newer**, already set up with your cameras.
- **An iPhone or iPad running iOS 18 / iPadOS 18 or later.**
- **A way to reach Frigate from your device:** on your home network, over a VPN such as Tailscale or WireGuard,
  or through a reverse proxy with HTTPS.
- **Your Frigate username and password**, if Frigate's authentication is turned on.

Frigantir is an independent app. It isn't made by or affiliated with the Frigate project.

## Connecting to Frigate

In the app's settings, under **Frigate server**:

1. Enter your Frigate address, for example `https://frigate.example.com` or `http://192.168.1.10:8971`.
   Use Frigate's port **8971**, or the address of your reverse proxy in front of it.
2. Enter your username and password if Frigate's authentication is enabled.
3. Save. Your cameras should appear on the dashboard.

Addresses on the internet must use **HTTPS**. Plain `http://` works only for addresses on your local network.

## Notifications (optional)

Frigate can't send iPhone notifications itself, so notifications need a separate **notification server**
connected to your Frigate. If whoever runs your Frigate server has set one up, they'll give you its address
and an API token. Everything else in the app works without it.

To turn notifications on, open **Settings → Notifications**, enter the notification server address and
API token, choose which cameras and alert types you want, turn on **Notifications**, tap **Save** and allow
notifications when iOS asks. Then tap **Send test notification** to check it works.

## Troubleshooting

**The app can't connect to Frigate.** Open your Frigate address in Safari on the same device. If it doesn't
load there, the problem is the network path, not the app: check that you're on your home network or VPN,
and that the address and port are right. If the app asked for **Local Network** access and you declined,
turn it on in iOS **Settings → Privacy & Security → Local Network**.

**Sign-in fails.** Check the username and password by signing in to Frigate's web page in Safari. Make sure
you're using port 8971 (the port with sign-in), not Frigate's internal port 5000.

**Live video doesn't play.** Check that the same camera plays in Frigate's own web page. Frigantir uses the
same live streams as Frigate's web interface.

**No notifications.**

- "The notification server rejected the API token." The token in the app doesn't match the server.
- "Notifications are turned off for this app in iOS Settings." Turn them on in iOS **Settings → Notifications
  → Frigantir**.
- Test notifications arrive but real ones don't: check which cameras and alert types you chose. By default only
  Frigate *alerts* (not detections) are sent.
- If you reinstalled the app or switched between a TestFlight and an App Store version, open
  **Settings → Notifications** and tap **Save** again to re-register.

## Privacy

Frigantir doesn't collect any data. Read the [privacy policy](/privacy).
