# GoPro GPS Cam (Flutter: Android and iOS)

Take photos with a GoPro from a phone or tablet, and stamp each photo with the phone's GPS position.

1. The app triggers the GoPro's shutter over Bluetooth LE, using GoPro's official Open GoPro API.
2. It records the phone's GPS position at the moment you press the button.
3. It downloads the photo over the GoPro's Wi-Fi.
4. It writes the GPS into the photo's EXIF without re-encoding the image. The camera's own details, such as model, exposure and thumbnail, are kept.
5. It saves the photo in a folder of your choice. Optionally it also saves a copy to the phone gallery and records a GPS track as a KMZ map.

**Works with:** HERO9 Black and newer (HERO9, 10, 11, 12 and 13).

## Install

- `gopro_gps_cam_arm64.apk` (about 30 MB) suits most phones and tablets from the last few years.
- `gopro_gps_cam.apk` (about 95 MB) is the universal version. Use it on older phones if the small one says it isn't compatible.

Copy the file to the device, open it, and allow "install unknown apps". The emulator can't be used because it has no Bluetooth.

## The main screen

| Phone | Tablet / landscape |
|---|---|
| Camera bar at the top, map in the middle, controls at the bottom | Map on the left, controls and recent photos on the right |

- **Camera bar:** shows the connected camera at a glance. It turns orange with a ⚠ when something needs attention, such as the camera not being in Photo mode or its clock being more than a minute out. Tap it for the camera panel, which has the mode, the clocks with **Set camera time from tablet**, **Disconnect**, and the connection log.
- **Map:** shows your position (blue dot and accuracy circle).
  - The **GPS ±n m** badge is green at 10 m or better, orange up to 25 m, and red above that. Tap it for details and tips.
  - The layers button switches the map imagery.
  - While a track is recording, a red **REC** badge shows the distance and photo count, with **FINISH**.
- **Buttons:** **Connect to GoPro** when nothing is connected. Once connected, **Take photo** and **Live view**.
- **Folder** (📁): the folder new photos are saved into. Tap it to change folder, create one, or delete an empty one.
- **Record track:** a GPS track (KMZ map) starts with the first photo and ends when you close the app.
- **Recent photos:** tap one to open it. **All (n)** opens the whole folder.
- **Top right:** 🖼 all photos, ⚙ settings: review photos before saving, save to the gallery, GPS-only mode, saved tracks and the connection log.

## Camera settings (survey preset)

Open it from the camera panel (tap the camera bar) or **⚙ Settings → Camera settings**. The screen reads the camera's current photo settings over Bluetooth and shows each one next to the recommended survey value. Green means it already matches; orange means it doesn't.

| Setting | Recommended | Why |
|---|---|---|
| Photo output | RAW (+ JPEG) | Keeps the sensor data; no aggressive JPEG processing |
| Digital lens | Linear | Straight quadrat border |
| Shutter | 1/250 s or 1/500 s | Removes micro-blur from hand shake and wave bounce |
| EV compensation | −0.5 | Stops caustics bleaching white coral, sand and shells |
| ISO min | 100 | Lowest noise |
| ISO max | 400 (800 when deeply overcast) | Grain isn't mistaken for substrate texture |
| White balance | Auto, or 5500 K if colour-correcting the batch | |
| Sharpness | Medium or Low | High adds edge artefacts |

Settings that don't match are ticked and pre-set to the recommended value. Change any drop-down (★ marks recommended options) or untick a row, then tap **Apply**. The app switches the camera to Photo mode, applies the settings in a safe order (Protune or Pro controls first, lens before RAW, ISO min before ISO max), reads them back, and shows the result on each row.

- The camera reports which options it allows. Some combinations aren't possible on some models (for example RAW with certain lenses), and the row then explains this.
- Settings the camera doesn't have are shown as "Not available on this camera".
- Changes apply to the camera's current Photo preset.
- **RAW files:** the app downloads and GPS-tags the JPEG. The `.GPR` RAW file stays on the SD card with the same file number.
- Each change and the camera's reply are written to the connection log.

## Map position looks wrong (for example 50 m out)?

A wrong-looking position has one of two causes:

1. **The phone's GPS fix is poor.** The blue circle is then large, the badge is orange or red, and the dot wanders. Indoors, near tall buildings, or right after starting, phones use Wi-Fi and mobile-network positioning, which can easily be 30–100 m out. To fix it:
   - Go outside and wait a minute.
   - Turn on **Use GPS satellites only** (in settings, or from the GPS badge).
   - Check that Android Settings → Location → Location services → Google Location Accuracy is on.
2. **The imagery is misaligned.** The circle is then small and the badge green, but the dot is beside where you actually are. Tap the layers button to compare:
   - **Esri World Imagery** (default)
   - **Esri Clarity**: a different, often sharper imagery set
   - **NSW Government aerial imagery**: NSW only, surveyed and very accurate
   - **OpenStreetMap street map**

   If the dot sits on the right road on the street map or the NSW imagery, the default imagery is the problem, so use the other layer.

Whichever layer you look at, the GPS written into the photos is the phone's fix, not the map.

Map tiles are cached. While the phone is on the GoPro's Wi-Fi it has no internet, so look at the area on the map before connecting.

## First-time pairing

1. On the GoPro, go to **Preferences → Wireless Connections → Connect Device → GoPro Quik** to put it in pairing mode.
2. In the app, tap **Connect to GoPro**, pick the camera, and accept Android's **Pair** request. On some phones it appears as a notification.
3. If automatic pairing doesn't work, the app explains how to pair in Android's Bluetooth settings, with buttons for **Open Bluetooth settings** and **Try again**.

After that, the camera only needs to be switched on.

## Connecting: what the app does

- **Bluetooth:** the app pairs with the camera first if needed. It then connects without scanning at the same time, lets the link settle, and retries up to 4 times, clearing Android's cached service list on each retry. This avoids the "android code 133" error on older phones.
- **Wi-Fi:** the app waits for the camera's Wi-Fi to come up, joins it (allowing 30 seconds), then waits up to 30 seconds for the camera to respond. It retries up to 3 times.
- **Photo mode:** the app checks the camera is in Photo mode after connecting and before every shot. If it isn't, it offers to switch it.
- **Connection log:** each step is logged with timings. Open it from the camera panel or settings, and copy it if you need help.

## Photos

- **Review:** after each shot the photo fills the screen with **Keep** and **Discard**. This can be turned off in settings.
- **Opening a photo:** shows the GPS read back from the saved file. **Move** sends it to another folder, and **Share** sends the original with GPS.
- **Storage:** photos are saved in `Documents/GoProGPS/<folder>/`. Gallery copies go to the album "GoPro GPS - <folder>".
- **GPS removed by other apps:** Android strips GPS from photos that other apps read out of the gallery; it zeroes the coordinates. Use the app's **Share** button or a USB cable to keep the GPS.

## GPS tracks (KMZ)

- **What's in the file:** `Documents/GoProGPS_Tracks/Track_<date>_<time>.kmz` contains the route as a red line, start and end markers, and a thumbnail at each photo. It opens in Google Earth or Google My Maps.
- **Recording in the background:** recording continues with the app in the background, and Android shows a notification while it does.
- **Keeping the file current:** the KMZ is updated after every photo. If Android closes the app, the track is completed the next time it opens.
- **Finishing:** recording stops when you press Back on the main screen ("Finish & close") or tap **FINISH**.

## Live view

The live view shows the camera's preview, with a big shutter button so you can take the photo at the right moment. While it waits for video it shows how much has arrived from the camera. If nothing arrives, check the camera is on its normal shooting screen, not a menu or playback.

## Building from source (Android Studio)

1. Install Android Studio and the Flutter SDK, then add the Flutter plugin in Android Studio.
2. Open this folder (the one with `pubspec.yaml`) and click **Pub get**.
3. Connect a phone with USB debugging on, select it in the device list, and click **Run ▶**. You can also run `flutter build apk --release --split-per-abi`.
4. If you get Gradle, AGP or Kotlin version errors with an older Flutter, run `flutter upgrade`, or run `powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Regenerate` to rebuild the `android` folder.

Tests: run `flutter test`. These use a fake camera in `test/support/`.

**iOS** needs a Mac with Xcode and an Apple developer account. Run `flutter create --platforms ios .` and add the usage strings from `setup.ps1` to `ios/Runner/Info.plist`. Then add the **Hotspot Configuration** and **Access Wi-Fi Information** capabilities.

## Code map

| File | Purpose |
|---|---|
| `lib/ui/home_page.dart` | Main screen layout (phone and tablet), dialogs |
| `lib/ui/position_map.dart` | Map, imagery choice, GPS badge and details |
| `lib/ui/camera_sheet.dart`, `clock_card.dart`, `camera_picker.dart` | Camera panel, clocks, camera list |
| `lib/ui/camera_settings_page.dart`, `lib/services/camera_settings.dart` | Survey camera settings (ids, recommended values, apply) |
| `lib/gopro/packets.dart` | Open GoPro multi-packet BLE messages |
| `lib/ui/live_view_page.dart`, `lib/gopro/preview_relay.dart` | Live view |
| `lib/ui/review_page.dart`, `photo_page.dart`, `folders.dart` | Keep/Discard, photo viewer and gallery, folders |
| `lib/ui/settings_page.dart`, `tracks_page.dart`, `log_page.dart` | Settings, saved tracks, connection log |
| `lib/gopro/camera.dart`, `gopro_ble.dart`, `gopro_wifi.dart` | GoPro control (Bluetooth, Wi-Fi, media) |
| `android/.../MainActivity.kt` | Android Bluetooth pairing helper |
| `lib/services/capture_service.dart` | Connect → shoot → tag → review → save |
| `lib/services/location_service.dart`, `exif/exif_gps_writer.dart` | GPS and EXIF writing |
| `lib/services/track_recorder.dart`, `kml_builder.dart`, `thumbnailer.dart` | GPS track and KMZ |
| `lib/services/photo_library.dart`, `app_settings.dart`, `connection_log.dart` | Folders, preferences, log |

## Licences and notes

- **Bluetooth library:** `flutter_blue_plus` is free for personal, nonprofit and educational use. Businesses need a commercial licence; then change `License.nonprofit` in `lib/gopro/gopro_ble.dart`. It sends basic build telemetry to its maintainer.
- **Map imagery:**
  - Esri: © Esri, Maxar, Earthstar Geographics. Free for non-commercial use.
  - NSW imagery: © Spatial Services NSW, CC BY 4.0.
  - Street map: © OpenStreetMap contributors.
- **Altitude:** height above sea level on Android 14 and newer, otherwise GPS height above the WGS-84 ellipsoid.
- **Photos only:** video isn't supported. Each new `.JPG` on the SD card after the shutter is treated as the photo.
