# Frigantir: push notifier

Frigate can't send Apple push notifications itself. This small self-hosted service fills that gap. It watches
Frigate for new review items (alerts and detections) and sends Apple Push Notification service (APNs)
pushes to the iPhones running **Frigantir**.

```
                  MQTT frigate/reviews                    HTTPS (HTTP/2)
  ┌─────────┐   or WebSocket /ws   ┌──────────┐   api.push.apple.com   ┌──────┐        ┌────────┐
  │ Frigate │ ───────────────────▶ │ notifier │ ─────────────────────▶ │ APNs │ ─────▶ │ iPhone │
  └─────────┘                      └──────────┘                        └──────┘        └────────┘
                                        ▲                                                   │
                                        └──────── register device token (HTTPS + API token) ┘
```

- The notifier connects **out** to Frigate (MQTT or WebSocket) and **out** to Apple.
- The phone talks to the notifier only to register, update or unregister itself and to request a test push. It
  never receives events from the notifier directly. Everything goes through Apple.
- Devices live in a small SQLite database in `/data`.

## Contents

1. [Prerequisites](#prerequisites)
2. [Create an APNs key](#create-an-apns-key)
3. [Sandbox vs production](#sandbox-vs-production)
4. [Build the image](#build-the-image)
5. [Run it](#run-it): docker run, docker compose, Kubernetes
6. [Expose it to the phone](#expose-it-to-the-phone)
7. [Configure the app](#configure-the-app)
8. [Notification thumbnails](#notification-thumbnails)
9. [Environment variables](#environment-variables)
10. [HTTP API](#http-api)
11. [Troubleshooting](#troubleshooting)
12. [Development](#development)

## Prerequisites

- **Frigate**, with one of:
  - MQTT enabled (`mqtt:` in the Frigate config) and a broker the notifier can reach. This is the default and
    is recommended.
  - Or network access to Frigate's web port for the WebSocket source. Use this if you run Frigate without MQTT.
- **Outbound HTTPS** (TCP 443) from the notifier to `api.push.apple.com` and `api.sandbox.push.apple.com`.
- An **Apple Developer account** that can create an APNs key for the app's bundle ID
  (`net.sjolie.frigateapp` by default).
- Docker, or a Kubernetes cluster. Images build for `linux/amd64` and `linux/arm64`.

## Create an APNs key

One key works for all your apps and for both sandbox and production. The notifier signs a short-lived token
with it ("token-based auth"), so you don't need certificates that expire every year.

1. Sign in to <https://developer.apple.com/account> and open **Certificates, Identifiers & Profiles**.
2. **Keys** → **+**. Enter a name (e.g. "Frigate notifier"), tick **Apple Push Notifications service (APNs)**,
   then **Continue** → **Register**.
3. **Download** the `AuthKey_XXXXXXXXXX.p8` file. **You can only download it once.** Keep it somewhere safe.
4. Note the **Key ID** (10 characters, shown on the key page and in the file name). This is `APNS_KEY_ID`.
5. Note your **Team ID** (top right of the portal, or **Membership details**). This is `APNS_TEAM_ID`.
6. Under **Identifiers**, open the app's App ID (`net.sjolie.frigateapp`) and make sure the **Push
   Notifications** capability is enabled. If you build the app yourself, Xcode normally does this when you
   add the Push Notifications capability.

> The bundle ID the app registers with must belong to the same team as the key. If it doesn't, APNs
> answers `DeviceTokenNotForTopic`.

## Sandbox vs production

APNs has two separate environments, and a device token only works in the environment it was issued for:

| How the app was installed  | Environment  | APNs host                    |
|----------------------------|--------------|------------------------------|
| Run from Xcode (debug)     | `sandbox`    | `api.sandbox.push.apple.com` |
| TestFlight or App Store    | `production` | `api.push.apple.com`         |

The app detects this and includes `environment` when it registers. The notifier picks the host per device,
so you can have both kinds of device on one server. You don't need to configure anything for this.

## Build the image

```sh
cd notifier
docker build -t frigate-notifier:latest .
```

To build for both amd64 and arm64 (e.g. a Raspberry Pi or a mixed cluster) and push to your registry:

```sh
docker buildx create --use --name multiarch   # once
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.example.com/frigate-notifier:latest --push .
```

The image is `python:3.12-slim` and runs as a non-root user (uid `10001`). It listens on port `8080`, stores
data in the `/data` volume, and has a `HEALTHCHECK` that calls `/api/v1/health`.

## Run it

First generate an API token. The app has to send this token on every request:

```sh
openssl rand -hex 32
```

**Key file permissions:** the container runs as uid 10001, so it must be able to read the `.p8` file. You can
`chmod 444 AuthKey.p8`, or `chown 10001` it. In Kubernetes, `defaultMode`/`fsGroup` handles this (see below).

### docker run

```sh
docker run -d --name frigate-notifier --restart unless-stopped \
  -p 8080:8080 \
  -v frigate-notifier-data:/data \
  -v /path/to/AuthKey_ABC123DEFG.p8:/run/secrets/apns.p8:ro \
  -e API_TOKEN=<your token> \
  -e APNS_KEY_ID=ABC123DEFG \
  -e APNS_TEAM_ID=TEAM123456 \
  -e APNS_KEY_FILE=/run/secrets/apns.p8 \
  -e MQTT_HOST=192.168.1.10 \
  -e MQTT_USERNAME=frigate -e MQTT_PASSWORD=secret \
  -e PUBLIC_URL=https://notify.example.com \
  -e FRIGATE_URL=http://192.168.1.10:5000 \
  frigate-notifier:latest
```

Check it:

```sh
curl http://localhost:8080/api/v1/health
# {"status":"ok","source":"mqtt","source_connected":true,"devices":0}
```

### docker compose

```sh
cp docker-compose.example.yml docker-compose.yml
cp .env.example .env          # fill in API_TOKEN, APNS_*, MQTT_* ...
mkdir secrets && cp ~/Downloads/AuthKey_ABC123DEFG.p8 secrets/AuthKey.p8 && chmod 444 secrets/AuthKey.p8
docker compose up -d --build
docker compose logs -f
```

The compose file mounts the key as a read-only secret at `/run/secrets/apns_key` and keeps the database in a
named volume. If Frigate and Mosquitto run in the same compose project, set `MQTT_HOST` to the broker's service
name. For thumbnails, set `PUBLIC_URL` and `FRIGATE_URL` (in `.env` or the commented `environment:` lines).

### Kubernetes

A minimal example. Adjust the namespace, image and MQTT host to fit your setup.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: frigate-notifier
  namespace: frigate
type: Opaque
stringData:
  API_TOKEN: "<openssl rand -hex 32>"
  APNS_KEY_ID: "ABC123DEFG"
  APNS_TEAM_ID: "TEAM123456"
  MQTT_PASSWORD: "secret"
---
apiVersion: v1
kind: Secret
metadata:
  name: frigate-notifier-apns-key
  namespace: frigate
type: Opaque
stringData:
  apns.p8: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: frigate-notifier-data
  namespace: frigate
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frigate-notifier
  namespace: frigate
spec:
  replicas: 1                 # SQLite + dedupe state: run exactly one replica
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: frigate-notifier}
  template:
    metadata:
      labels: {app: frigate-notifier}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
      containers:
        - name: notifier
          image: registry.example.com/frigate-notifier:latest
          ports:
            - {name: http, containerPort: 8080}
          env:
            - {name: SOURCE, value: mqtt}
            - {name: MQTT_HOST, value: mosquitto.frigate.svc.cluster.local}
            - {name: MQTT_USERNAME, value: frigate}
            # Optional: notification thumbnails (both required)
            - {name: PUBLIC_URL, value: https://notify.example.com}
            - {name: FRIGATE_URL, value: http://frigate.frigate.svc.cluster.local:5000}
            - {name: APNS_KEY_FILE, value: /run/secrets/apns/apns.p8}
          envFrom:
            - secretRef:
                name: frigate-notifier   # API_TOKEN, APNS_KEY_ID, APNS_TEAM_ID, MQTT_PASSWORD
          volumeMounts:
            - {name: data, mountPath: /data}
            - {name: apns, mountPath: /run/secrets/apns, readOnly: true}
          readinessProbe:
            httpGet: {path: /api/v1/health, port: http}
          livenessProbe:
            httpGet: {path: /api/v1/health, port: http}
            periodSeconds: 30
          resources:
            requests: {cpu: 10m, memory: 48Mi}
            limits: {memory: 128Mi}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: frigate-notifier-data
        - name: apns
          secret:
            secretName: frigate-notifier-apns-key
            defaultMode: 0440
---
apiVersion: v1
kind: Service
metadata:
  name: frigate-notifier
  namespace: frigate
spec:
  selector: {app: frigate-notifier}
  ports:
    - {name: http, port: 8080, targetPort: http}
```

Alternatively, create the key Secret straight from the file:
`kubectl -n frigate create secret generic frigate-notifier-apns-key --from-file=apns.p8=AuthKey_ABC123DEFG.p8`.

Run **one replica**. The device list and dedupe record are in a local SQLite file.

## Expose it to the phone

The phone has to reach the notifier's HTTP API to register. Pushes themselves come from Apple, so the phone
only needs to reach the notifier when you change settings (and again whenever iOS rotates the device token,
which the app handles).

- **The app requires HTTPS for public hostnames.** Plain `http://` is accepted only for LAN addresses (e.g.
  `http://192.168.1.20:8080`). With a LAN address, the app can only re-register while it's on your network.
- **Recommended:** put it behind the reverse proxy you already use for Frigate (Traefik, Caddy, nginx, NPM...)
  with a TLS certificate, e.g. `https://frigate-notifier.example.com` → `http://notifier:8080`. A VPN such as
  Tailscale or WireGuard works too.
- **Never expose it without `API_TOKEN`.** The service refuses to start without it, so pick a long random token
  and don't reuse your Frigate password. Only `/api/v1/health` (device count only) and
  `/api/v1/thumbnails/...` (signed, expiring links) work without the token.
- If you use [thumbnails](#notification-thumbnails), proxy all of `/api/v1` (including `/api/v1/thumbnails/`)
  and set `PUBLIC_URL` to the external URL.

## Configure the app

In Frigantir, open **Settings → Notifications**:

1. **Server URL**: the notifier's base URL, e.g. `https://frigate-notifier.example.com`. Don't add `/api/v1`.
2. **API token**: the value of `API_TOKEN`.
3. Choose the **severities** you want (Alerts, and optionally Detections) and, optionally, which **cameras**.
   No cameras selected means all cameras.
4. Turn on **Notifications**, tap **Save** and allow notifications when iOS asks. The status line should
   read "Registered with the notification server."
5. Tap **Send test notification**. You should get "Test notification — notifications are working." within a
   few seconds. If you don't, the app shows the APNs error reason (see [Troubleshooting](#troubleshooting)).

## Notification thumbnails

When thumbnails are enabled, each review push carries a link to that review's thumbnail. The app's
notification extension downloads the image from that link and attaches it to the notification. The phone is
often away from home where Frigate isn't reachable, so the image comes **through the notifier**:

```
iPhone ──GET <PUBLIC_URL>/api/v1/thumbnails/<review id>?expires=…&sig=…──▶ notifier ──GET──▶ Frigate
```

- **Turn it on** by setting both `PUBLIC_URL` (the notifier's base URL as phones reach it, e.g.
  `https://notify.example.com`) and `FRIGATE_URL`. In MQTT mode `FRIGATE_URL` is used only for thumbnails.
  If either is missing, pushes are sent without images, exactly as before. The startup log says which mode is
  active.
- **The notifier must reach Frigate over HTTP(S).** The unauthenticated port (5000) is simplest. For the
  authenticated port (8971), also set `FRIGATE_USERNAME`/`FRIGATE_PASSWORD` (and `FRIGATE_VERIFY_TLS=false`
  for a self-signed certificate).
- **Phones must reach `PUBLIC_URL`.** `/api/v1/thumbnails/...` must go through the same reverse proxy as the
  rest of `/api/v1`. Simply proxy the whole path.
- **The links are signed and expire after an hour.** The extension downloads them without an `Authorization`
  header. Instead, each link has an HMAC-SHA256 signature (with a key derived from `API_TOKEN`) over the review
  id and expiry time. A link can't be changed to point at another review, and it stops working after 60
  minutes, the same lifetime as the push itself. If you change `API_TOKEN`, outstanding links stop working.
- The notifier remembers each review's `thumb_path` for 24 h. After a restart, it looks the review up with
  Frigate's `/api/review/<id>`.

## Environment variables

| Variable             | Default                 | Description |
|----------------------|-------------------------|-------------|
| `API_TOKEN`          | **required**            | Bearer token the app must send. Use a long random value. |
| `APNS_KEY_ID`        | **required**            | 10-character Key ID of the APNs key. |
| `APNS_TEAM_ID`       | **required**            | Apple Developer Team ID. |
| `APNS_KEY_FILE`      | –                       | Path to the `.p8` key (e.g. a mounted secret). Set this or `APNS_KEY`. |
| `APNS_KEY`           | –                       | PEM contents of the `.p8` key (literal `\n` sequences are accepted). |
| `APNS_BUNDLE_ID`     | `net.sjolie.frigateapp` | `apns-topic` used when a device registered without a `bundle_id`. |
| `SOURCE`             | `mqtt`                  | `mqtt` or `websocket`. |
| `MQTT_HOST`          | required for mqtt       | MQTT broker host (the one Frigate publishes to). |
| `MQTT_PORT`          | `1883`                  | MQTT broker port. |
| `MQTT_USERNAME`      | –                       | MQTT username. |
| `MQTT_PASSWORD`      | –                       | MQTT password. |
| `MQTT_TOPIC_PREFIX`  | `frigate`               | Frigate's `mqtt.topic_prefix`. The notifier subscribes to `<prefix>/reviews`. |
| `MQTT_TLS`           | `false`                 | Connect to the broker with TLS (system CA store). |
| `FRIGATE_URL`        | required for websocket  | Frigate base URL, e.g. `http://frigate:5000` or `https://frigate.example.com`. In MQTT mode it's optional and only used to fetch [thumbnails](#notification-thumbnails). |
| `FRIGATE_USERNAME`   | –                       | Frigate user. If set, the notifier logs in via `/api/login` (for `/ws` and for thumbnails). |
| `FRIGATE_PASSWORD`   | –                       | Frigate password. |
| `FRIGATE_VERIFY_TLS` | `true`                  | Set `false` for self-signed Frigate certificates. |
| `PUBLIC_URL`         | – (thumbnails off)      | The notifier's base URL as phones reach it, e.g. `https://notify.example.com`. With `FRIGATE_URL`, this enables [thumbnails](#notification-thumbnails). |
| `CAMERAS`            | – (all)                 | Comma-separated allowlist of cameras that may trigger notifications. |
| `COOLDOWN_SECONDS`   | `0` (off)               | Minimum seconds between pushes for the same device and camera. A review that starts during the cooldown is skipped entirely, including its later messages. |
| `VERIFY_WAIT_SECONDS`| `10`                    | For devices that skip recognized people: how long to hold a person-only alert while Frigate's face recognition runs. `0` decides immediately. |
| `DATA_DIR`           | `/data`                 | Where the SQLite database (`notifier.sqlite3`) is stored. |
| `PORT`               | `8080`                  | HTTP listen port. |
| `LOG_LEVEL`          | `INFO`                  | `DEBUG`, `INFO`, `WARNING` or `ERROR`. |

If a required setting is missing, the notifier exits at startup with a message listing every problem. Logs
never contain secrets, and device tokens are truncated to their first 8 characters.

### When a push is sent

- A **new** review item notifies every device subscribed to its severity (`alert` or `detection`).
- A review that is **upgraded** from detection to alert notifies alert subscribers who haven't already been
  notified about it.
- A review first seen as an alert in a later `update` or `end` message also notifies alert subscribers, if it
  started in the last 15 minutes. Frigate doesn't always send `new`: audio alerts (e.g. "speech" on a baby
  camera) arrive as an `update` that is already an alert, then `end`. The 15-minute limit stops a restart from
  replaying old reviews.
- Each push Apple accepts is logged with its `apns-id`. If a logged push doesn't appear on the device, look
  at the device: Focus modes, Settings → Notifications → Frigantir, and notification grouping.
- **Recognized people** (devices registered with `ignore_verified: true`, the app's "Skip alerts for
  recognized people"): an alert whose objects are all `person-verified` (Frigate face recognition knew
  everyone) isn't sent. Audio labels don't count either way. An alert with any unrecognized person or any
  other object is sent. Face recognition usually finishes a few seconds after a review starts, so a
  person-only alert that isn't recognized yet is held for `VERIFY_WAIT_SECONDS`, then sent unless it has
  become recognized. If a stranger or another object shows up during the hold, it's sent right away.
- A device is never notified twice for the same review (remembered for 24 h). Each device's camera list,
  `CAMERAS` and `COOLDOWN_SECONDS` all apply.
- Pushes for the same review share an `apns-collapse-id`, so they replace each other in Notification Center.

## HTTP API

Every endpoint except health requires `Authorization: Bearer <API_TOKEN>` and returns `401` otherwise.
Bodies are JSON.

### `POST /api/v1/devices`

Registers a device, or updates it if the token is already registered.

```json
{"token": "<hex APNs device token>", "environment": "sandbox",
 "bundle_id": "net.sjolie.frigateapp", "device_name": "Tristan's iPhone",
 "severities": ["alert", "detection"], "cameras": [], "ignore_verified": false}
```

- `token`: a hex string, required. It's stored in lowercase.
- `environment`: `sandbox` or `production`, required.
- `severities`: a non-empty subset of `["alert", "detection"]`. Defaults to `["alert"]`.
- `cameras`: a list of camera names. `[]` means all cameras.
- `ignore_verified`: `true` to skip alerts showing only people Frigate recognized (`person-verified`).
  Optional, defaults to `false`.
- `bundle_id` and `device_name`: optional.

Returns `200` with the stored device (the same fields plus `created_at` and `updated_at`), or `400`
`{"error": "..."}` if validation fails.

### `DELETE /api/v1/devices/{token}`

Unregisters a device. Returns `204`, including when the token is unknown.

### `POST /api/v1/devices/{token}/test`

Sends a test push to the device.

- `200` `{"sent": true}`: the push was sent.
- `502` `{"sent": false, "reason": "BadDeviceToken"}`: APNs rejected it. `reason` is the APNs reason.
- `404`: the device is unknown.

### `GET /api/v1/thumbnails/{review_id}?expires=…&sig=…` (signed, no bearer auth)

Returns the review's thumbnail as fetched from Frigate, with Frigate's `Content-Type` and
`Cache-Control: private, max-age=3600`. The signature is the authorization. You never build these URLs
yourself: they arrive in the push payload as `frigate.thumbnail_url`.

- `403`: the signature is missing or invalid, or the link has expired.
- `404`: the review or its thumbnail isn't found, or thumbnails are disabled.
- `502`: Frigate is unreachable or returned an error.

### `GET /api/v1/health` (no auth)

```json
{"status": "ok", "source": "mqtt", "source_connected": true, "devices": 2}
```

### Push payload

```json
{"aps": {"alert": {"title": "Front Door", "body": "Person (Alice) · Driveway"},
         "sound": "default", "thread-id": "front_door", "category": "FRIGATE_REVIEW", "mutable-content": 1},
 "frigate": {"review_id": "1791293688.0-abc123", "camera": "front_door", "severity": "alert",
             "start_time": 1791293688.0, "thumb_path": "/media/frigate/clips/review/thumb-...webp",
             "labels": ["person"], "sub_labels": ["Alice"], "zones": ["driveway"],
             "thumbnail_url": "https://notify.example.com/api/v1/thumbnails/1791293688.0-abc123?expires=1791297288&sig=…"}}
```

`thumbnail_url` is present only when [thumbnails](#notification-thumbnails) are enabled. It's never in test
pushes.

## Troubleshooting

Start with `docker logs frigate-notifier` (or `kubectl logs`). Every failed push is logged with the status and
reason APNs returned.

| Symptom / APNs reason | Cause and fix |
|-----------------------|---------------|
| `BadDeviceToken` | The token doesn't match the environment: a debug build from Xcode (sandbox) sent to production, or the reverse. The app reports its environment, so this usually clears up once the app re-registers. The notifier deletes the device when this happens, so open the app's notification settings to register again. |
| `DeviceTokenNotForTopic` | The `bundle_id` (apns-topic) doesn't match the app the token belongs to, or the APNs key belongs to a different team than the app. Check `APNS_TEAM_ID`, and that the key and App ID are in the same team. The device is deleted. |
| `Unregistered` (410) | The app was uninstalled or notifications were turned off. The device is deleted automatically. |
| `InvalidProviderToken` | Wrong `APNS_KEY_ID`/`APNS_TEAM_ID`, or the key was revoked. Check both values against the portal. |
| `ExpiredProviderToken` | Usually **clock skew**. APNs rejects tokens whose timestamp is off by more than about an hour. Make sure the host runs NTP (`timedatectl`). The notifier refreshes its token every 50 minutes and retries once when it sees this error. |
| `TopicDisallowed` | Push Notifications isn't enabled on the App ID. |
| `NetworkError: ...` | The notifier can't reach Apple. Allow outbound TCP 443 to `api.push.apple.com` and `api.sandbox.push.apple.com` (HTTP/2). |
| Test push works, but no notifications for events | Check `GET /api/v1/health`. If `source_connected` is `false`, the notifier can't reach MQTT or Frigate, and the logs say why. With MQTT, check that Frigate has `mqtt.enabled: true`, that both use the same broker, and that `MQTT_TOPIC_PREFIX` matches Frigate's `topic_prefix`. Watch the topic with `mosquitto_sub -h <broker> -t 'frigate/reviews' -v` while walking past a camera. Also check that the review items have the severity you subscribed to (only "Alerts" by default), and check the camera filters and `CAMERAS`. |
| WebSocket source keeps reconnecting | Check `FRIGATE_URL` (use the port the web UI uses). Behind authentication (port 8971), set `FRIGATE_USERNAME`/`FRIGATE_PASSWORD`. For self-signed certificates, set `FRIGATE_VERIFY_TLS=false`. |
| Notifications arrive without images | Check the startup log for "Thumbnails enabled". Request a `thumbnail_url` (e.g. from a fresh push payload): `403` means the clock is wrong or the link is older than an hour, `404` means Frigate doesn't know the review, and `502` means the notifier can't reach Frigate (check `FRIGATE_URL` and credentials). Make sure the reverse proxy forwards `/api/v1/thumbnails/` and that `PUBLIC_URL` is the external HTTPS URL. |
| App says unauthorized | `API_TOKEN` in the app doesn't match the server. Check for stray whitespace. |
| `PermissionError` reading the key | The container runs as uid 10001. Make the `.p8` readable (`chmod 444`) or set `fsGroup`/`defaultMode` in Kubernetes. |

## Development

```sh
cd notifier
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest -q
```

Layout: `app/config.py` (env settings), `app/sources.py` (MQTT and WebSocket readers with reconnect),
`app/notify.py` (who to notify, dedupe, cooldown), `app/formatting.py` (push payloads), `app/apns.py`
(HTTP/2 client and JWT), `app/thumbnails.py` (signed links, Frigate image proxy), `app/api.py` (HTTP API),
`app/store.py` (SQLite).
