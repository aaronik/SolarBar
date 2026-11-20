# SolarBar

A native macOS menu-bar monitor for Victron off-grid power systems, inspired by [PulseBar](https://github.com/aaronik/PulseBar). The menu bar shows two-minute sparklines for battery charge (mint, fixed 0–100%), solar (amber), and AC power (purple). AC apparent power uses its own VA scale. Click it for a dark dashboard with a rolling 24 hours of locally saved live history, including separate battery charge, signed battery power, and battery voltage charts. Use the **Menu Bar** pills near the bottom of the dashboard to independently show or hide **Battery %**, **Battery Power**, **Solar**, and **AC Output / AC Load**. Battery Power is a blue line on its own symmetric watt scale: above the center line is charging, below is discharging. These choices are saved, and they don’t change the dashboard charts or data collection. Below the pills, use the **Refresh Rate** slider (2–30 seconds) to control sampling; it does not change how often Bluetooth devices broadcast. All dropdown charts use the same time range based on the available history and leave gaps where a reading is missing.

## Build and launch

Requires macOS 13 or later and Swift 6 (Xcode or the Command Line Tools). No third-party app dependencies.

```sh
SOLARBAR_SIGN_IDENTITY="<installed Apple signing identity>" ./build.sh
open -g build/SolarBar.app
```

SolarBar lives in the menu bar, not the Dock. It starts in **Victron Bluetooth** mode by default. To try it without hardware, choose **Settings → Source → Demo** and click **Apply**. The amber dot indicates demo mode. The menu-bar bolt only appears when there’s no visible graph data. For a permanent installation, move the built app to `/Applications`. The local build is signed for use on this Mac, not notarized.

### Keep Bluetooth and Keychain approvals across updates

Ad-hoc signing identifies one exact build. If you rebuild with it, macOS can ask again for Bluetooth and for each saved advertisement key, even if you previously clicked **Always Allow**. To keep approvals stable without changing certificate trust settings, use an Apple Development or Developer ID Application signing identity already installed on your Mac. List available identities with `security find-identity -v -p codesigning`, then use `SOLARBAR_SIGN_IDENTITY="<identity name or SHA-1>" ./build.sh`. Keep using the same identity. SolarBar does not install certificates or change trust settings, and the build will not silently fall back to ad-hoc signing.

When moving from an old ad-hoc build to the consistently signed build, macOS may ask once for Bluetooth and once per existing advertisement key. Use **Always Allow** for the saved keys if you trust the app. Keep launching the same installed copy and rebuild with the same identity afterward. This setup does not delete or export your existing Victron keys. For disposable testing only, `SOLARBAR_SIGN_IDENTITY=- ./build.sh` opts into ad-hoc signing and may cause repeated prompts.

## Connect directly over Bluetooth

1. Allow Bluetooth access when macOS asks. If you previously denied it, go to **System Settings → Privacy & Security → Bluetooth** and allow SolarBar.
2. In **VictronConnect**, open your device, go to **Settings → ⋯ → Product info**, enable **Instant Readout via Bluetooth** if needed, then open **Instant Readout Details → Show**. Copy the 32-character **Advertisement Key**. It is not the Bluetooth PIN.
3. Return to the SolarBar menu-bar panel. Under **Nearby Victron Devices**, click **Add key** next to the matching device, click **Paste** (or press **⌘V** in the field), and save. Repeat for each device. You don't need its MAC address. If a device doesn't appear, disconnect from it in VictronConnect, check its firmware and Instant Readout setting, and move closer.

SolarBar only listens for [Victron Instant Readout](https://www.victronenergy.com/media/pg/VictronConnect_Manual/en/stored-trends---instant-readout.html) BLE advertisements. It never pairs, connects to, or writes to equipment. An advertisement identifies the device but its readings are encrypted; no key can be derived just from listening. Keys are saved in your Mac’s Keychain, per device, and can be replaced or forgotten using the device's **Key…** button. Don't post the keys publicly. No GX, VRM, or internet access is required.

**Readings vary by model.** SmartShunt/BMV and Lynx Smart BMS can show state of charge, battery voltage, current, and estimated battery power (voltage × current). Supported MPPT, Inverter RS and Multi RS records can show solar watts and daily yield. VE.Bus and RS records can provide AC output watts; a basic inverter may only broadcast apparent power (VA). SolarBar uses that reading when real watts are unavailable, labels it VA, and plots it on a separate dashboard scale instead of treating it as watts. If the inverter reports only AC voltage, the dashboard shows that voltage and leaves the AC load line blank rather than inferring power. Device cards also show available readings for supported Orion DC–DC, Smart Battery Sense, BatteryProtect, Lithium Smart, AC charger, and DC meter records. Newer or unknown record types can be discovered but may not be decoded. Some Bluetooth products don't broadcast Instant Readout at all.

The dashboard prefers a fresh battery monitor over inverter battery data. It sums fresh solar reports and uses a single inverter for AC output to avoid double-counting parallel equipment. These are not whole-system totals if some equipment is missing, not reporting, or out of range. Bluetooth AC output does not identify generator versus shore versus grid. Readings expire after about 25 seconds without a new advertisement, plus up to one dashboard refresh interval. Unavailable readings show **—**. The footer shows the time of the last decoded broadcast, not the time the dashboard polled. Charts are snapshots of the latest fresh readings at the selected interval.

Live chart history is saved as samples arrive in `~/Library/Application Support/SolarBar/history-v1.sqlite` and restored after restarts. Bluetooth and each GX endpoint have separate histories; demo readings are never saved. No device keys or raw advertisements are included. The charts retain a rolling 24 hours at any refresh interval and reduce dense lines for display while preserving peaks, dips, and gaps. History starts with this version; broadcasts missed while the app is closed cannot be recovered.

## Optional: Victron GX over the LAN

If you prefer GX system totals, enable **Modbus TCP** on your Cerbo GX or other Venus OS device under **Settings → Services** (or **Integrations**, depending on firmware). In SolarBar choose **Settings → Source → Victron GX (LAN)**, enter the GX's LAN address, and leave port **502** unless your system uses another. Allow macOS Local Network access if prompted. The app sends only [GX Modbus](https://www.victronenergy.com/live/ccgx:modbustcp_faq) reads to system unit 100. Modbus TCP is not authenticated; keep it on a trusted LAN and do not port-forward it. Cloud-only VRM is not supported.

## Development

```sh
swift build
./test.sh
```

Tests cover known encrypted [Victron packet fixtures](https://github.com/keshavdv/victron-ble/tree/main/tests), missing values, multi-device aggregation, chart gaps, and the GX TCP client against a localhost-only simulator. Tests use Swift and Python 3; no Victron hardware is needed. The decoder follows Victron’s [advertisement format](https://github.com/keshavdv/victron-ble/blob/main/extra-manufacturer-data-2022-12-14.pdf).
