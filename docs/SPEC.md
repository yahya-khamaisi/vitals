# Vitals: behaviour and APIs

Everything is sampled on one background queue every 1–5 s (Settings › Update every), then published to the panel and the menu bar together. The menu-bar images are redrawn once per sample.

## 1. Readings

| Reading | Behaviour | macOS API |
|---|---|---|
| CPU usage | Per-core ticks, deltas between samples. User includes nice. | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` |
| Core types | Performance or efficiency, per logical CPU. | IODeviceTree `cluster-type`, `logical-cpu-id` |
| CPU frequency | Average over busy time per cluster, from performance-state residency and the power manager's frequency table. | `libIOReport` "CPU Core Performance States", `pmgr` `voltage-states1/5-sram` |
| GPU usage | Device, renderer and tiler utilization, memory in use. | `IOAccelerator` `PerformanceStatistics` |
| GPU frequency and power | Residency-weighted frequency; energy delta over time. | `libIOReport` "GPU Performance States", "Energy Model" |
| CPU power | Shown only where the Energy Model reports it (zero on M5). | `libIOReport` "Energy Model" |
| Load average, uptime | — | `getloadavg`, `kern.boottime` |
| Memory | App = internal − purgeable; cached = external + purgeable; used = app + wired + compressed. | `host_statistics64(HOST_VM_INFO64)` |
| Memory pressure | Level (normal / warning / critical) and a 0–100% history. | `kern.memorystatus_vm_pressure_level`, `kern.memorystatus_level` |
| Swap | — | `vm.swapusage` |
| Volumes | Browsable mounted volumes; free is "available for important usage". | `FileManager.mountedVolumeURLs` |
| Disk activity | Sum of bytes read and written across drives. | `IOBlockStorageDriver` `Statistics` |
| SMART, model | Every 5 minutes. | `diskutil info -plist` |
| Network speed | 64-bit counters of the primary interface. | `sysctl NET_RT_IFLIST2`, `SCDynamicStore` `State:/Network/Global/IPv4` |
| Wi‑Fi | RSSI and transmit rate; SSID only where macOS allows it without Location. | CoreWLAN |
| Public IP | Every 10 minutes and on interface change; can be turned off. | `https://api.ipify.org` |
| Latency | One ping to the router and to 1.1.1.1 every 10 s. | `/sbin/ping` |
| Per-process traffic | Only while the Network page is open, every 3 s. | `nettop -P -d -L 2` |
| Processes | CPU % and resident memory. | `ps -Aceo pid,pcpu,rss,comm` |
| Battery | Level, time, charging; cycles, raw and design capacity, voltage, current; adapter watts. | `IOPSCopyPowerSourcesInfo`, `AppleSmartBattery`, `IOPSCopyExternalPowerAdapterDetails` |
| Temperatures | SMC keys averaged by group: `Tp*` performance cores, `Te*` efficiency cores, `Tg*` GPU, `TH*` SSD, `TB*T` battery, `TW0P` Wi‑Fi, `TAOL` ambient, `Ts0P/Ts1P` palm rest. Intel `TC0P`, `TG0P` and others. HID sensors add the SoC die (`PMU tdie*`), NAND and gauge. | `AppleSMC`, `IOHIDEventSystemClient` (temperature events) |
| Power, voltage, current | `PSTR` system total, `PPBR` battery, `PDTR` adapter, `VP0R`, `VD0R`, `IPBR`, `ID0R`. | `AppleSMC` |
| Fans | Actual, minimum and maximum speed; mode. | SMC `FNum`, `F%dAc`, `F%dMn`, `F%dMx`, `F%dMd` / `F%dmd` |
| Bluetooth batteries | Apple HID devices from the registry; others from System Profiler every 2 minutes. | `AppleDeviceManagementHIDEventService` `BatteryPercent`, `system_profiler SPBluetoothDataType` |
| Mac name | Once, then remembered. | `system_profiler SPHardwareDataType` |

## 2. Fan control

Writing fan keys needs root. **Install Helper** asks for an administrator password once. It then:

1. Copies Vitals' own binary to `/Library/PrivilegedHelperTools/com.yahyakhamaisi.vitals.fanhelper`, owned by root.
2. Loads a launch daemon that runs that copy with `--fan-daemon`.

The daemon listens on `/var/run/com.yahyakhamaisi.vitals.fanhelper.sock` and accepts only `ping`, `manual <fan> <rpm>` (clamped to the fan's range), `auto <fan>` and `restore`. Manual sets `Ftst` = 1, the mode key = 1 and `F%dTg`. Auto sets the mode back to 0. Vitals hands every fan back to automatic when you choose Auto or quit. When the daemon is stopped, it hands every fan back to automatic too.

## 3. Menu bar

- One `MenuBarExtra` for the combined item, plus one per module, each shown or hidden with `isInserted`.
- Images are drawn with AppKit at 22pt high, with text in the menu bar's label color. Monochrome widgets are template images.
- By-value colors: green under 60%, orange to 85%, red above.

## 4. Automation

| Way in | Detail |
|---|---|
| CLI | `/usr/local/bin/vitals` runs `Vitals cli …`, which posts to the running app over `DistributedNotificationCenter` and prints the reply. |
| URL | `vitals://open?page=<name>` |
| Shortcuts | Get System Value (text or JSON), Open Vitals Page. |
| Global shortcut | ⌃⌥V opens the panel (Carbon hot key, no permission). |

## 5. Known limits

- CPU energy reads zero on M5 in IOReport, so CPU power is hidden there.
- NVMe SMART detail (wear, data written, power-on hours) isn't exposed to apps on this Mac's internal SSD, so Vitals shows `diskutil`'s SMART status only.
- Wi‑Fi network names need Location access on recent macOS. Vitals doesn't ask for it.
- Manual fan control is untested on Intel Macs.
