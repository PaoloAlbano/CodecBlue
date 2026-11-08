# Findings: Bluetooth su macOS 27.2 (Apple Silicon)

Fase 0, raccolta in sola lettura con `tools/probes/bt-probe.sh`, `ioreg` e `launchctl`, senza root.
Data: 2026-11-05.

## Macchina
- macOS 27.2 (26B123), arm64, **SIP attivo**
- Controller: **BCM_4388C2**, firmware 24.2.241.1921, transport **PCIe**, Vendor ID 0x004C (Apple)
- Cuffie: HUAWEI FreeBuds 5 (connesse via macOS), FreeBuds 3 (associate)

## Topologia IORegistry
```
AppleARMIODevice "bluetooth"
└─ AppleBluetoothModule                     (UserClient: AppleBluetoothModuleUserClient)
   ├─ BTDebug                               (CoreCapture "StateDump")
   └─ AppleConvergedIPCOLYBTControl         (UserClient: AppleConvergedIPCControlUserClient)
      └─ AppleConvergedIPCRTIDevice
         ├─ RTIInterface unit=0 "hci"   skywalk → IOSkywalkKernelPipeBSDClient (nexus UUID)
         ├─ RTIInterface unit=1 "sco"   skywalk → …
         ├─ RTIInterface unit=2 "acl"   skywalk → …
         ├─ RTIInterface unit=3 "debug" userclient (AppleConvergedIPCUserClient)
         ├─ RTIInterface unit=4 "tsi"   skywalk → …   (time sync)
         └─ RTIInterface unit=5 "iso"   skywalk → …   (LE Audio isochronous)

IOResources
└─ IOBluetoothHCIController (IOBluetoothFamily, "Built-In")
   └─ IOBluetoothHCIUserClient  creator = bluetoothd
```

**Cosa ne ricaviamo:**
- HCI command/event e dati ACL viaggiano su **due kernel pipe Skywalk separate** (unit 0 e 2). È
  coerente con Lucid, che apre "hci channel" e "acl channel".
- Il nexus si trova cercando `AppleConvergedIPCRTIInterface` con `ACIPCInterfaceProtocol` = `hci`
  o `acl` e leggendo `IOSkywalkNexusUUID` dal figlio. **Gli UUID possono cambiare a ogni boot**:
  vanno sempre risolti a runtime, mai cablati nel codice.
- `IOBluetoothHCIController` e il suo user client sono lo strato "legacy" usato da bluetoothd e
  IOBluetooth.framework. Lo streaming vero passa da Skywalk.

## API Skywalk `os_channel_*`
- **Non sono nell'SDK pubblico** (MacOSX27.2.sdk non le ha). Sono esportate da libsystem
  (`libsystem_kernel`).
- Il riferimento è il sorgente XNU open source (`bsd/skywalk/`, `libsyscall/wrappers/skywalk/`,
  licenza APSL). Scriveremo **dichiarazioni nostre** minime (prototipi e struct opache) per
  l'interoperabilità, senza copiare file APSL nel repo MIT.

## launchd / bluetoothd
- `system/com.apple.bluetoothd`, plist `/System/Library/LaunchDaemons/com.apple.bluetoothd.plist`
- `minimum runtime = 10`: se il processo muore prima di 10 s dall'avvio, launchd **ritarda** il
  relaunch. Il guard deve tenerne conto (timing della "safe window").
- `exit timeout = 5`: dopo SIGTERM, launchd manda SIGKILL dopo 5 s.
- Va verificato se launchd rilancia subito dopo SIGTERM (KeepAlive o richiesta on-demand via
  MachServices). Sembra di sì, visto il comportamento di Lucid, ma va misurato in fase 3.

## Pairing / link key
- `/Library/Preferences/com.apple.Bluetooth.plist` **non esiste più** su macOS 27.
- Lo store è probabilmente in `/private/var/root/Library/Preferences/com.apple.bluetoothd.plist`
  (leggibile solo da root, non verificato) e/o nel keychain di sistema. Da approfondire in fase 4.
  Per ora la strada è un **pairing nostro**, come fa Lucid.

## Strumenti
- Xcode completo **non installato** (solo Command Line Tools, Swift 6.4.2, clang, cmake). Per
  l'app SwiftUI e la firma serve Xcode.
- PacketLogger (Additional Tools for Xcode) **non installato**. Serve per le capture HCI di
  riferimento.
- Rust non installato.

## TODO fase 0 rimanenti
- [ ] Installare Xcode e Additional Tools (PacketLogger), poi fare una capture di riferimento
      A2DP AAC con le FreeBuds 5.
- [ ] Con root: `lsof -p $(pgrep bluetoothd)` per vedere i file descriptor dei canali Skywalk
      aperti da bluetoothd (conferma del modello a due canali).
- [ ] FreeBuds 5: attivare LDAC/HD in AI Life.
