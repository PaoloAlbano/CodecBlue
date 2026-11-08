# Confronto con Blue Bloom (jonathanlu98/bluebloom, MIT) — 2026-11-05

Fonte: solo README e release notes v0.1.0 (NON il codice: clean room).

## Architettura (differenza principale)
- Blue Bloom NON prende il controller: "talks to the macOS Bluetooth daemon directly and opens the A2DP channels"
  via interfacce private → tastiere/mouse restano a macOS. Tiene anche HFP e AVRCP (mic non usabile da altre app).
- Dispositivo audio virtuale (driver HAL installato con password admin) invece del process tap.
- Noi: presa del controller (Skywalk) → serve HID bridge; process tap globale + mute.

## Gap funzionali
codec aptX/aptX HD/AAC 320/SBC XQ; sample rate segue Apple Music; batteria cuffie; modalità automatica
(prende solo cuffie con codec migliore, si attiva quando le cuffie si collegano da sole); ripristino output/pausa
all'uscita; finestra impostazioni; 8 lingue; uninstaller in-app; export diagnostica; CLI probe/codectest;
DMG; supporto Intel.

## Nostri vantaggi
hand-off chiamate (loro bloccano il mic); riconnessione automatica (loro "doesn't connect or retry on its own");
latenza misurata 50–100 ms; watchdog/ripristino; AGENTS.md; HID bridge.

## Analisi del codice (v1.0.0, commit b891f9c) — 2026-11-05
Motore ObjC ~6.1k righe (A2DPSource 2156 monolitico), UI SwiftUI ~4.5k, driver C 1142 (da NullAudio), Bazel+Xcode 26, niente CI.
Verificato io: handleEvent ignora XPC_TYPE_ERROR (ClassicXPC.m:212); 'aptd' letto senza controllo PID (BlueBloomDevice.c:960);
AAC senza kAudioCodecPropertySoundQualityForVBR (AACEncoder.m:138).
Debolezze principali: niente gestione errori/timeout XPC, XPC sync sul main thread, protocollo pinnato a 26A428 senza probe,
SUSPEND dalla cuffia non ripreso, framing AVDTP euristico su SOCK_STREAM, nessun drift compensation (drop 125 ms / silenzio),
latenza fissa 250 ms dichiarata, audio leggibile da qualsiasi processo, sample rate solo Apple Music via log scraping,
HeadsetAudioGuard contrario al nostro hand-off, nessun test state machine, nessuna CI, firma ad-hoc.
Da riusare (idee/costanti): sequenza XPC check-in 1/10/12, takeover in-place nella finestra 2 s, grab AVRCP prima del media,
costanti di timing, heartbeat driver, install verificato con codesign -R, guard ABR LDAC, LATM writer, test round-trip.
Hand-off chiamate: riprendere = takeOverInPlace (~2.5–3.5 s); rilascio richiede drop link + re-page (profile round una volta per link);
variante da provare: rilasciare solo HFP RFCOMM.
