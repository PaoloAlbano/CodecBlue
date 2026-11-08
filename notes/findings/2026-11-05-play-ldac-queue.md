# LDAC verso le FreeBuds 5: cosa funziona, cosa no, e perché

Sessione del 2026-11-05, Mac dell'utente, HUAWEI FreeBuds 5 (`40:DC:A5:XX:XX:XX`, firmware
0.12.10, BT 5.2, servizi HFP AVRCP A2DP SerialPort).

L'indirizzo Bluetooth delle cuffie è oscurato: è un identificatore del dispositivo di chi ha
misurato, non un dato che serva a capire qualcosa, e le ultime tre ottetti non cambiano nessuna
delle conclusioni qui sotto.

Questo file è la memoria di quella sessione: le misure, le ipotesi **escluse con la misura che
le esclude**, i bug corretti e — in fondo — quello che **non** è ancora dimostrato. Le sezioni
sono in ordine di lettura, non cronologico; la cronologia è in fondo.

---

## 1. Sommario

- Tutto il setup funziona: presa in place, AVRCP, HFP con SLC e batteria, LDAC configurato,
  canale media, START, restituzione a macOS. Il flusso parte e si sente.
- **Il nostro canale media prende 50–80 kbps e rifiuta il resto.** Misurato in otto modi
  diversi, sempre lo stesso numero.
- **La causa è lo sniff mode.** Durante il nostro stream il link **non esce mai** da sniff
  (zero `ModeChange` in 30 s), con intervallo 240–246 ms. macOS, quando suona lui, esce da sniff
  (`Sniff/Active mode change: 2->0`) perché è **`Server.Audio` di bluetoothd** a farlo, e solo
  per il proprio stream. Il nostro report lo conferma: RTT AVRCP 130 → 500 → 544 ms mentre
  streamiamo. In un intervallo di sniff passano pochi pacchetti, qualunque cosa offriamo.
- Non dipende da: dimensione del pacchetto, ritmo di invio, priorità L2CAP, MTU, socket buffer,
  encoder, header LDAC, HFP/AVRCP tenuti. Ogni voce ha una misura che la esclude (§5).
- Offrendo **esattamente** ciò che offre macOS (680 B ogni 23,22 ms = 234 kbps) il nostro canale
  ne prende 8–13 al secondo e ne rifiuta 30–34: è il link che dorme, non la banda che manca.
- Il relay PipeMgr legge 16–17 volte/s, più dei pacchetti che escono: **legge e poi non manda**.
  È il testimone del problema, non la causa (§4.6).
- **La cuffia e l'aria non sono il problema**: il prototipo Python, prendendo il controller, ha
  fatto **1.016 kbps lordi sulle stesse FreeBuds 5** (§9).
- Blue Bloom non fa nulla sul link che noi non facciamo (zero occorrenze di `sniff`,
  `ExitSniffMode`, priorità ACL): **ha lo stesso limite** e lo aggira con il bitrate adattivo
  (§6). Il suo 990 kbps è nominale.
- Quindi la domanda vera non è più "quale architettura" ma **"come si tiene il link fuori da
  sniff restando dentro bluetoothd"** (§7, §10).
- Le due strade XPC note sono bloccate: `general.xpc` richiede un entitlement Apple, il numero di
  `SetACLHighPriority` non è deducibile. Ma è **quella** la cosa da sbloccare, non
  l'architettura.
- **RISOLTO il 2026-11-06.** La causa non era lo sniff ma la **A2DP Link Quality Mode**
  (`_BCM_WriteLinkQualityMode`). Accesa via `BTAudioMsgIdStartAudio` sul canale audio di
  bluetoothd: **445 kbps** in flood (era 50), e **MQ a 336 kbps con zero scarto**. Dettagli in
  §13. Le sezioni 4–7 restano valide come misure; la conclusione "è lo sniff" è **superata**.
- **Terza porta, trovata il 2026-11-06: `com.apple.BTAudioHALPlugin.xpc`, senza entitlement.**
  È il canale da cui `Server.Audio` riceve "audio started" — il segnale che fa uscire il link da
  sniff. I messaggi arrivano, e l'enum è stato letto dal log (1 PublishEndpoint … 21
  TransitionBiToUniDirection, 13 Register, 5 StartAudio). Ma il canale **crasha bluetoothd**
  (`CFRelease(NULL)`) con ogni messaggio senza `kBTAudioMsgArgs`, e pubblicare un device finto
  non è ancora riuscito (§7.3).

---

## 2. Cosa funziona (e va tenuto)

- **Presa in place**: macOS molla 534–727 ms dopo il disconnect forzato, canale preso alla 1ª
  richiesta, signaling con MTU 895. Nessun page, nessun SDP.
- **AVRCP tenuto** (`AVCTPHolder`), **HFP tenuto** con SLC e batteria (`HandsFreeHolder`).
- **SET_CONFIGURATION LDAC** su SEID 34 (0x22) con delay reporting; le cuffie dichiarano
  240 ms di DelayReport, bluetoothd calcola `A2DP Latency = 263 ms`.
- **Canale media** aperto su PSM 0x19, `inMTU:1024 outMTU:895`, `SOCK_STREAM`,
  `initialCredits:65535`, `priority:0`.
- **START accettato**, audio udibile, `interrupted` → CLOSE/ABORT → restituzione a macOS.
- **Riconnessione**: `codecblue release` chiede a macOS di riconnettere e in ~2 s le cuffie
  tornano disponibili (`link: up, macOS audio device: yes`).

---

## 3. Il sintomo, letto bene

Prima esecuzione (`play`, LDAC HQ, tono di 20 s):

```
[  6.101] streaming: 86 kbps, 15 packets/s, queue 351 (max 351), HQ 990 kbps
[ 24.112] streaming: 54 kbps,  9 packets/s, queue 3516 (max 3516), HQ 990 kbps
```

- `86 → 54 kbps` era **byte inviati / tempo dall'inizio**, non per intervallo: il numero scendeva
  perché cresceva il denominatore. Il throughput reale per finestra era ~10 pacchetti/s ×
  ~600 byte ≈ **50 kbps**.
- La coda cresceva di ~180 pacchetti ogni 2 s: il socket accettava ~10 pacchetti/s mentre
  l'encoder ne produceva ~190/s.
- Il report aveva due bug (kbps cumulativi, `packets/s` con `Int/Double`): vedi §8.

---

## 4. Le misure

### 4.1 Flood a dimensione fissa (`codecblue flood`, nessun encoder, nessun audio)

Pacchetti identici, il più veloce possibile, per 5 s ciascuno.

| pacchetto | pacchetti/s | kbps |
|---|---|---|
| 64 B | 128 | 65 |
| 100 B | 96 | 77 |
| 150 B | 51 | 61 |
| 200 B | 45 | 73 |
| 300 B | 23 | 55 |
| 400 B | 12 | 38 |
| 679 B | 9 | 50 |
| 895 B | 9 | 51 |

**Il tetto è in byte, non in pacchetti**: 50–77 kbps qualunque sia la dimensione. 7.600 rifiuti
in 5 s: il socket è pieno il 99% del tempo.

### 4.2 Ritmo controllato (`codecblue pace`): la stessa offerta di macOS

680 byte a 43 pacchetti/s = 234 kbps, a ritmo regolare:

```
pace: 679-byte packets at 43/s (234 kbps offered) for 6 s
pace: offered 43/s, took 9/s, refused 34/s = 48 kbps
pace: offered 43/s, took 8/s, refused 34/s = 46 kbps
pace: offered 43/s, took 13/s, refused 30/s = 72 kbps
```

**Rifiuta il 70–80% di ciò che macOS consegna sullo stesso link.** Non è il ritmo, non è la
dimensione, non è l'encoder (qui non c'è).

### 4.3 Latenza del link a riposo (`codecblue link`)

- AVDTP RTT **mediano 135 ms** (min 102, max 170), AVRCP 114 ms.
- Durante lo streaming l'AVRCP RTT oscilla fra 60 e 1036 ms.
- Il link è in **sniff** a riposo: `ModeChange newMode 2 (sniff), interval 394` (394 × 0,625 ms
  = **246 ms** di sniff interval).

### 4.4 Il link durante lo streaming: **resta in sniff** (la causa del tetto)

Questo è il punto che ho sbagliato due volte, quindi va scritto con la prova accanto.

**macOS che suona in AAC** (21:51:13–21:51:44, `afplay` del nostro tono):

```
21:51:13.113  HCI event: ModeChange, handle 23, newMode 2 (sniff), interval 384
21:51:13.552  HCI event: ModeChange, handle 23, newMode 0 (active), interval 0
              [Server.Audio] Sniff/Active mode change: 2->0
21:51:44.750  HCI event: ModeChange, handle 23, newMode 2 (sniff), interval 384   ← quando smette
```

**Durante il nostro stream** (20:40:55–20:41:25, 30 s): **zero `ModeChange`.**

E il nostro stesso report, mentre streamiamo, misura l'RTT AVRCP: **130 ms → 500 ms → 544 ms**.
Quello è un link in sniff (un link active risponde in 5–20 ms). A riposo: AVDTP 135 ms.

**Chi fa il cambio di modo è `Server.Audio` di bluetoothd**, e lo fa solo per il *proprio*
stream A2DP (`Sniff/Active mode change` compare nella finestra di macOS, mai nella nostra).
Quando streammiamo noi, `Server.Audio` non sa niente: il link resta in sniff, con intervallo
384–394 × 0,625 ms = **240–246 ms**.

Questo spiega tutto il resto: in un intervallo di sniff passano pochi pacchetti, **qualunque**
cosa offriamo. `pace` a 43 pkt/s viene rifiutato perché il link dorme fra un pacchetto e
l'altro, non perché manchi banda.

**I due errori che ho fatto, per non ripeterli:**
1. Prima stesura: "il link è in sniff, ~40 kbps di tetto" — giusto, ma senza la prova che
   restasse in sniff *durante* lo stream.
2. Seconda stesura: "esce da sniff e resta active, quindi non è lo sniff" — **sbagliato**. Avevo
   letto un `ModeChange handle 31` e l'ho attribuito alle cuffie (era un altro link), e ho letto
   "nessun ModeChange" come "resta active" quando significa l'opposto: **resta com'era, in
   sniff**. La lezione: un evento assente non è un evento avvenuto, e ogni `ModeChange` va
   legato al suo handle.

### 4.5 macOS in AAC sullo stesso link

Log di bluetoothd:

```
A2DP configured at 44.1 KHz. Codec: AAC-LC, VBR max: 230 kbps.
1 frames * (12+668) bytes = 680 per RTP (max=879) every 23.22 ms
```

680 byte ogni 23,22 ms = **43 pacchetti/s = 234 kbps**. E, nella finestra in cui macOS ha
suonato davvero (`afplay` del nostro stesso tono, 21:51:15–21:51:39):

- `ModeChange ... newMode 0 (active)` all'avvio;
- **0 letture PipeMgr** per il canale media;
- `Received system 'audio started' notification from HAL on a2dpHandle 1`,
  `adjustBitRateForMac- Adjusting Bitrate`, `Successfully opened streaming channel ... on
  stream handle 1`.

Il traffico di macOS va dal sendthread di A2DP al controller, **senza passare dal relay**.

### 4.6 Il relay PipeMgr: quanto legge (e perché non è lui la causa)

- Nostro canale: **103 letture in 6 s** (17/s) mentre uscivano 9 pacchetti/s; in un'altra
  finestra 248 in 15 s (16/s). Il report mostra "at most 9 packet(s) per drain", poi 1.
- Canale di macOS: **0 letture** in 24 s di streaming (il suo traffico va dal sendthread di A2DP
  al controller, senza passare dal relay).

Il relay legge ~16–17 volte al secondo, più dei 9–13 pacchetti/s che escono: **legge e poi non
manda**, perché il link è in sniff e il controller non ha slot. Quindi il relay non è il tetto:
è il testimone. (Nella seconda stesura avevo scritto "15 × 679 × 8 = 81 kbps di tetto teorico":
coincidenza numerica, non causalità.)

### 4.7 Encoder

0,04–0,05 ms per chiamata, **21.000 frame LDAC/s** contro i 375 necessari (48 kHz). Non è mai
stato il collo di bottiglia. libldac compilata in virgola mobile (F32 supportato: `setpcm_ldac.c`,
`ldaclib.c` senza `_32BIT_FIXED_POINT`), `LDACBT_MTU_REQUIRED = 679`, `LDACBT_TX_HEADER_SIZE = 18`.

---

## 5. Ipotesi escluse, e la misura che le esclude

**La causa è lo sniff mode** (§4.4): non è in questa tabella perché non è un'ipotesi esclusa, è
la spiegazione. Le righe sotto sono le altre ipotesi, tutte scartate con una misura.

| Ipotesi | Misura che la esclude |
|---|---|
| Coda non limitata (solo ritardo) | risolto con `PacketQueue` a 150–300 ms; il tetto resta |
| Encoder lento | 21.000 frame/s contro 375; `pace`/`flood` non usano encoder |
| Codec troppo alto (HQ) | MQ (330 kbps) dà gli stessi 40–113 kbps |
| Dimensione del pacchetto | flood 64→895 B: sempre 50–77 kbps |
| MTU del canale | 679 vs 895: identico |
| Ritmo di invio (a raffica) | `pace` a 43/s regolari come macOS: rifiuta il 75% |
| Socket buffer / low water | `SO_SNDBUF`/`SO_SNDLOWAT` da 1 a 16 MTU: nessun effetto |
| Priorità L2CAP | `priority:0` nel log di bluetoothd anche con `--media-priority 3`: la chiave non viene applicata |
| Crediti L2CAP | `initialCredits:65535`, `creditAckDelta:30000`, `maxLatencyinMS:-1`: mai a secco |
| Cuffia / aria insufficienti | prototipo Python con presa del controller: 1.016 kbps sulle stesse cuffie (§9) |
| HFP / AVRCP tenuti | `--no-hfp`, `--no-avrcp`: nessun effetto |
| Tipo di socket | `SOCK_STREAM`, come Blue Bloom |
| Header LDAC / packetizing | identici a Blue Bloom, verificati riga per riga (§6) |
| PipeMgr lento | legge 15–17 volte/s, più dei 9–13 pacchetti/s che escono: legge e poi non manda |

---

## 6. Confronto con Blue Bloom (sorgente pubblico, MIT, release 1.0.0)

Letto `github.com/jonathanlu98/bluebloom`, commit `b891f9c`, e anche la storia (nessun commit
tocca il link).

**Identico a noi:**

- canale XPC `com.apple.server.bluetooth.classic.xpc`, check-in `kCBMsgArgIsPrivilegedDaemon=1`,
  stessi numeri di messaggio (1, 10, 12, 27, 28, 29, 30, 44, 45, 46, 51, 59, 60, 62, 63);
- canale media aperto con `priority:0` (`kCBL2CAPChannelPriority` esiste nella loro API ma non
  la usano);
- packetizing LDAC: RTP 12 byte + header 1 byte (conteggio frame nei 4 bit bassi) + frame LDAC,
  timestamp che avanza di `frames × 128` — identico al nostro `MediaPacket`;
- `SO_SNDBUF` e `SO_SNDLOWAT` a **un MTU**, una scrittura = un SDU;
- MTU del link usato così com'è (895); noi ora 679 di default, ma con 895 misuriamo lo stesso;
- `SOCK_STREAM`.

**Zero occorrenze** in tutto il loro sorgente di `sniff`, `link mode`, `0xFC57`,
`ACLHighPriority`, `general.xpc`, `ExitSniff`, `AccessoryAudioClient`, `stream handle`.

### Quindi: Blue Bloom ha lo stesso limite?

**Quasi certamente sì.** Non l'ho misurato con le tue cuffie, quindi lo dico come deduzione
forte, non come fatto. Gli indizi:

1. Non c'è una sola riga che tocchi il link. Usano lo stesso socket, lo stesso `SO_SNDLOWAT` a
   un MTU, lo stesso pump ogni 2 ms (`DISPATCH_SOURCE_TYPE_TIMER`), la stessa priorità 0. Se il
   nostro tetto è lo sniff (§4.4), il loro è identico.
2. Il loro README lo dice indirettamente: *"At a fixed bitrate, the sound can drop out while
   macOS scans for nearby devices… for about 15 seconds"* — se ci fosse banda da vendere, una
   scansione non farebbe cadere l'audio.
3. `CHANGELOG`: *"when the Bluetooth link gets congested, LDAC, SBC and AAC step down and come
   back up once it clears"*, e il caso #8 *"With LDAC, Adaptive can switch back and forth
   between two bitrates on some headphones"*. È il workaround a un link che non regge.
4. Il loro 990 kbps è **nominale** (il valore chiesto al codec), non un throughput misurato: non
   hanno un log di kbps raggiunti contro kbps richiesti, solo `recentKbps` (quello che esce) e
   l'adattamento.

**La differenza di sostanza resta una sola:** Blue Bloom ha un **dispositivo audio virtuale**.
Le app suonano lì, e il link non deve reggere il bitrate del codec ma solo quello che l'utente
sta suonando; se non lo regge, `BitrateAdapter` scende di livello (990 → 660 → 492 → 396 → 330)
e `MediaStreamer` scarta PCM prima di codificare (`kMaxLagSeconds = 0.3`). **Non chiedono mai al
link più di quanto il link dia.** Noi, con un tono a 990 kbps fissi, chiediamo il massimo a un
link che dorme: è il caso peggiore, e non è quello che l'utente vive con Blue Bloom.

Differenza minore, non la causa: loro usano S24, noi F32 (entrambi supportati dalla libldac
compilata in virgola mobile).

**Cosa manca per chiudere la questione:** il log di Blue Bloom con le FreeBuds 5 (`recent
bitrate` ogni 2 s). Se sta a 50–80 kbps come noi, la deduzione è confermata; se arriva a 330+,
allora c'è qualcosa che fanno e che a noi sfugge, e va cercato nel loro codice, non nel link.

---

## 7. Le due strade XPC per toccare il link: misurate, e chiuse

### 7.1 `general.xpc` (dove vivono `ExitSniffMode`, `EnterSniffMode`, `ChangeConnectionPacketType`, `SetQoSConfig`)

bluetoothd espone due servizi XPC: `classic.xpc` (quello che usiamo) e **`general.xpc`**, che
porta i messaggi "general" (`kCBGeneralMsgId*`, 142 stringhe), cioè i comandi che parlano
direttamente al controller.

Provato con `codecblue generalscan FROM TO`. Risposta di bluetoothd, per ogni messaggio:

```
"codecblue-…-MBF-68047-302" has insufficient entitlements to send MBFramework XPC messages
```

**Chiusa**: riservato a componenti Apple firmati.

### 7.2 `classic.xpc` + `kCBMsgIdDeviceSetACLHighPriorityMsg`

Esiste: `BTDeviceMsgHandler::handleBTDeviceSetACLHighPriorityMsg`, argomento `aclPriority`
(`aclPriority: device %@, priority %s`). È il vendor command Broadcom 0xFC57 che Lucid manda
da sé, esposto da bluetoothd. **Manca il numero del messaggio**: i `kCBMsgId*` sono simboli,
non stringhe numeriche, e il binario è spogliato (9 simboli esportati, nessuno utile).

Provato a dedurlo con `codecblue xpcscan FROM TO` (manda i messaggi con un UUID che non
corrisponde a nessun dispositivo; bluetoothd risponde `Classic Unknown CB MsgID n` per i numeri
che non conosce e con il **nome** per quelli che conosce). **La mappatura non è densa**: 40–48
noti, 49–52 ignoti, 53–61 noti, 62–120 ignoti, 121+ ignoti. bluetoothd conosce solo i messaggi
che IOBluetooth usa davvero, quindi il numero non si ricava per posizione.

Servirebbe una cattura di una chiamata reale (hook su `xpc_connection_send_message` in un
processo che la fa, oppure i simboli di IOBluetooth). Il codice è già pronto e disattivato:
`XPCProtocol.setACLHighPriority` (opzionale, `nil`), `ClassicXPC.setACLHighPriority`,
`HeadsetTakeover.requestHighPriority`; `--low-latency` lo usa e dice onestamente quando non può.

### 7.3 `com.apple.BTAudioHALPlugin.xpc` (il canale audio): aperto, e una trappola

Sessione del 2026-11-06. È la terza porta, e l'unica **senza entitlement**: il canale da cui
`Server.Audio` riceve "audio started" — cioè esattamente il segnale che fa fare a bluetoothd il
`Sniff/Active mode change: 2->0` per il proprio stream A2DP.

**Raggiungibile.** `codecblue audiocan ADDR` apre il servizio e i messaggi arrivano:

```
AudioDeviceManager received new xpc connection from 0x79d9dfd400
No device found for uid 40:DC:A5:XX:XX:XX to handle incoming msgId: BTAudioMsgIdPublish
```

Nessun `insufficient entitlements`. Il nome del messaggio lo scrive bluetoothd, quindi l'enum
si legge dal log.

**L'enum, letto un numero alla volta** (un messaggio ogni 150 ms, nome letto dal log,
abbinato per timestamp ±140 ms). I numeri sono densi da 1:

| n | messaggio | n | messaggio |
|---|---|---|---|
| 1 | PublishEndpoint | 12 | ScoRouteReason |
| 2 | Publish | 13 | Register |
| 3 | PropertyChanged | 14 | DeliverySpeedChangeTimerFired |
| 4 | Close | 15 | UllaChangeMode |
| 5 | StartAudio | 16 | UllaModeChanged |
| 6 | AudioAvailable | 17 | UllaModeChangeLongTimeout |
| 7 | StopAudio | 18 | UllaClearSession |
| 8 | TransportReady | 19 | VolumeChanged |
| 9 | SelectCodec | 20 | TransitionUniToBiDirection |
| 10 | AudioContentType | 21 | TransitionBiToUniDirection |
| 11 | SelectScoDataSource | 37 | SelectInputDataSource |
|  |  | 38–39 | AMPAudioFeedback, AMPSkipDuration |

22–36 e 40 non producono log: o non sono gestiti, o cadono prima di loggare.

**La trappola: questo canale uccide bluetoothd.** Ogni prova ha prodotto un crash report
`/Library/Logs/DiagnosticReports/bluetoothd-2026-11-06-10{4623,4649,4704,4808}.ips`, tutti
identici:

```
EXC_BREAKPOINT (SIGTRAP) — CoreFoundation CFRelease.cold.2 <- CFRelease <- bluetoothd+4236148
<- bluetoothd+4237168 <- bluetoothd+4235948 <- _xpc_connection_call_event_handler
```

Cioè: `AudioDeviceManager` prende il valore di `kBTAudioMsgArgs` (o il dizionario di proprietà)
e lo rilascia **senza controllare che esista**. Un messaggio con `kBTAudioMsgId` e
`kBTAudioMsgDeviceUid` ma **senza `kBTAudioMsgArgs`** fa `CFRelease(NULL)` e porta giù il
demone. Il Bluetooth torna su da solo in 1–2 s (la cuffia si riconnette), ma è un crash per
ogni messaggio malformato.

Il comando resta nel repo **disattivato**: rifiuta di partire senza
`CODECBLUE_AUDIO_CHANNEL=yes`.

**Cosa manca per usarlo davvero.** Non il numero (li abbiamo), ma la forma del messaggio:
`Publish` deve portare `kBTAudioMsgArgs` con un dizionario di proprietà (`kBTAudioMsgArgDeviceType`,
`kBTAudioMsgArgDeviceProperties`, `kBTAudioMsgPropertyDeviceUID/DeviceAddress`), e il device
va creato da `AudioDeviceManager` *prima* che i messaggi per-device siano gestiti — altrimenti
resta `No device found for uid`. Provato con un dizionario annidato: `Unhandled message:
BTAudioMsgIdPublish`, cioè il device non nasce e il messaggio cade nel ramo generico.

**Verdetto onesto**: la porta è aperta e l'enum è noto, ma **non è ancora dimostrato** che si
possa pubblicare un device audio finto da un processo non Apple. Il crash dice che il codice
si fida dei campi opzionali: è un bug loro, non una barriera. La strada resta viva e non
richiede root — ma richiede di indovinare la struttura esatta di `Publish`, e ogni tentativo
sbagliato costa un riavvio di bluetoothd.

**Dato utile raccolto per strada**, dal log di macOS mentre suona lui:

```
A2DP LinkQualityReport: Handle = 22 ReTx = 6.8% (5/73), NAK = 0, NoSync = 5,
  TxPwr = 8 dBm, RSSI = -54, 2EDR pkts = 70, 3EDRTx pkts = 0, rate = 230 kbps, Flow off = 0
```

230 kbps reali, 6,8% di ritrasmissioni, RSSI −54 dBm, **zero pacchetti 3-DH5**: l'aria regge
e avanza. Conferma indipendente che il tetto è il percorso bluetoothd, non il link radio.

---

## 8. Bug trovati e corretti (tutti con test di regressione dove ha senso)

1. **`break` dentro lo `switch` del ciclo di invio**: con il socket pieno il ciclo girava a
   vuoto invece di uscire (`break sending`). Prima di questo fix le pause del socket non
   comparivano mai nel report — è il bug che mi aveva fatto dubitare delle misure.
2. **`packets/s`** divideva un `Int` per un `Double`: valori assurdi, anche negativi.
3. **kbps cumulativi** invece che per finestra.
4. **Pause del socket** contate per tutta la sessione invece che per finestra.
5. **`play` non usciva** dopo la restituzione (il signal source teneva vivo il processo).
6. **`--media-mtu` < 679 faceva segfaultare** il processo: libldac ha
   `LDACBT_MTU_REQUIRED = 679` e sotto quella soglia scrive oltre il proprio buffer. Ora il
   valore è bloccato al minimo (`LDACEncoder.minimumMTU`), con test.
7. **Scrittura WAV**: la conversione negativa andava in crash (`Negative value is not
   representable`); ora costruisce l'`Int16` e lo reinterpreta.
8. **Ordine del ciclo**: ora **invia prima di codificare** (un pacchetto fermo in coda mentre
   il socket è scrivibile è banda persa).

---

## 9. Quello che NON è ancora dimostrato

### Cosa invece è già dimostrato (e chiude il dubbio "è la cuffia?")

Il **prototipo Python** del 2026-11-05 14:27 (presa del controller via Skywalk, vedi
`notes/archive/PLAN-v3-python-takeover.md`) ha mandato LDAC HQ 48 kHz alle **stesse FreeBuds 5**:

> 5.627 pacchetti media da ~677 B in 30 s ≈ **1.016 kbps lordi**, tutti confermati
> (`NUMBER_OF_COMPLETED_PACKETS`), nessun errore.

E il 2026-11-05 17:04 lo stesso prototipo ha funzionato in uso reale (servizio installato, audio
di sistema, LDAC HQ, "l'utente sente la musica"), con la priorità ACL Broadcom 0xFC57 accettata.

Quindi: **la cuffia e l'aria reggono 1 Mbps.** Il tetto di 50–80 kbps è il percorso di
bluetoothd, non l'hardware. Questo toglie di mezzo l'ipotesi più costosa (buttare via
l'architettura per niente).

### Cosa manca ancora

- **Non ho verificato che macOS sostenga davvero 234 kbps su questo link.** Ho visto la
  *configurazione* (`680 byte every 23.22 ms`) e il percorso (fuori dal relay), non il rate
  ottenuto. Serve a misurare *quanto* è grande il divario, non se esiste.
- **Non ho verificato che Blue Bloom arrivi a 330+ kbps con queste cuffie** (§6). Con il dato
  del prototipo sopra, la domanda non è più "è la cuffia?" ma "il link resta in sniff anche per
  lui?" — e la risposta più probabile è **sì**, perché non tocca il link.

### La conclusione che ne segue

Il tetto di ~50–80 kbps **non è l'architettura "canali in affitto"**: è lo **sniff mode**, che
`Server.Audio` di bluetoothd disattiva solo per il proprio stream. Il prototipo che prende il
controller fa 1 Mbps perché lì il link lo governiamo noi (priorità ACL, mode, packet type).

Quindi la differenza fra i due approcci non è "quanta banda c'è" ma **"chi tiene sveglio il
link"**. Se si trova un modo di tenerlo sveglio restando dentro bluetoothd, la strada condivisa
torna viva; altrimenti serve la presa del controller, non per la banda ma per il controllo del
mode.

---

## 10. Prossimi passi

La domanda "è la cuffia?" è chiusa (§9): regge 1 Mbps. La domanda vera è **"come si tiene il link
fuori da sniff"**, e c'è una strada che vale la pena battere prima di cambiare architettura.

### Strada 1 (da provare per prima) — svegliare il link restando dentro bluetoothd

Il link resta in sniff perché `Server.Audio` di bluetoothd non sa che stiamo streammando. Se
riusciamo a farglielo fare, la strada condivisa torna viva e non serve root.

Cosa provare, in ordine di costo:

1. **Trovare il numero di `kCBMsgIdDeviceSetACLHighPriorityMsg`.** È il vendor command Broadcom
   0xFC57 (quello che Lucid manda e che tiene il link attivo), esposto da bluetoothd. Il codice è
   già pronto e disattivato (`XPCProtocol.setACLHighPriority`, `--low-latency`). Il numero non si
   deduce (§7.2): serve una cattura di una chiamata reale — hook su
   `xpc_connection_send_message` in un processo che la fa, oppure i simboli di IOBluetooth.
2. **Cercare un messaggio che dica a bluetoothd "questo dispositivo sta streammando"**, così che
   sia `Server.Audio` a fare il cambio di modo. Nel log la funzione si chiama
   `Sniff/Active mode change`; le stringhe `A2DPStreaming`, `isStreamingOutput`, `setLinkMode`
   esistono in bluetoothd. Da cercare fra i 233 `kCBMsgId*` con `xpcscan` esteso e con una
   cattura di quello che fa macOS quando parte l'audio.
3. **Misurare quanto macOS sostiene davvero** (cattura HCI o `afplay` + log): serve a sapere se
   il divario è 234 vs 50 o 234 vs 200. Non cambia la diagnosi, ma dimensiona il problema.

Se una di queste funziona, il tetto sparisce **senza root e senza perdere HID**.

### Strada 2 (se la 1 fallisce) — prendere il controller (Skywalk)

È quello che faceva il prototipo Python: 1 Mbps misurati sulle stesse cuffie, uso reale
funzionante il 2026-11-05 17:04. Lì il link lo governiamo noi: priorità ACL, mode, packet type.

Costi noti e misurati allora:

- **HID bridge**: tastiera e mouse BT si perdono quando il controller passa di mano. Il
  prototipo girava con la tastiera via cavo; l'HID host con un secondo canale era in roadmap e
  **non è mai stato fatto**.
- **Watchdog**: se il daemon muore, il Mac resta senza Bluetooth. Serve un processo figlio che
  faccia sempre `SIGCONT` o `launchctl kickstart -k system/com.apple.bluetoothd`.
- **Fragilità fra release**: Skywalk, launchd e bluetoothd possono cambiare; le chiavi di bonding
  stanno nel System keychain con prompt admin.
- **Va contro il piano v4** (§2: "modalità condivisa, niente presa del controller, niente root") e
  contro la promessa del README ("no root daemon, no SIP changes").

### Cosa NON è un'opzione

Accettare il tetto: significherebbe nessun codec A2DP utilizzabile (LDAC parte da 330, SBC XQ
~500, AAC 128–200). Su questo hardware il progetto non avrebbe senso.

### La domanda da decidere

Non è più "A o B" in astratto: è **"quanto vale la pena provare la strada 1 prima di passare
alla 2?"**. La strada 1 costa poche ore e, se riesce, tiene in piedi tutto il resto (niente root,
niente HID, README vero). La strada 2 è certa ma costosa e cambia il prodotto.

---

## 11. Strumenti lasciati nel repo (diagnostica, non prodotto)

| comando | cosa fa |
|---|---|
| `codecblue play ADDR [FILE.wav] [--quality HQ\|SQ\|MQ] [--queue-ms N]` | stream reale con report onesto |
| `codecblue link ADDR` | RTT del link a riposo (sniff o active) + tetto teorico |
| `codecblue flood ADDR [SEC] [BYTES]` | pacchetti/s massimi al variare della dimensione |
| `codecblue pace ADDR [SEC] [BYTES] [PKT/S]` | offerta a ritmo controllato: quanto prende |
| `codecblue tone FILE.wav [SEC]` | scrive il tono di prova come WAV (per `afplay`) |
| `codecblue xpcscan FROM TO` | mappa numero → nome dei messaggi di `classic.xpc` |
| `codecblue generalscan FROM TO` | prova `general.xpc` (oggi: entitlement negato) |
| `codecblue lookup ADDR` / `release ADDR` | stato del link / restituzione a macOS |

Opzioni diagnostiche di `play`: `--media-mtu N|0`, `--sndbuf-packets N`, `--media-priority N`,
`--no-hfp`, `--no-avrcp`, `--low-latency`.

### Comandi di log che sono serviti

```sh
# mode del link (sniff/active) e cambio di stato
log show --last 10m --predicate 'process == "bluetoothd"' | grep -E "ModeChange|Sniff/Active"

# quanto legge il relay dal nostro socket
log show --start "..." --end "..." --predicate 'process == "bluetoothd"' \
  | grep -c "MAX buffer size for the L2CAP"

# configurazione e latenza A2DP (macOS e nostra)
log show --last 1h --predicate 'process == "bluetoothd"' \
  | grep -E "A2DP configured|A2DP Latency|adjustBitRateForMac"

# parametri del canale L2CAP (MTU, crediti, priorità)
log show --last 10m --predicate 'process == "bluetoothd"' \
  | grep -E "trying to connect to device|Registering L2CAP pipe|Endpoint created"

# mappatura dei messaggi XPC
log show --last 1m --predicate 'process == "bluetoothd"' \
  | grep -E 'Received XPC message|Unknown CB MsgID'
```

---

## 13. RISOLTO (2026-11-06): non era lo sniff, era la Link Quality Mode

**Il tetto è caduto: 445 kbps contro 50, senza root, senza daemon, senza HID.**

### 13.1 La misura che ribalta la diagnosi

Quattro prove A/B, stesso codice, stessa cuffia, stesso canale, `flood` da 679 B:

| ora | modo del link | Link Quality Mode | risultato |
|---|---|---|---|
| 11:14:36 | `newMode 0 (active)` | **OFF** | **55 kbps** (10 pkt/s) |
| 11:16:20 | active | **ON** | **436 kbps** (80 pkt/s) |
| 11:18:03 | active | **OFF** | **59 kbps** (11 pkt/s) |
| 11:20:11 | active | **ON** | **435 kbps** (80 pkt/s) |

Il link era **già fuori da sniff** in tutte e quattro: `ModeChange ... newMode 0 (active)` alle
11:14:36.697, e nessun altro `ModeChange` fino a fine prova. Quindi **lo sniff non è la causa**:
uscirne non basta. La variabile che discrimina è `Enabling A2DP Link Quality Mode`.

### 13.2 Cos'è

`Enabling A2DP Link Quality Mode` / `Disabling Link Quality Mode` sono la traccia di
`Server.Audio` che chiama il vendor command Broadcom:

```
OI_STATUS _BCM_WriteLinkQualityMode(handle, bool, u16, u16, u16, u16, cb)
OI_STATUS _ACI_WriteLinkQualityMode(...)
OI_STATUS _SRS_WriteEnhancedLinkQualityMode(...)
```

È della stessa famiglia del **0xFC57** che manda Lucid, quello che nel prototipo Python era
"accettato" e faceva 1.016 kbps. Non cambia il packet type — `3EDRTx pkts = 0` in entrambi i
casi, sempre 2-DH5 da 679 B — cambia **quanti pacchetti al secondo** il controller concede:
9 → 86.

### 13.3 Come accenderla (la strada, funzionante)

`com.apple.BTAudioHALPlugin.xpc`, il canale audio di bluetoothd (§7.3), **non ha entitlement**.
Il messaggio `BTAudioMsgIdStartAudio` (= **5**) produce la notifica che `Server.Audio` aspetta:

```
Received system 'audio started' notification from HAL on a2dpHandle 1
  → ConnectMediaStream → Starting A2DP audio streaming → Enabling A2DP Link Quality Mode
```

Tre condizioni, tutte necessarie, tutte scoperte sbagliando:

1. **`kBTAudioMsgArgs` sempre presente.** Senza, bluetoothd fa `CFRelease(NULL)` in
   `_xpc_connection_call_event_handler` e **muore** (crash report 11:36:55, il quinto della
   giornata).
2. **L'UUID giusto**: `kBTAudioMsgDeviceUUID` deve essere il `CBDevice` UUID di bluetoothd
   (`4379D275-…`, quello stampato nei suoi log), **non** l'UUID di IOBluetooth e **non** l'UID
   CoreAudio. Con quello sbagliato: `No device found for uid …` e nessun effetto.
3. **L'ordine**: il keeper va avviato **prima** del takeover. Appena prendiamo il canale media,
   bluetoothd fa `Unpublishing audio device 40:DC:A5:XX:XX:XX-tacl` e da quel momento ogni
   messaggio per quel device risponde `No device found`. Prima del takeover il device c'è.

### 13.4 Il risultato, con i numeri

```
flood 679 B, 12 s, nessun afplay attivo:
  984 pacchetti = 82 pkt/s = 445 kbps     (prima: 9 pkt/s = 50 kbps)

play LDAC MQ, 30 s:
  336 kbps, 62 pkt/s, link took 100% of real time,
  queue 0–16 ms, dropped 0%, AVRCP round trip 13–57 ms
```

**MQ è perfetto**: zero scarto, coda vuota, nessun `socket full`. È il primo stream LDAC
continuo e senza perdite di questo progetto.

**HQ resta al 50% di scarto**: 495–503 kbps su 990, coda 149 ms. Il tetto con la LQM accesa è
~500 kbps, non 990: manca un secondo interruttore (probabilmente il packet type 3-DH5, che
bluetoothd non negozia mai — `3EDRTx pkts = 0` anche quando suona lui).

### 13.5 La qualità adattiva, e i tre errori che ha richiesto

`--adapt` fa seguire il livello LDAC al link invece di sceglierlo a priori. Tre correzioni, tutte
nate da un difetto sentito all'ascolto:

1. **Il gracchiare d'apertura.** Partendo da HQ i primi 6 s sono a 990 kbps su un canale da 500:
   47% buttato, e si sente. Ora `--quality` è il **tetto**, non il punto di partenza: chiedere MQ
   significa "MQ è quanto voglio", e l'adattatore parte da lì.
2. **La risalita in un livello che ha appena fallito.** La prima versione tornava in SQ 4 s dopo
   che SQ aveva fallito, e il glitch si sentiva in loop. Ora un livello che fallisce viene
   **bloccato**, con attesa che raddoppia (30 s, 60 s, 120 s…).
3. **La finestra di decisione troppo lunga.** Le prime finestre sono da **0,5 s** invece di 2 s
   (`firstReportInterval`), così la decisione arriva in mezzo secondo. Servono entrambe le cose:
   il tetto evita il glitch, le finestre corte evitano di aspettare 4 s per accorgersene.

Risultato, `--quality MQ --adapt --keep-link-quality`, 40 s:

```
 9.5  playing in LDAC MQ
10.0  355 kbps, queue 0 ms          ← finestre da 0,5 s
11.1  344 kbps, queue 0 ms
13.1  336 kbps, queue 0 ms, dropped 0%
… fino a 29.1: 336 kbps, queue 0–16 ms, dropped 0%, nessuna risalita
```

Nessun gracchiare, nessuno scarto, nessuna oscillazione.

### 13.6 La prova d'ascolto (2026-11-06, la prima che passa)

Finalmente un ascolto, non un numero. Tre tentativi:

1. **Melodia generata** (nota ogni 0,5 s, inviluppo sinusoidale): **gracchia**. Ma il difetto
   era il file — l'inviluppo fa uno scalino a ogni cambio di nota, e lo scalino è un click.
2. **Tono puro a 440 Hz, 40 s**: **pulito**. Con un seno continuo non c'è niente nel segnale che
   possa produrre un click, quindi l'assenza di click è una misura del trasporto.
3. Report della prova pulita: **44 s a 336 kbps, coda 0–16 ms, `dropped` mai comparso**.

Lezione: un file di test con attacchi netti non distingue "il codec gracchia" da "il file
gracchia". Un tono puro sì.

### 13.7 I crash di bluetoothd, e la pulizia

Cinque crash report in un giorno, tutti nostri, tutti dal canale audio:

| ora | causa | tipo |
|---|---|---|
| 10:46:23 | messaggio senza `kBTAudioMsgArgs` | `EXC_BREAKPOINT`, `CFRelease(NULL)` |
| 10:46:49 | idem | idem |
| 10:47:04 | idem | idem |
| 10:48:08 | idem | idem |
| 11:36:55 | `kBTAudioMsgDeviceUUID` reale + dizionario proprietà di forma sbagliata | `EXC_CRASH`, eccezione ObjC dentro `CFBooleanGetValue` |

Il secondo è diverso dal primo e va scritto: **non basta** mettere `kBTAudioMsgArgs` per essere al
sicuro. Con un UUID che il dispositivo conosce, bluetoothd entra nel ramo per-dispositivo e passa
il valore a `CFBooleanGetValue`, che lancia `doesNotRecognizeSelector` se il tipo non è un booleano.
Cioè: il codice **si fida del tipo dei campi** che gli mandiamo.

**Pulizia fatta**: `audioscan` e `audioreg` sono stati **rimossi**. Erano due sonde che mandavano
40 messaggi arbitrari a un demone di sistema, e hanno ucciso bluetoothd ogni volta che sono state
eseguite. Al loro posto un solo comando, `audioprobe`, che manda unicamente il messaggio che
sappiamo funzionare (`BTAudioMsgIdStartAudio`, quello che usa `AudioStreamKeeper` in produzione),
e che rifiuta di partire senza `CODECBLUE_AUDIO_CHANNEL=yes` spiegando perché.

Regola che ne ricavo, e che vale per il resto del progetto: **una sonda che parla con un processo
di sistema non deve poter mandare messaggi arbitrari**. Se serve conoscere un enum, si legge dal
log di una chiamata che funziona, non si forza la mano al demone.

### 13.8 Due bug trovati in questa prova

- **Il ciclo non usciva a fine audio.** Dopo l'ultimo campione il processo restava vivo a girare
  a vuoto (15 minuti in una prova): `position >= total && queue.isEmpty` non scattava mai perché
  il socket non prendeva gli ultimi pacchetti. Ora esce, e se la coda non si svuota entro 2 s
  scarta il resto e lo dice.
- **Nessun controllo di volume.** Il PCM va dal file all'encoder intatto: un seno a piena scala
  è dolorosamente forte. Aggiunto `--gain X` (`WAVFile.scaled`, con clamp a ±1.0).

### 13.9 Il device virtuale, e i cinque difetti che ha rivelato

Il driver HAL (`Driver/CodecBlueDriver/CodecBlueDriver.c`) funziona: macOS scrive nel device
"CodecBlue", il ring condiviso in `/tmp/codecblue-ring` riceve l'audio, `codecblue system` lo
legge e lo manda in LDAC. Cinque difetti, tutti trovati solo perché il device è stato usato
davvero:

1. **Estensione sbagliata.** CoreAudio scansiona solo `*.driver` in
   `/Library/Audio/Plug-Ins/HAL`. Un `.bundle` con dentro tutto giusto viene ignorato **in
   silenzio**: nessun log, nessun errore.
2. **`kAudioPlugInPropertyDeviceList` mancante.** Il plug-in si caricava, il processo partiva, e
   poi `Device activation failed`. L'host non scopre i device con `OwnedObjects`: chiede la
   **lista** al plug-in.
3. **`GetZeroTimeStamp` non valido.** Restituiva un numero di frame arbitrario invece di un
   multiplo esatto del periodo. L'host considerava il clock invalido e **non chiamava mai
   `DoIOOperation`**: device "Running", zero audio.
4. **Permessi dei file di servizio.** Il driver gira come `_coreaudiod`, i file in `/tmp` erano
   dell'utente: `open` falliva e la traccia diagnostica era **silenziosamente assente**. Ho
   letto le righe di un mio test credendole del driver.
5. **Volume per-canale mancante.** Il sistema chiede `kAudioDevicePropertyVolumeScalar` su
   `element 1` e `2` oltre che `main`. Rispondendo solo a `main`, la HAL non costruisce il
   volume del device e i tasti del volume non fanno nulla.

**Latenza**, misurata e poi ridotta: ring da 200 a 50 ms (`staleAfterFrames` 9600 → 2400), coda
da 150 a 60 ms. Da ~450 ms a **~150 ms** (ring 9 ms, coda 60 ms, `skip` 0). I 50 ms iniziali
erano troppo stretti — CoreAudio consegna blocchi da 1024 frame (21 ms) e il lettore saltava a
ogni lettura, cioè un click — ma a 200 ms il ritardo si sentiva. 50 ms sono due blocchi e mezzo.

**Il volume**: applicato da `codecblue` prima dell'encoder, non nel driver. Nel driver ogni
variazione doveva attraversare ring e coda: **2–3 secondi** tra lo slider e l'effetto. Ora ~50 ms.
Il valore si legge con un listener CoreAudio (`SystemVolume`), non con polling. Il driver
persiste il volume in `/tmp/codecblue-volume`, perché macOS ne ricorda uno per UID e il driver
lo sovrascriverebbe a ogni riavvio.

**Il gracchiare**, la causa vera: quando il ring restituiva **meno frame del richiesto**, il
resto del blocco veniva riempito con **zeri**. Ogni underrun metteva uno scalino nell'onda, e
uno scalino è un click. Ora il resto **tiene l'ultimo campione** (`lastSample`). Non era il
link, non era il ring che saltava (`skip` 0), non era il codec.

### 13.10 La coda adattiva, e perché il gracchiare non era la batteria

Il sintomo: `dropped 2–22%`, `socket full` 8–27 volte per finestra, coda 0–32 ms. Con una coda
fissa da **250 ms** invece di 60: `dropped 0%`, nessun gracchiare.

Quindi il link **non perde pacchetti: stalla**. Smette di accettare per 100–300 ms, poi riprende.
Con 60 ms di budget lo stallo eccede il buffer e il PCM viene buttato — ed è quello il
gracchiare. Con 250 ms ci sta dentro. La batteria al 10% era un sospetto plausibile ma **falso**:
le stesse cuffie scariche, con macOS, suonano bene.

Il compromesso non va bene: 250 ms di coda sono 250 ms di ritardo su ogni video. Quindi la coda
**impara** (`PacketQueue.noteStall` / `relax`):

- parte da **60 ms**;
- ogni stallo la **raddoppia**, fino a un tetto di **400 ms**;
- una finestra pulita la **dimezza**, mai sotto i 60 ms.

Latenza bassa quando il link è buono, protezione quando serve. Misurato con audio reale:
`queue 0–16 ms`, `socket full 1–2 volte (3–6 ms)`, `dropped` mai comparso.

La decisione "questa finestra è pulita?" sta **nel chiamante**, che ha il contatore degli stalli;
la coda fa solo l'aritmetica. Tenerla in due posti li faceva divergere — un test lo ha colto.

### 13.11 Cosa resta aperto

- **I 990 kbps di HQ**: serve il 3-DH5, o `A2DP Link Adaptive Packet Type` (bluetoothd logga
  `Link Adaptive Packet type support=0`, quindi il controller dice di non supportarlo) — oppure
  accettare MQ come qualità di lavoro, che è già LDAC vero a 330 kbps.
- **La qualità adattiva**: con la LQM accesa c'è margine per scegliere HQ/MQ in base alla coda
  invece che a priori. È il `BitrateAdapter` previsto nel PLAN.
- **Blue Bloom**: la previsione delle note precedenti ("ha lo stesso tetto") va riletta: se
  anche lui non tocca la LQM, con queste cuffie non può superare ~50 kbps. Il suo bitrate
  adattivo lo maschera, ma non lo risolve.

---

## 14. Sessione 2026-11-06: la terza porta

- `com.apple.BTAudioHALPlugin.xpc` **accetta** i nostri messaggi (nessun entitlement, a differenza
  di `general.xpc`). Enum dei 21 messaggi letto dal log, uno per uno.
- Il canale **crashta bluetoothd** con `CFRelease(NULL)` su ogni messaggio senza
  `kBTAudioMsgArgs`: quattro crash report identici, `EXC_BREAKPOINT` in
  `_xpc_connection_call_event_handler` → `CFRelease`. Bluetooth torna su da solo in 1–2 s.
- `codecblue audiocan ADDR` aggiunto e **disattivato** (serve `CODECBLUE_AUDIO_CHANNEL=yes`).
- `XPCProbe.sendRaw` aggiunto: invio di un dizionario con chiavi arbitrarie e annidate.
- Raccolto di passaggio: macOS in AAC fa 230 kbps con 6,8% di ritrasmissioni, RSSI −54 dBm,
  zero 3-DH5 (`A2DP LinkQualityReport`). L'aria avanza.
- Self-test: 317 check, 0 falliti.

## 12. Cronologia della sessione

| passo | esito |
|---|---|
| Prima `play` (HQ, tono 20 s) | setup completo, coda in crescita, ~50 kbps |
| Diagnosi del report | 2 bug (packets/s, kbps cumulativi) + `break` che girava a vuoto |
| `PacketQueue` + scarto audio vecchio | latenza limitata, il tetto resta |
| MQ | 40–113 kbps: non è il codec |
| `--sndbuf-packets` 4/8/16 | nessun effetto |
| `--media-priority` 1/2/3 | nessun effetto (`priority:0` nel log) |
| `--media-mtu` 679 vs 895 | nessun effetto |
| `--no-hfp` / `--no-avrcp` | nessun effetto |
| Ipotesi sniff (prima stesura) | giusta, ma senza la prova che restasse in sniff durante lo stream |
| `general.xpc` | entitlement negato |
| `xpcscan` | mappatura sparsa: numero di `SetACLHighPriority` non deducibile |
| Lettura di Blue Bloom | identico sul link; la differenza è il dispositivo audio virtuale |
| `flood` | tetto in byte: 50–77 kbps con qualunque dimensione |
| Confronto con macOS in AAC | 43 pkt/s configurati, 0 letture PipeMgr: percorso diverso |
| `pace` a 43 pkt/s | rifiuta il 75%: è il canale, non il ritmo |
| Bug: MTU < 679 | segfault di libldac, ora bloccato |
| Bug: WAV negativo | crash, ora corretto |
| Ordine del ciclo | ora invia prima di codificare |
| Rilettura delle note del prototipo | **la cuffia regge 1 Mbps** (§9): il tetto non è l'hardware |
| **"Non è lo sniff" (seconda stesura)** | **sbagliata**: `ModeChange handle 31` era un altro link; "nessun ModeChange" significava "resta in sniff", non "resta active" |
| Rilettura del log con handle e orari | macOS esce da sniff (`Server.Audio`, 2->0), noi no: **lo sniff è la causa** (§4.4) |
| Riscrittura di queste note | un documento unico, con i due errori dichiarati |

### 13.12-bis CORREZIONE: la LQM funziona anche con CodecBlue come uscita

La sezione che segue è **sbagliata** nella conclusione. È rimasta qui perché la catena causale
che descrive è giusta e serve; quello che non regge è il verdetto.

**Cosa ho misurato dopo, con le cuffie riconnesse:**

```
18:59:40  Closing media channel for handle 1
18:59:40  Erased 1 audio device …-tacl from audio device map … Map now has 1 devices
18:59:54  Register audio device 40:DC:A5:XX:XX:XX-tacl        ← torna da solo, 14 s dopo
```

`bluetoothd` **ricrea** il device dopo il takeover. Il keeper riprova ogni secondo, quindi dopo
una quindicina di tentativi il messaggio passa:

| uscita | cuffie | flood | `audio started` | LQM |
|---|---|---|---|---|
| FreeBuds 5 | connesse | 464 kbps | 5 | accesa |
| CodecBlue | connesse | **502 kbps** | 4 | **accesa** |
| CodecBlue | **sconnesse** | 255–380 kbps | 0 | spenta |

Le prove che avevo fatto «con CodecBlue» erano tutte a cuffie **sconnesse** — me le ero perse
io durante i test di riconnessione, e non me ne sono accorto perché `system_profiler` mostra le
cuffie anche nella sezione *Not Connected*. Da lì la conclusione sbagliata.

**Regola che ne ricavo, e che vale più della correzione**: prima di attribuire un
comportamento al codice, verificare che il dispositivo sia ancora lì. `system_profiler` elenca
anche i dispositivi non connessi, quindi il conteggio va fatto dentro la sezione `Connected:`,
non sul testo intero — un `grep -c` sull'output completo dà 1 anche a cuffie spente.

**Conseguenza pratica**: non serve pubblicare un device finto. Serve solo **aspettare** che
`bluetoothd` ricrei il `-tacl` e non dichiarare la LQM accesa prima. Il keeper deve dire quando
il messaggio è arrivato davvero, invece di ripetere in silenzio.

### 13.12 Perché la Link Quality Mode cade quando CodecBlue è l'uscita (superata da 13.12-bis)

Indagine del 2026-11-06, dopo che l'utente ha riferito «scatti e gracchiare» con la coda a
250 ms. La coda non c'entrava: **la LQM era spenta**.

Firma nei numeri, prima di guardare i log:

```
socket full 76–125 volte (fino a 2105 ms), at most 3 packet(s) per drain
```

`at most 3 packet(s) per drain` è la LQM **spenta**; accesa sono 70–500 (misurato: 523).
Il log di `bluetoothd` lo conferma: 105 `No device found for uid …-tacl` in 2 minuti,
zero `Enabling A2DP Link Quality Mode`.

**La catena causale, letta dal log.** Il takeover chiude il canale media di bluetoothd:

```
Closing media channel for handle 1
AccessoryAudioClient destroyAccessoryAudioDevice 0x7b75110380
void BT::AudioDevice::unpublish() Unpublishing audio device 40:DC:A5:XX:XX:XX-tacl
-[AudioDeviceManager sendMsg:withArgs:uid:] msgID: BTAudioMsgIdClose, for UID: …-tacl
Erased 1 audio device …-tacl from audio device map … Map now has 0 devices
```

Da lì `AudioDeviceManager` non ha più nessun device con quell'uid, quindi ogni successivo
`BTAudioMsgIdStartAudio` cade in `forwardEvent:forUid:` con `No device found`. Il keeper
continua a mandare il messaggio — è per questo che il log si riempie di errori identici —
ma non arriva a nessuno.

**Misura che separa le due ipotesi** (flood 679 B, 8 s):

| uscita di sistema | keeper | flood | LQM |
|---|---|---|---|
| HUAWEI FreeBuds 5 | sì | **470 kbps** | accesa |
| CodecBlue | sì | 255–380 kbps | spenta |
| CodecBlue, dopo 20 s | sì | 478–510 kbps | ? |

L'ultima riga è ambigua: il flood è alto ma `audio started` resta 0, quindi il numero viene
dal fatto che il flood satura da solo il socket, non dalla LQM. **Il discriminante non è il
throughput del flood, è la presenza di `Received system 'audio started'` nel log.** Su quello
non c'è ambiguità: 0 in tutte le prove con CodecBlue come uscita.

**Cambiare l'uscita mentre il keeper gira non serve** (provato: flood 277 kbps prima, 380 dopo
il cambio). La LQM cade quando bluetoothd ritira il device, non quando cambia l'uscita.

**Cosa NON è la causa**, verificato e scartato:

- la batteria (l'utente: «con macOS, anche scariche, si sentono bene» — e aveva ragione);
- la coda dei pacchetti (con budget 250 ms la coda restava a 0–16 ms, perché il collo di
  bottiglia era a monte: vedi 13.10);
- l'uuid sbagliato: `4379D275-655C-EEB8-BB72-643BF2534BE0` è lo stesso di quando funzionava;
- il suffisso dell'uid: provati `-tacl`, `-taad`, `-tsco`, nessuno produce `audio started`.

**Le tre vie, in ordine di costo.**

1. **Pubblicare il device noi.** `BTAudioMsgIdPublish` (=2) è il messaggio con cui il device
   nasce nella mappa di `AudioDeviceManager`. Se riusciamo a pubblicare un device con uid
   `40:DC:A5:XX:XX:XX-tacl`, `StartAudio` trova qualcosa e la LQM si accende anche a cuffie
   ritirate. Il rischio è noto e documentato in §7.3: un `Publish` malformato fa
   `CFRelease(NULL)` e uccide bluetoothd. **Ora però la forma del messaggio si legge dal log**
   di bluetoothd quando pubblica lui (`kBTAudioMsgArgDeviceType`,
   `kBTAudioMsgArgDeviceProperties`, `kBTAudioMsgPropertyDeviceUID/DeviceAddress`) — non è più
   da indovinare. Resta che ogni tentativo sbagliato costa un riavvio del demone.
2. **Non far ritirare il device.** Il ritiro nasce dalla chiusura del canale media. Se il
   takeover non chiudesse il canale di bluetoothd ma aprisse un secondo canale L2CAP verso le
   cuffie, bluetoothd terrebbe il device e la LQM. Problema: due stream A2DP verso le stesse
   cuffie, che ne accettano uno.
3. **Tenere le cuffie come uscita e non fare il takeover.** È l'unica che funziona oggi, ma
   allora il codec lo sceglie macOS (AAC/SBC), non noi: niente LDAC.

**Regola per il futuro, da mettere accanto a quella dei probe**: un numero alto nel report non
dimostra che il meccanismo funzioni. `at most N packet(s) per drain` e
`Received system 'audio started'` sono le due misure che distinguono «il link è veloce» da «la
LQM è accesa». Il throughput del flood da solo inganna, perché il flood satura il socket anche
senza LQM.

### 13.13 Il rumore sulla cuffia destra: il fill teneva un solo campione

Sintomo riferito: «piccoli rumori sulla cuffia **destra**». Non su entrambe — e questo è il
dato che risolve il caso.

Il riempimento da underrun teneva **un** campione:

```swift
var lastSample: Float = 0
...
scratch[i] = i < chunk.count ? chunk[i] * level : lastSample * level
if let last = chunk.last { lastSample = last }
```

Due errori in tre righe:

1. `chunk.last` in un blocco interleaved è il campione **destro**: il sinistro non veniva mai
   ricordato.
2. Quel valore veniva poi scritto su **entrambi** i canali, quindi a ogni underrun il valore del
   destro finiva anche nel sinistro.

Risultato: plateau di tensione nel canale destro (rumore) e salto di ampiezza nel sinistro
(click), entrambi invisibili a `skip`, `dropped` e `queue`. È la stessa classe di bug del §13.4
— il fill che azzerava — e la lezione è la stessa: **il fill è codice che produce audio, quindi
va guardato come audio**, non come riempimento.

Corretto con `lastLeft`/`lastRight` separati, e un test che verifica che il sinistro **non**
venga sovrascritto col valore del destro.

**Perché solo ora**: prima il cuscino era a 50 ms e il ring veniva svuotato dal lettore, quindi
gli underrun erano rari e brevi; con il cuscino a 250 ms e il writer che deriva, gli underrun
arrivano in fondo al cuscino e il fill viene esercitato molto più spesso. Il bug c'era da
sempre, ma il rumore è diventato udibile quando il percorso ha cominciato a funzionare.

### 13.14 Due cause di "in ritardo", due risposte opposte

Il ciclo saltava l'audio stale ogni volta che l'encoder era dietro l'orologio:

```swift
if due - position > queue.maxFrames { /* salta */ }
```

Ma "essere dietro" ha due cause che vogliono risposte opposte:

- **il link è lento** → la coda è piena e non accetta altro → saltare ha senso, il ritardo
  crescerebbe;
- **la sorgente è lenta** → non c'è audio da leggere → **aspettare**. Saltare qui butta via
  audio che non era in ritardo di niente.

Il discriminante è `queue.hasRoom`. Senza, il report leggeva `dropped 100%` con il ring
perfettamente sano — un numero che accusava il link per un problema che non esisteva.

Corollario, altrettanto importante: **una lettura vuota non è silenzio**. `play(pulling:)`
riempiva di zeri quando il ring non aveva frame; ora restituisce niente e il ciclo aspetta. Il
cuscino può assorbire uno stallo solo se l'audio viene **trattenuto**, non sostituito.

### 13.15 Il gracchiare "da subito": il periodo del clock del driver era un secondo

Sintomo: «lo sento da subito», anche se basso. Un rumore che c'è dal primo secondo è
**strutturale**, non una deriva: non è il cuscino che si esaurisce, è qualcosa che sbaglia in
modo continuo.

Il driver dichiarava al sistema:

```c
case kAudioDevicePropertyZeroTimeStampPeriod:
    *(UInt32*)outData = kRingFrames;   // 48000 = un secondo intero
```

`kRingFrames` è la dimensione del ring (1 s di audio), e va benissimo come tale. Ma
`kAudioDevicePropertyZeroTimeStampPeriod` è **il periodo contro cui il sistema pianifica l'IO**:
CoreAudio confronta il proprio orologio con quello dichiarato dal device e corregge la
differenza. Con un periodo di un secondo, la correzione avviene una volta al secondo e in un
colpo solo — una discontinuità nell'audio, udibile come piccolo gracchiare continuo.

Un device virtuale normale usa 512–4096 frame (10–85 ms). Ora 512 (10.7 ms): la deriva viene
corretta un centinaio di volte al secondo, quindi lo scarto per correzione è minuscolo.

**Perché era sfuggito**: il valore era corretto *come numero* — il commento sopra spiegava
addirittura che doveva essere un multiplo esatto del periodo, e lo era. Il bug era semantico:
la costante giusta usata per la proprietà sbagliata. Nessun test poteva coglierlo, perché il
driver non ha test: si vede solo ascoltando, ed è per questo che serviva la tua orecchia.

**Regola**: nel driver, ogni proprietà va letta come una domanda a cui il sistema crede. Una
costante giusta nel posto sbagliato produce audio che *sembra* funzionare e gracchia.

### 13.16 Un tentativo sbagliato, registrato perché non venga rifatto

Ho provato a spostare il cuscino dal ring alla coda dei pacchetti, alzando `leadTime` a 250 ms.
Risultato: **peggio**. `ring: 0 frames waiting`, `at most 8 packet(s) per drain`, letture corte
continue.

Il motivo è che la sorgente è **dal vivo**: l'encoder non può correre avanti rispetto ad audio
che il driver non ha ancora prodotto. Alzare il lead non crea audio, lo chiede e basta, e la
lettura torna corta. Il cuscino può stare solo dove l'audio esiste già — nel ring — e il lead
deve restare piccolo (40 ms).

Revertito. Il codice ora lo dice nel commento, così il tentativo non viene rifatto.

### 13.17 La pausa: l'orologio continuava a correre

Sintomo dopo una pausa e ripresa: «gracchiare tanto, andare a rallentatore, strani fruscii».
Tre sintomi insieme che indicano una cosa sola: **l'encoder crede di essere in ritardo**.

`due` si misura da `start`:

```swift
let due = min(Int((Double(now - start) / 1e9 + lead) * Double(rate)), total)
```

Mentre gli headphones hanno sospeso lo stream il ciclo faceva `usleep(5000); continue` senza
toccare `start`. Quindi al "start" degli headphones l'encoder credeva che **tutta la pausa**
fosse audio dovuto in quel momento: riempiva la coda fino al tetto, la coda traboccava, e il
risultato è audio compresso nel tempo (rallentatore), distorto (gracchiare) e con plateau
(fruscii).

Le misure lo dicono senza ambiguità:

```
streaming: 406 kbps out, 75 packets/s, link took 121% of real time (codec MQ 330 kbps)
           queue 320 ms, dropped 2%, 267 short read(s) (17088 frames held)
ring: 192 frames waiting        ← il writer non riesce a stare dietro
```

**406–452 kbps da un codec da 330**: stavamo chiedendo al codec più di quanto possa produrre,
perché gli chiedevamo di recuperare 30 secondi in un colpo. E `17088 frames held` = 356 ms di
plateau nella finestra: i fruscii.

**Corretto in due punti**, perché sono due errori distinti:

1. **l'orologio non viene addebitato per la pausa**: `start` (e `lastReport`) avanzano della
   durata effettiva della sospensione, quindi la ripresa riparte da dove si era fermata;
2. **la coda viene svuotata alla ripresa**: l'audio in coda è di prima della pausa, e suonarlo
   dopo è il "rallentatore". `state.flushQueue` lo fa buttare al primo giro.

**Nota su come è stato trovato**: i tre sintomi riferiti insieme — gracchiare, rallentatore,
fruscii — sono la firma di un burst. Un solo sintomo avrebbe potuto essere il link; tre insieme
descrivono sempre un problema di *tempo*, non di banda. Vale la pena ricordarlo: quando i
sintomi sono più d'uno e sono qualitativi (velocità, tono, distorsione), il sospetto è
l'orologio.

### 13.18 La pausa dell'app non è un suspend AVDTP

Il fix del §13.17 non si attivava mai, e la prova è che `headphones suspended the stream` non
compariva **mai** nel log. Le cuffie non sanno niente della pausa: l'app ferma di scrivere nel
device, il driver smette di riempire il ring, e per AVDTP lo stream è sempre attivo.

Quindi `state.suspended` resta `false`, l'orologio continua, e al resume `due` è avanti di tutta
la pausa. Con 2–3 s di pausa il recupero passava inosservato per fortuna; con 10 s produceva
rallentatore, distorsione e 280 letture corte per finestra — esattamente quello che l'utente ha
descritto.

**L'unico testimone è la sorgente.** Se `due - position` supera il doppio del cuscino, lo stream
non stava scorrendo: l'orologio viene riportato indietro (`start` e `lastReport` avanzano del
ritardo) e la coda svuotata. Una volta per ogni tratto di inattività — senza il flag, la
condizione resta vera a ogni giro (la `position` non può avanzare col ring vuoto) e il log si
riempiva di un reset ogni mezzo secondo.

**Regola**: quando una correzione «non fa niente», la prima domanda non è se è giusta, ma se
**viene eseguita**. Il log che avrebbe dovuto dimostrarlo era già lì — bastava cercarlo.

### 13.19 Il reset dell'orologio uccideva il processo

Il fix del §13.18 spostava `start` in avanti:

```swift
start &+= UInt64(behind * 1e9)   // sbagliato
```

Ma `behind` è `due - position`, che include il `lead`: spostando `start` di quella quantità lo
si mette **davanti a `now`**, e `now - start` su un `UInt64` va in underflow. Swift lo tratta
come errore fatale:

```
EXC_BREAKPOINT (SIGTRAP)
Swift runtime failure: arithmetic overflow
A2DPStreamer.playLoop(feed:endless:totalFrames:)
```

Crash report `codecblue-2026-11-06-193058.ips`, 50 s dopo l'avvio, appena il video ha fatto una
pausa. Il sintomo per l'utente: «non sento nulla» — il processo era morto.

**Corretto**: la sorgente è dal vivo, quindi non c'è audio vecchio che valga la pena suonare. Si
salta la `position` a live e si riancora `start = now`. Nessun underflow possibile, e il
comportamento è quello giusto: dopo una pausa si riparte dal presente, non dal punto in cui si
era fermato.

**Regola**: un `UInt64` che rappresenta un istante non si "aggiusta" sommandogli un delta
calcolato altrove. Se il delta può superare la differenza, la sottrazione va in underflow e Swift
lo tratta come un errore fatale — non come un numero negativo. Meglio riassegnare l'istante a
`now`, che è sempre valido per costruzione.

### 13.20 `position` e `start` sono una coppia, e il driver non tace mai

Due cose imparate a spese dell'utente, entrambe da non rifare.

**1. `position` è misurata *contro* `start`.** Non si possono muovere separatamente:

| tentativo | effetto |
|---|---|
| `start += due - position` | `start` finisce davanti a `now`, `now - start` va in underflow, **crash** |
| `position = live; start = now` | `position` resta avanti a un `due` ripartito da zero: niente è mai dovuto, **silenzio per 25 s** |
| `position = 0; start = now` | corretto: si riparte dal presente, e l'audio torna dovuto subito |

**2. Il driver non smette di scrivere quando l'app va in pausa: scrive silenzio.** Quindi il ring
resta pieno (`10080 frames waiting` anche durante la pausa) e `due - position` non cresce: il
reset dell'orologio **non scatta mai** in una pausa dell'app. Scatta solo quando il *device* si
ferma davvero (cambio di uscita, app chiusa).

Conseguenza: il reset è una rete di sicurezza per il caso «la sorgente si ferma», non la
soluzione per la pausa dell'app. Per la pausa dell'app la soluzione è che il silenzio scorra
normalmente, ed è quello che succede: misurato, `336 kbps` prima e dopo, senza reset.

**Il gate sul cuscino è stato rimosso**, e vale la pena ricordare perché: `if ring.available <
keepAliveFrames { return [] }` va in **deadlock**. Il lettore aspetta che lo scrittore riempia il
cuscino, ma lo scrittore è esattamente ciò che il lettore sta consumando. Misurato due volte: il
ring si è fermato a 2848 frame contro una soglia di 2880 e lo stream è andato muto. Non serve
nemmeno: con il periodo del clock a 512 frame la deriva che svuotava il cuscino è sparita, e la
profondità si tiene da sola fra 9888 e 10208 frame.

### 13.21 Cosa legava il programma a un paio di cuffie specifico

Domanda dell'utente: «l'importante che funzioni poi in caso con tutte le cuffie e non solo con le
mie». Verificato punto per punto, e tre cose erano davvero legate al device di sviluppo.

**1. Il sample rate era un requisito, non una preferenza.** `setUp(sampleRate:)` rifiutava con
`unsupportedRate` se le cuffie non offrivano esattamente 48 kHz. Un paio che in LDAC accetta solo
44.1 kHz veniva **respinto** — una limitazione del programma, non dell'hardware. Ora il rate
richiesto è una preferenza: si prende quello fra i loro, e il log dice quale.

**2. Mancava il resampler.** Il device virtuale gira a 48 kHz (è quello che ogni app ci scrive),
ma le cuffie possono volere 44.1. `Resampler` (interpolazione lineare, stato fra i blocchi)
converte. Il test che conta è quello sul bordo del blocco: la prima versione prendeva l'ultimo
frame dal blocco *precedente* anche in coda, quindi ogni blocco collassava verso l'audio vecchio
— un click a ogni confine. Il self-test l'ha colto subito.

**3. Il keeper riconosceva il suffisso `-tacl`.** Il suffisso di trasporto non è garantito uguale
per tutte le cuffie (`-taad`, `-tsco` esistono). Ora si riconosce l'**indirizzo**, e il taglio va
fatto sul separatore del suffisso, non sui trattini: l'indirizzo in forma CoreAudio è pieno di
trattini (`40-DC-A5-...`), e tagliare su quelli lo spezza a metà. Anche questo l'ha trovato un
test.

**Cosa era già generico**, verificato e non toccato: la SEID si legge dalla scoperta degli
endpoint, il bitrate parte da MQ con adattamento, il canale AVRCP e quello hands-free si aprono
per numero di servizio, il volume passa per i decibel dichiarati dal driver.

**Il limite che resta, e va detto**: il programma implementa **solo LDAC**. Cuffie senza LDAC
(SBC/AAC soltanto) non possono essere pilotate, e l'errore ora lo dice esplicitamente invece di
lasciar credere che sia un problema di configurazione.

### 13.22 La latenza: il cuscino parte da 80 ms e impara

La latenza era 250 ms perché il cuscino era fisso al caso peggiore, pagato su ogni video. Ma gli
stalli che copre sono **rari**: pagare sempre per il peggiore è sbagliato quando il meccanismo per
non pagarlo esiste già.

Il cuscino ora parte da **80 ms** e usa l'adattamento che c'era già in `PacketQueue`:

- uno stallo più lungo di metà del cuscino lo **raddoppia**, fino a un tetto di 300 ms;
- cinque finestre pulite consecutive lo **dimezzano**, mai sotto gli 80 ms.

E il ring segue la coda: `streamer.cushionChanged` riallinea `ring.staleAfterFrames`. Sono un
numero solo in due posti — un ring più profondo della coda aggiungerebbe ritardo che la coda non
usa.

**Una lezione sul metodo.** Avevo scritto una `CushionPolicy` separata, con i suoi test, prima di
accorgermi che `PacketQueue.noteStall/relax` faceva già esattamente questo. L'ho **cancellata**:
due implementazioni della stessa politica, con due velocità di apprendimento diverse, si sarebbero
contraddette. Il valore aggiunto non era il codice nuovo, era **abbassare il floor da 250 a 80 ms**
— una riga. Vale la pena ricordarlo: prima di scrivere, guardare se la cosa esiste già.

**Da misurare** (le cuffie erano sconnesse): il floor minimo che non produce scarti. 80 ms è una
scelta ragionata — due stalli misurati erano da 40–122 ms, quindi 80 copre i primi e si allarga
sui secondi — ma va verificata con una scansione 250/180/120/80 ms, contando scarti, letture corte
e skip.

### 13.23 Latenza: da 250 ms a 81 ms, e i quattro errori che ci sono voluti

Obiettivo: meno latenza. La latenza **è** il cuscino — il buffer delle cuffie e il frame LDAC sono
fissi — quindi tutto il lavoro è stato su quanto audio tenere in mano.

**Risultato misurato**: cuscino stabile a **3904 frame = 81 ms**, `dropped 0`, `short read 0`,
`skip 0`, 336 kbps. Contro i 250 ms fissi di partenza.

Quattro errori, tutti trovati misurando e nessuno visibile a occhio:

**1. Il throttle si spegneva a metà del target.** `guard depth < target / 2` significava che il
cuscino si fermava a 40 ms su un target di 80 — metà della latenza richiesta e metà del cuscino
necessario. Ora la soglia è il target intero; rallentare non ferma mai il consumo, quindi non può
andare in deadlock.

**2. `staleAfterFrames` era un grilletto, non un budget.** Il lettore saltava in avanti appena il
depth superava il budget. Ma il throttle tiene il depth *a* quel budget, quindi superarlo è
normale mentre il cuscino si ricostruisce: saltare buttava via esattamente il cuscino appena
creato. **86 skip in una sola sessione**, uditi come click, con tutti gli altri numeri sani. Ora
si salta solo quando il ring ha davvero girato su se stesso e l'audio è stato sovrascritto.

**3. La regola di allargamento era troppo sensibile.** "Stallo ≥ metà del cuscino" allargava per
stalli che il cuscino già assorbiva: 46 ms portavano 80 → 160, poi 81 ms portavano 160 → 320. E
siccome il link ha stalli in quasi ogni finestra, il cuscino **non tornava mai giù**: 320 ms
fissi su un link il cui stallo peggiore era 104 ms. Ora si allarga solo se lo stallo **supera** il
cuscino (≥ 90%).

**4. Il lettore partiva dall'inizio del ring.** Il driver riempie il ring da quando è caricato, e
`StartIO` lo azzera (`write = 0; read = 0`) in un momento che non controlliamo. Un solo
`jumpToLive()` prima del ciclo non bastava: misurato, il depth restava a **46 000 frame su 48 000
— 960 ms di latenza — per tutta la sessione**, perché il lettore era permanentemente un ring
indietro. Ora il controllo è dentro il ciclo: se il depth supera il doppio del budget non è un
cuscino, è un arretrato, e si salta al presente.

**La lezione che vale più delle quattro**: ogni numero di questa sessione — `dropped`, `skip`,
`queue`, `kbps` — è rimasto sano mentre l'audio era sbagliato. `skip` è stato l'unico che ha
parlato, e solo perché l'ho aggiunto al report invece di lasciarlo in un commento.

### 13.24 "È più di 80 ms": i 81 ms erano solo la mia parte

L'utente ha misurato a orecchio più di 80 ms, e aveva ragione. **81 ms era il cuscino, non la
latenza.** La latenza è la somma di cinque cose, e solo tre sono mie:

| componente | ms | mia? |
|---|---|---|
| lead dell'encoder | 40 → **15** | sì |
| cuscino nel ring | 81 → **60** | sì |
| coda dei pacchetti | 0–16 | sì |
| frame LDAC + link | ~50 | no |
| buffer delle cuffie | ~150 | no |

Totale prima: **~320 ms**. Totale ora: **~275 ms**. La parte mia è scesa da 137 a 75–91 ms.

**Il lead era il colpevole più stupido**: 40 ms per dare all'encoder qualcosa da inviare
all'inizio. Il lookahead LDAC è ~10 ms, quindi 15 bastano. Nessun test poteva dirlo — è un numero
scelto a mano e mai rimisurato dopo che il resto è cambiato.

**Le cuffie non riportano il delay.** `delayReport` non arriva mai (il codice c'è, la riga di log
non compare): quindi il buffer delle cuffie non è misurabile e la cifra di ~150 ms è una stima,
non un dato. Va detto quando si parla di latenza.

**Il limite onesto**: sotto i ~275 ms non si scende senza rompere qualcosa. Il cuscino a 60 ms ha
già richiesto tre allargamenti in 70 s su questo link (stalli da 67, 122, 251 ms), e ognuno è
latenza aggiunta che poi resta. Un cuscino più piccolo produce click; il buffer delle cuffie non
si tocca. Chi vuole meno latenza di così deve accettare che il link stalli, e sentirlo.

### 13.25 Il file di test cracklava da solo

L'utente: «quando suona il suono dei toni si sentono dei rumori ma forse è colpa dell'audio che
mandi». **Aveva ragione.** Il file era questo:

```swift
let phase = (t * 2).truncatingRemainder(dividingBy: 1)
let note = notes[Int(t * 2) % notes.count]
let envelope = min(1, phase * 20) * (1 - phase) * 0.25
samples[i*2] = envelope * sin(2 * .pi * note * t)
```

La frequenza cambia ogni 0,5 s ma **`t` continua a scorrere**: a ogni cambio di nota la fase fa un
salto. L'inviluppo ne mascherava la maggior parte, ma il segnale è pieno di discontinuità — e una
discontinuità è esattamente ciò che un codec e un link peggiorano. **Stavamo testando il file, non
il trasporto.**

Misurato: salto massimo fra campioni consecutivi **882** nel vecchio file contro **308** in un
seno a 440 Hz della stessa ampiezza (teorico 283). Tre volte tanto, e distribuito su tutto il
file.

**Ora** `WAVFile.sine` genera un seno puro, costante, con la frequenza arrotondata a un numero
intero di cicli nel file: l'ultimo campione si ricongiunge al primo senza gradino, quindi anche in
loop è continuo. `WAVFile.sweep` fa una rampa 100 Hz → 8 kHz con fase accumulata (niente salti)
per sentire cosa fa il codec lungo la banda.

**La lezione, che è la seconda volta**: un file con attacchi netti non distingue «gracchia il
codec» da «gracchia il file». Era già scritto nel §13.6 dopo il primo giro, e l'ho violato di
nuovo usando l'arpeggio per misurare la latenza. Un segnale di test deve essere **più pulito del
sistema che misura**, altrimenti misura se stesso.

### 13.26 "Non sento nulla": le cuffie chiudono il canale e noi ci arrendevamo

Sintomo: video avviato, **silenzio**. Il log lo diceva chiaramente:

```
[  7.953] streaming: 0 kbps out, 0 packets/s
...
[ 14.173] source was idle for 6.6 s: the clock is reset, not caught up
[ 14.321] media channel closed by the headphones
[ 14.322] handing the headphones back to macOS
```

Le cuffie chiudono il canale media quando non ricevono audio per qualche secondo — è il loro
risparmio energetico, non un errore. Ma il nostro codice, su `.closed`, faceva `return`: finiva
**tutto lo stream**, restituiva le cuffie a macOS, e da lì in poi l'audio andava dove macOS
decideva. Per chi ascolta: silenzio, o l'uscita sbagliata.

**Corretto**: su `.closed` il canale viene **riaperto** (`reopenMediaChannel`), tenendo la
configurazione LDAC. Il canale è solo il trasporto; la configurazione è ancora valida, e
riaprire costa un handshake invece di un'intera sessione.

**Perché il test di prima non l'ha colto**: nel test precedente il video stava suonando, quindi il
ring non si svuotava mai e le cuffie non chiudevano nulla. Serve una pausa di **più di 10 secondi**
per riprodurlo, ed è esattamente quello che l'utente ha fatto.

**Nota su un secondo sintomo**: quando il canale si chiude e noi ci arrendiamo, `ring` va a
`48000 frames waiting` — un secondo intero di audio accumulato che nessuno legge. Quel numero, da
solo, dice «il lettore è morto»: vale la pena guardarlo per primo.

### 13.27 Il LaunchAgent, e il device che taceva

Due cose che mancavano, entrambe di quelle che costano tempo all'utente invece che a chi scrive.

**1. `codecblue agent install|remove|status`.** Un plist in `~/Library/LaunchAgents` che lancia
`codecblue system <address> --quality MQ` al login, con `KeepAlive` (lo streamer esce quando le
cuffie si disconnettono, e tornare quando tornano è il punto) e `ThrottleInterval` 5 (un crash
loop non deve girare a vuoto). Il log va in `/tmp/codecblue-agent.log`, perché un LaunchAgent
gira fuori da qualsiasi terminale: se fallisce, il suo fallimento non ha dove farsi vedere.

**Il percorso del binario è la parte fragile**, e vale la pena scriverlo: `Bundle.main.executableURL`
e `CommandLine.arguments[0]` puntano entrambi a `.build/out/Products/Debug/codecblue`, che
`swift package clean` cancella. L'agente fallirebbe al login con nient'altro nel log che "no such
file". Si risale quindi al repository e si usa `.build/debug/codecblue`, il symlink stabile che
SwiftPM mantiene e che il launcher `codecblue` esegue.

**2. Il device ora dice quando nessuno lo alimenta.** Se il ring è vuoto all'avvio:

```
the ring is empty: if apps are playing and you hear nothing, the device is selected but nothing
is feeding it. Check that this process is running (`codecblue agent status`), then play something.
```

E `codecblue agent status` risponde alla domanda vera — «l'audio device è alimentato?» — guardando
se il file del ring è stato modificato negli ultimi 2 secondi. Non se il processo esiste: se
*qualcuno scrive*. È la differenza fra «sembra avviato» e «funziona», e questa sessione è stata
tutta su quella differenza.

**Test**: il plist viene fatto **parsare** con `PropertyListSerialization`, non solo confrontato
come stringa. Un plist che non parsa è un agente che non fa niente in silenzio, che è esattamente
il modo di fallire che questa funzione esiste per evitare. C'è anche il caso con `&` nel percorso,
che senza escape renderebbe il file invalido.

### 13.28 Gli scanner che uccidevano bluetoothd sono stati resi impossibili

`xpcscan` e `generalscan` mandavano **ogni numero in un intervallo** a `bluetoothd`. Il 2026-11-06
lo hanno ucciso cinque volte su cinque: quattro `EXC_BREAKPOINT` da `CFRelease(NULL)` e una
eccezione ObjC in `CFBooleanGetValue`. La regola era già scritta nelle note — *un probe che parla
con un processo di sistema non deve poter mandare messaggi arbitrari* — ma il codice la violava
ancora, perché la regola era solo un commento.

**Ora è un tipo.** `KnownMessage` (`Sources/CodecBlueCore/Bluetooth/KnownMessage.swift`) contiene
le uniche chiavi che si possono spedire, prese dal log di una chiamata funzionante e dalle stringhe
del binario. Il comando che li usa si chiama `handlers device|general` e **non ha un parametro per
l'intervallo**: non esiste un modo di chiedere un numero sconosciuto, quindi non esiste un modo di
raggiungere un caso che `bluetoothd` non gestisce.

Verificato: `./codecblue handlers device` manda dieci messaggi noti e `bluetoothd` è ancora vivo.

**Il test che conta** non è «la tabella non è vuota»: è che `KnownMessage.name(9999, …)` sia `nil`.
La proprietà di sicurezza è l'assenza di una strada, non la presenza di un controllo — un controllo
si può dimenticare di chiamarlo, un tipo no.

**Lezione generale**: una regola scritta in un commento non è una regola, è un'intenzione. Se
qualcosa non deve essere possibile, deve essere **non rappresentabile** nel codice.

### 13.29 Il fade-out, e cosa dice davvero il Link Quality Report

**Fade-out.** Fermarsi a metà forma d'onda lascia un gradino dal valore corrente a zero, e un
gradino è un click: il «piccolo fruscio sulla destra» della pausa. Ora, quando lo stream viene
fermato, vengono emessi **5 ms di rampa** prima di uscire — attraverso lo stesso percorso di tutto
il resto, cioè codificati e accodati, altrimenti non sarebbe un fade ma una soppressione.

Il primo tentativo non arrivava a zero (finiva a 0.185): il guadagno veniva ricalcolato dentro
ogni blocco invece che per frame sull'intero fade. Il self-test lo ha colto, perché la rampa è
aritmetica pura e quindi verificabile senza link.

**Il Link Quality Report, letto per intero.** Questo è il dato che chiude la domanda di fondo:

```
RSSI = -43, {50,75,90}th Noise = {-102,-101,-101} for 20 ch
TxPwr = 8 dBm, ReTx = 0.0%, NAK = 0, NoSync = 0, Flow off = 0
2EDR pkts = 0, 3EDRTx pkts = 0, 1SlotTx = 0, 3SlotTx = 0, 5SlotTx = 0
A2DP Link Adaptive Packet type support = 0
```

Tre conclusioni, tutte contro l'ipotesi «il link è debole»:

1. **Il segnale è ottimo**: −43 dBm con rumore a −101 dBm su 20 canali. È un link corto e pulito.
2. **Non c'è perdita**: `ReTx 0.0%`, `NAK 0`, `NoSync 0`, `Flow off 0`. Il controller non rifiuta
   niente e non ritrasmette niente.
3. **Tutti i contatori di pacchetti sono zero**, compresi `1SlotTx` e `3SlotTx`: il report non
   descrive il traffico A2DP che stiamo generando, quindi `rate = 230 kbps` è una **stima del
   controller**, non una misura. Non va usata come prova di niente.

**Quindi gli stalli non sono radio.** Sono `bluetoothd` che smette di drenare il socket per
100–300 ms. Il `Link Adaptive Packet type support = 0` spiega perché il throughput ha un tetto
(~500 kbps misurato): senza pacchetti 3-slot il costo per byte è più alto. Ma **non spiega gli
stalli**, che sono temporali e non di banda — e il cuscino li assorbe già.

**Cosa resta da fare, se mai**: il packet type si imposta a livello di controller
(`HCISetACLPacketType`), non via AVDTP, e macOS non lo espone. Non è una strada praticabile senza
un kext. Il tetto di ~500 kbps va quindi documentato come limite della macchina, non del
programma — cosa che le note dicevano già, e che questo report conferma con i numeri.

### 13.30 Il README diceva il falso, e la usage anche

Due cose che non erano codice ma erano sbagliate lo stesso.

**Il README** affermava: *«What is missing is the virtual output device (step 3 below), so for
now the audio comes from a file rather than from the Mac's output.»* Era vero il 6 novembre e
falso il 7: il driver esiste, si installa, e `codecblue system` suona l'uscita del Mac. Un README
che sottostima il progetto è meno pericoloso di uno che lo sopravvaluta, ma resta un documento che
mente, e chi lo legge non prova la cosa che funziona.

Corretto anche il resto: il titolo prometteva **aptX, AAC 320 e SBC XQ**, che non esistono. Ora
dice LDAC, e la sezione sul layout dice esplicitamente che gli altri codec sono l'obiettivo e non
una promessa. Un errore che dice «non supportato» costa un minuto; una promessa che non si avvera
costa la fiducia.

**La usage** elencava `audioprobe` come *«DANGEROUS: crashes bluetoothd»*. Non lo è più: dopo il
§13.28 manda **un** messaggio noto, quello che il keeper usa in produzione, e rifiuta di partire
senza una variabile d'ambiente. E mancavano del tutto `agent` e `handlers`.

**E `codecblue` senza argomenti stampava solo la versione.** Tre righe e uscita 0: sembrava un
programma con un comando solo. Ora stampa la usage, che è l'unica cosa che uno vuole vedere
digitando il nome del programma.

**La lezione**: la documentazione invecchia come il codice, ma in silenzio. Il codice che sbaglia
produce un errore; il README che sbaglia produce una persona che non prova.

### 13.31 Il ritardo che si accumula guardando un video

Sintomo: *«se guardo un video lungo si accumula ritardo»*. Non un guasto, una crescita lenta.

**La misura che lo ha localizzato.** Ho aggiunto al report la consegna cumulativa — frame
mandati diviso tempo reale trascorso — e misurato 200 s con un seno:

```
ring: 1984, 1984, 1984, 2048, 1920, 1984, 2048   (stabile)
queue: 0, 0, 16, 0, 0, 16, 0                     (torna a zero)
sent: 100.01% of real time since start
```

I **nostri** buffer non crescono. Quindi il ritardo non è nel ring, non nella coda, non
nell'encoder: è nelle cuffie, che ricevono esattamente il tempo reale e suonano con un cristallo
leggermente diverso. 100 ppm sono 4,8 frame/s, cioè **60 ms ogni dieci minuti**.

**Il primo tentativo, sbagliato.** Ho messo un bias permanente nel `paceSlowdown`, che muove
l'ancora dell'orologio. Risultato: leggevo meno frame di quanti il driver scriveva, e il ritardo
è semplicemente **cambiato indirizzo** — il ring è passato da 2048 a 2750 frame e continuava a
salire. La lezione: rallentare la lettura non corregge niente, sposta il buffer di un dispositivo
più a monte.

**Il secondo, giusto ma inerte.** Resampler con rapporto 0.9999 in uscita. Misurato: la consegna
cumulativa scendeva a 99.95% (corretto!) ma il ring **cresceva** a 11 800 frame, con 124 short
read. Il motivo: un resampler che produce 127.987 frame per blocco deve comunque essere codificato
in blocchi da 128, quindi la frazione va in una fifo che si svuota lentamente e poi salta interi
blocchi — un buco da 128 frame, udibile.

**La causa vera, che era un'altra.** Rileggendo il log del test precedente:

```
[ 77.4] ring 1984 frame  (41 ms)   <- normale
[ 79.4] ring 9600 frame  (200 ms)  <- uno stallo di bluetoothd riempie il ring
[ 81.5] ring 13504 frame (281 ms)
[ 87.6] ring 12096 frame (252 ms)  <- e NON scende più
```

Il ring è rimasto a ~11 800 frame per i **130 secondi successivi**. Il driver scrive all'orologio
del Mac che il link stia dietro o no, quindi ogni stallo di `bluetoothd` (100–300 ms, più volte al
minuto) lascia nel ring quel tanto di audio in più. E leggere esattamente il tempo reale
**conserva** quel surplus per sempre. Ecco il ritardo che si accumula: non è deriva di cristallo,
è un backlog che nessuno smaltisce.

Il salto al presente (`jumpToLive`) c'era già, ma scattava a `target × 2` = 120 ms — cioè a ogni
stallo normale — e **una volta sola** (`loggedCatchUp`), quindi dopo il primo non si ripeteva più.

**La correzione.** Un servo: quando il ring è sopra il target, leggo una frazione di blocco in più
e la comprimo indietro a esattamente un blocco. Il link porta sempre il tempo reale, il surplus
sparisce, e l'unica cosa che cambia è il pitch — 1,5% al massimo, 0,26 di semitono, inudibile su
voce e musica. Il salto di emergenza è stato alzato a `target × 6` (360 ms): resta la rete di
sicurezza, non la correzione normale.

**E il troncamento che rendeva il servo inerte.** `Int(Double(count) * boost)`: a 0,36% di un
blocco da 128 frame l'extra è 0,46, e `Int` lo fa **zero**. Il servo girava e non faceva niente —
misurato: ring fermo a 3400 frame contro un target di 2880 per due minuti. La frazione va
accumulata fra i blocchi, non troncata. C'è un test che lo dice in modo diretto:
`Int(128 * 0.0036) == 0` è il bug, e 1000 blocchi devono produrre il numero giusto di frame extra.

**Non verificato in vivo**: le cuffie si sono spente a metà lavoro (batteria al 20%, poi
disconnesse). Il servo è provato dai test e dal fatto che la consegna cumulativa scende, ma la
prova finale — un video lungo senza ritardo — resta da fare.

### 13.32 I tasti delle cuffie non facevano niente

*«Non riesco ad aumentare e abbassare il volume tramite le cuffie»*. Il codice c'era: `AVCTPHolder`
parsava `PASS THROUGH`, riconosceva `0x41 volume_up` e `0x42 volume_down`, e li passava a
`onKey`. E `onKey`, in `A2DPStreamer`, faceva esattamente questo:

```swift
holder.onKey = { [log] key in log("headphone button: \(key)") }
```

Li scriveva nel log. Nient'altro. Il pulsante arrivava, veniva accettato, e non muoveva niente.

**Cosa mancava, oltre al collegamento:**

- `SET ABSOLUTE VOLUME` (opcode 0x50) rispondeva `NOT IMPLEMENTED`. Alcune cuffie mandano quello
  invece del tasto relativo quando si preme il volume, e un rifiuto significa che il volume non si
  muove. Ora è riconosciuto e accettato.
- Il flag press/release: l'operando ha il bit alto a 1 sul rilascio, e un rilascio non deve far
  scattare il tasto una seconda volta.
- `SystemVolume.step(by:)` e `set(position:)`, che scrivono il valore **scalare** nel device. Non
  il gain: così il driver resta l'unica fonte di verità, il listener lo rilegge, la curva in dB si
  applica come per lo slider, e la barra del menu e i tasti della tastiera seguono.

**Il parsing è una funzione pura ora** (`AVCTPHolder.interpret`), e il motivo è il bug stesso: la
regola viveva dentro `receive`, irraggiungibile da un test, quindi «`SET ABSOLUTE VOLUME` è
rifiutato» non poteva essere visto da nessun controllo. Una regola che non si può testare è una
regola che non si può verificare.

**Non verificato in vivo**, per la stessa ragione: le cuffie sono andate via prima che potessi
premere un tasto. Il parsing è coperto da tre test.

### 13.33 Il volume delle cuffie: quattro frame sbagliati, nessun errore da nessuna parte

*«Sento il volume modificarsi, ma mi aspettavo agisse direttamente sul volume del Mac»*. Il
sospetto era giusto e la causa era peggiore di quanto sembrasse: **nessuno dei frame AVRCP che
mandavamo era valido**, e le cuffie rispondevano `REJECTED` a tutti senza che niente, da nessuna
parte, lo dicesse.

Il modo per scoprirlo è stato loggare **ogni byte** in arrivo e in partenza. Il log ha mostrato
subito due cose:

```
AVRCP in:  10 11 0E 01 48 00 00 19 58 10 00 00 01 03     <- GET CAPABILITIES, ogni 2 s
AVRCP in:  22 11 0E 0A 48 00 00 19 58 00 00 00 01 01     <- 0x0A = REJECTED
```

Le cuffie ci chiedevano le capability ogni due secondi, per sempre, e noi rispondevamo
`NOT IMPLEMENTED`. Non sapevano mai che supportiamo il volume assoluto, quindi non mandavano mai
un evento di volume. E i comandi che mandavamo noi erano rifiutati.

**I quattro errori, tutti nella stessa direzione** (una struttura AV/C indovinata invece che letta):

1. **`GET CAPABILITIES` in uscita**: `00 11 0E 10 00 10 ...` — byte 3 è il *ctype* e `0x10` non è
   un valore che può assumere; mancava del tutto il subunit `0x48` (PANEL), quindi ogni operando
   era un byte in anticipo. Copiato invece dal frame che le cuffie mandano a noi.
2. **`SET ABSOLUTE VOLUME`**: mandato come opcode AV/C nudo (`50 26`). Nell'AVRCP 1.4 è una PDU
   *vendor dependent*, e ogni PDU vendor dependent porta **due byte di lunghezza** dopo un byte
   riservato: `50 00 00 01 26`. Senza, le cuffie leggono il volume come lunghezza.
3. **`REGISTER NOTIFICATION`**: stessa lunghezza mancante. La prima versione mandava
   `31 00 0D 00 00 00 00` e non riceveva **nessuna** risposta — non un rifiuto, il silenzio, che è
   peggio perché sembra che il comando sia andato.
4. **Le risposte**: copiavamo la richiesta e cambiavamo solo il bit C/R, quindi il *ctype* restava
   `CONTROL` in un frame che si dichiarava risposta. Ora si costruisce da zero.

**E poi l'errore nel leggere la risposta**, che è il più insidioso: la notifica di volume è
`12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17`, che è **15 byte**. Il primo parser ne richiedeva
17 e leggeva il byte 16 — quindi scartava *ogni* notifica in silenzio. La guardia era il bug.

**Il risultato, misurato:**

```
AVRCP out: FF 10 11 0E 00 48 00 00 19 58 31 00 00 05 0D 00 00 00 00
AVRCP in:  12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17
           ^ctype 0x0F INTERIM   PDU 0x31   len 2  ev 0x0D  val 0x17
```

La registrazione è accettata, e le cuffie dicono subito a che volume stanno: **18%**. Da lì in poi
ogni pressione dei loro tasti arriva come notifica `CHANGED`, e ogni movimento dello slider del Mac
viene spinto con `SET ABSOLUTE VOLUME`, che ora risponde `ACCEPTED` (`09`).

**La lezione, che è la stessa di §13.28 e vale la pena ripetere**: un protocollo binario non si
indovina. Si legge il frame che l'altro capo manda, e si copia. Ogni volta che ho scritto i byte a
mano ho sbagliato di un byte, e ogni volta il sintomo era *niente* — nessun errore, nessun crash,
solo una funzione che sembrava non esistere.

**Non verificato in vivo**: le cuffie si sono spente (batteria) subito dopo la prima notifica
letta. Il percorso è provato dai test e dalla risposta INTERIM, ma la prova finale — premere i
tasti e vedere lo slider del Mac muoversi — resta da fare.

### 13.34 Il cursore del Mac non si muove: il driver non annuncia il cambio

*«Perché non vedo muoversi il cursore del volume del Mac ora se lo hai sistemato?»*. Perché il
valore cambiava e **nessuno lo annunciava**.

La catena è questa: la notifica AVRCP arriva, `SystemVolume.set(position:)` scrive
`kAudioDevicePropertyVolumeScalar` nel device, il driver la accetta e salva il valore in
`gDriver.volumeBits`. Tutto corretto. Poi il driver manda **una** notifica:

```c
gDriver.host->PropertiesChanged(gDriver.host, kDeviceObjectID, 1, &changed);
```

due errori in una riga:

1. **L'oggetto sbagliato.** In un AudioServerPlugIn il volume non è una proprietà del device: è un
   *control* con un object ID suo (4, 5, 6 — main, left, right). Il volume a livello di device che
   macOS mostra è **sintetizzato dal HAL** leggendo i control, e il HAL li rilegge solo quando un
   control dice di essere cambiato. Notificare il device non fa rileggere niente.
2. **Il selettore sbagliato.** Mandava indietro il selettore appena ricevuto, che è `volm` (la
   proprietà del device). Un level control ha `vlme` (`kAudioLevelControlPropertyScalarValue`).

**La prova che era questo.** Ho registrato listener su ogni combinazione — device, control 4, 5, 6,
dallo stesso processo e da un altro — e scritto il volume in tutti i modi. **Nessun listener è mai
scattato, nemmeno una volta.** Il valore veniva salvato correttamente e nessuno lo annunciava: ogni
client continuava a mostrare il numero vecchio, per sempre.

Ora `volume_notify_changed()` notifica i tre control con `vlme`, e in più il device con `volm` per
sicurezza. Il valore è già corretto da prima; quello che mancava era dirlo.

**La lezione**: in un driver audio, scrivere il valore e annunciarlo sono due operazioni distinte, e
la seconda non è implicita. Un valore che nessuno annuncia è indistinguibile, per ogni client, da un
valore che non è mai cambiato.

### 13.35 I tasti trasporto arrivano e vengono ignorati

Le altre funzionalità delle cuffie, provate una per una con il trace acceso.

**I tasti trasporto funzionano a metà, e la metà che manca è la nostra.** Il 7 novembre, con il
trace acceso, le cuffie hanno mandato:

```
10 11 0E 00 48 7C 46 00     ctype 00 CONTROL, subunit 48 PANEL, opcode 7C PASS THROUGH,
                            operando 46 = PAUSE
FE 12 11 0E 09 48 7C 46 00  la nostra risposta, ctype 09 ACCEPTED
```

Il tasto arriva, lo riconosciamo (`headphone button: pause`), rispondiamo ACCEPTED. Poi:

```swift
default:
    break  // play/pause/next are the app's business, not ours
```

Cioè: lo accettiamo e non facciamo niente. Dal punto di vista delle cuffie il comando è andato a
buon fine, quindi non riprovano e non segnalano niente. **È il tipo di bug peggiore: una risposta
positiva a un comando che non viene eseguito.**

Per agire serve inoltrare una media key al sistema (`NSEvent.otherEvent(.systemDefined, subtype: 8)`
e `cgEvent.post`), e questo richiede il permesso di Accessibilità. Misurato: `AXIsProcessTrusted()`
è **false** per il processo, quindi l'evento verrebbe scartato in silenzio — esattamente lo stesso
sintomo di adesso, ma con più codice. Va chiesto il permesso, e va deciso se è una cosa che vogliamo
imporre all'utente.

**Le altre funzionalità, stato:**

| funzione | stato |
|---|---|
| volume, Mac → cuffie | ✅ verificato (`SET ABSOLUTE VOLUME`, ACCEPTED) |
| volume, cuffie → Mac | ✅ verificato (7 pressioni, cursore segue) |
| play / pausa / next / previous | ⚠️ arrivano, riconosciuti, accettati, **ignorati** |
| batteria | ✅ riportata (`headphone battery: 100%`) |
| codec / sample rate | ✅ negoziati, SEID letto dal device |
| chiamate (HFP) | ✅ canale tenuto, non usato per l'audio |
| multi-point | ❌ non testabile con un solo paio |

**Una cosa che ho visto e non ho toccato**: con nessuna app che scrive nel device, il ring si
riempie di silenzio (46 000 frame) e il nostro servo lo drena lentamente (16 000 dopo 100 s). Non è
un difetto — è il driver che scrive silenzio perché il device è selezionato — ma significa che il
`drainBoost` lavora anche quando non c'è niente da sentire. Da verificare che non introduca un
ritardo percepibile alla prima app che scrive.

### 13.36 Il permesso di Accessibilità va a un programma, non a un terminale

*«Mi chiede di abilitare il terminale, non codecblue. Forse ha senso che sia un programmino a
parte?»*. Sì, e la ragione è più forte di quanto sembri.

macOS concede il permesso di Accessibilità **a un programma, per nome**, e il nome è quello del
binario che ha chiamato `AXIsProcessTrustedWithOptions`. Se a chiamarlo è `codecblue` lanciato da un
terminale, il nome che compare nelle Impostazioni è **il terminale**. Concedere quello significa
dare a *qualsiasi* programma lanciato in quel terminale il diritto di sintetizzare eventi di
tastiera — per sempre, per ogni `ls`. È un permesso enormemente più ampio di quello che serve a
questo caso, ed è giusto che la gente lo rifiuti.

Quindi il privilegio vive nel programma più piccolo che può averlo: `codecblue-keys`, un binario
che legge una riga da stdin e posta una media key. Niente rete, niente file, nessun argomento che
faccia altro. Si concede l'Accessibilità a **quello**, e a nient'altro.

**Il protocollo** è una riga per comando, una riga per risposta:

```
play|pause|toggle|next|previous|fast|rewind|status|quit
ok <comando> | denied | unknown <riga>
```

`codecblue` ne avvia uno all'inizio dello stream e lo tiene per la sessione: la finestra di
permesso compare una volta e le pressioni successive sono immediate. Avviarne uno per pressione
farebbe ricomparire la finestra ogni volta.

**E la risposta ai tasti ora dipende da cosa succede.** Prima era:

```swift
case .key(let name):
    onKey?(name)
    reply[3] = 0x09  // ACCEPTED
```

cioè ACCEPTED sempre, anche quando `onKey` non faceva niente. Ora `onKey` restituisce `Bool` e la
risposta è `0x09` se il tasto è stato gestito, `0x08` NOT IMPLEMENTED se no. **Un tasto rifiutato è
meglio di una bugia**: le cuffie sanno che non lo gestiamo e possono ripiegare, invece di credere
che sia andata e non riprovare mai.

**Non verificato in vivo**: manca il permesso. `.build/debug/codecblue-keys --status` risponde
`not trusted`, e `--request` fa comparire la richiesta. Il percorso è provato dai test e dalla
logica, ma la prova vera — premere play e vedere la musica fermarsi — richiede che tu conceda il
permesso a `codecblue-keys`.

### 13.37 Il canale di controllo, e due bug che ha subito trovato

Prima di scrivere qualunque interfaccia, un modo per **parlare con lo stream mentre suona**. Senza,
cambiare la qualità significa fermare, riscrivere la riga di comando e ripartire: diversi secondi di
silenzio, che è esattamente il contrario di quello che serve per una impostazione che vuoi provare
ascoltando.

Un socket unix in `/tmp/codecblue-control`, un comando per riga, una risposta per riga. Un
programma esterno può parlarci anche con `nc -U`, e un client bacato non può corrompere lo stato
dello stream.

```
$ codecblue status
adapt          on
battery        100
quality        MQ
ring_frames    1920
ring_ms        40
skips          0
volume         56

$ codecblue quality SQ
ok quality=SQ
adapt=off
```

**Il cambio di qualità funziona senza rinnegoziazione**: libldac cambia la dimensione dei frame che
produce, e ogni pacchetto porta il proprio `frameCount`, quindi il flusso continua. È la ragione per
cui `encoder.quality` era già una `var` — l'adattatore la cambiava da solo da giorni.

**Bug 1, trovato subito: la coda.** Cambiando MQ → SQ con la coda a 240 ms, il risultato era 48–60%
di audio scartato e il ring a un secondo pieno. La coda conteneva pacchetti al vecchio livello, il
link non li smaltiva, `!queue.hasRoom` restava vero e il ciclo buttava via audio per recuperare. Ora
al cambio la coda si svuota: costa al massimo il cuscino (60 ms) ed è finita subito, mentre tenerla
costa secondi di distorsione.

**Bug 2, più profondo: lo skip non avvisava nessuno.** Quando il link non regge e il ciclo salta
audio, avanza l'**orologio** senza leggere. Il driver continuava a scrivere, e il ring cresceva
esattamente di quanto era stato saltato — misurato: da 37 ms a 1000 ms in una finestra, e non
tornava più giù perché nessuno lo leggeva. Ora `onSkip` dice al lettore di scartare la stessa
quantità dal ring (`SharedRing.discard`), che non è `jumpToLive`: quello butta via tutto, questo
butta via esattamente quello che era già perso.

Dopo la correzione, lo stesso cambio MQ → SQ su un link da 500 kbps: ring 37 → 71 ms, **zero
skip**. La qualità che il link non regge ora costa audio scartato (inevitabile) ma non ritardo.

**Il resto del piano** — l'app menu bar — è un client di questo canale. Farla prima avrebbe
significato o un secondo programma che duplica la logica, o un'app che sa solo avviare e fermare
processi.

### 13.38 L'app menu bar: un client, non un secondo programma

L'app che c'era era del prototipo Python (`notes/archive/python-prototype-2026-11-05.tar.gz`,
`app/Sources/LDACBar/`, 716 righe), e in questo repo `Sources/CodecBlue/` non è mai esistito —
`git log --all` su quel percorso è vuoto. Non è stata reintrodotta: è la prima.

**Il disegno**, e la ragione per cui è venuto dopo il canale di controllo e non prima: l'app non
contiene codice audio. Tutto quello che mostra viene da due posti — l'elenco delle cuffie note a
macOS, e il canale di controllo di uno stream in corso — e tutto quello che fa è una di tre cose:
scrivere un LaunchAgent, caricarlo, o mandare una riga su quel canale. Farla prima avrebbe
significato o un secondo programma che duplica la logica, o un'app che sa solo avviare e fermare
processi (senza il cambio di qualità a caldo, che è l'unica cosa che valeva la pena metterci).

**Chi tiene in vita lo stream: launchd, non l'app.** `KeepAlive` è acceso, quindi se le cuffie si
spengono il processo esce e launchd lo riavvia ogni 5 secondi finché non tornano. Chiudere la
finestra non ferma la musica, e riaprirla ritrova lo stream in corso. Fermarlo deliberatamente
significa `unload`, perché altrimenti `KeepAlive` lo farebbe ripartire — il comportamento giusto
per un crash, sbagliato per una scelta.

**Due dettagli che hanno richiesto attenzione:**

- `launchctl load` su un label già caricato **non fa niente**. Dopo aver riscritto il plist per un
  altro paio di cuffie, caricare e basta lascerebbe in esecuzione l'indirizzo vecchio. Quindi
  `load()` scarica prima, e c'è un test che lo verifica leggendo il corpo della funzione — perché è
  una regola che nessun tipo può rendere impossibile.
- Il percorso nel plist deve essere `.build/debug/codecblue`, non `.build/out/Products/Debug/…`
  (che `swift package clean` cancella). La stessa funzione che risolve il percorso è ora usata dal
  CLI e dall'app: un errore, un posto.

**L'elenco delle cuffie** viene da `system_profiler`, ed è l'unico modo pubblico: le XPC di
bluetoothd si interrogano per indirizzo ma non si enumerano, e i framework privati che lo farebbero
sono esattamente quelli che uccidono bluetoothd (§13.28). Il parser traccia la **sezione**
(`Connected:` / `Not Connected:`) invece di cercare per stringa, perché `grep` su tutto il file dice
che le cuffie ci sono anche quando sono spente — l'errore che era già costato una serata (§13.1).
C'è un test con l'output vero, sezione compresa.

**Il bundle** lo costruisce `scripts/build-menu-app.sh`: senza `Info.plist` con `LSUIElement` l'app
compare nel Dock invece che solo nella barra. Firma ad-hoc, perché macOS rifiuta un bundle il cui
eseguibile è cambiato dopo la creazione, e il permesso di Accessibilità è ricordato per firma.

**Non verificato in vivo**: le cuffie sono spente (batteria al 20%, poi nel case). L'app parte,
l'icona c'è, l'elenco le mostra entrambe come `off`. La prova vera — sceglierle, premere Start,
sentire l'audio — richiede che siano accese.

### 13.39 Bitrate e frequenza: cosa si può scegliere davvero, e cosa no

*«BlueMoon o Lucid fanno scegliere anche i kbps e la frequenza. Possiamo farlo anche noi?»*.
Risposta onesta: **la frequenza sì, i kbps solo a tre livelli** — e vale la pena sapere perché.

**Il bitrate non è un numero continuo.** LDAC ha tre soli livelli, e dipendono dalla frequenza:

```
        | 44.1 / 88.2 kHz | 48 / 96 kHz
HQ      |     909 kbps    |   990 kbps
SQ      |     606 kbps    |   660 kbps
MQ      |     303 kbps    |   330 kbps
```

Non esiste un quarto valore: `ldacBT_set_eqmid` prende un EQMID, non un bitrate. Misurato con
`codecblue abr` su questa build: `HQ 990`, `SQ 660`, `MQ 330` a 48 kHz, e **rifiutati** gli EQMID 3
e 4 che la tabella ABR di Sony nomina (492 e 396 kbps a 96 kHz). Quindi i "kbps" che un'app mostra
sono quei tre numeri, non uno slider.

**ABR non è disponibile in questa build.** `LDACBT_EQMID_ABR` è `0x7F` e l'header lo riserva, ma
`ldacBT_init_handle_encode` lo rifiuta. Sony distribuisce l'ABR come **modulo separato**
(`abr/src/ldacBT_abr.c`), che ho incluso nel target — e che però richiede una chiamata periodica a
`ldac_ABR_Proc(handle, abrHandle, TxQueueDepth, flagEnable)` per adattare il livello alla coda.
Il nostro `BitrateAdapter` fa già esattamente questo, con la nostra logica. **Non serve ABR**: la
scelta adattiva c'è già ed è nostra, quindi non c'è niente da guadagnare nell'usare la loro.

**La frequenza invece si può scegliere**, e ha senso: 44.1 kHz è il rate nativo del 99% della
musica, quindi chiedere 48 kHz a un brano a 44.1 significa un resampling che non aggiunge nulla.
Oggi il codice chiede sempre 48 kHz (`setUp(sampleRate: ring.sampleRate)`). Il device virtuale è
fisso a 48 kHz (`kSampleRate` nel driver), quindi per usare 44.1 servirebbe o un resampler in
ingresso (che c'è già, ma al contrario) o rendere il rate del driver configurabile.

**Cosa ho fatto quindi:**
- `codecblue abr` misura e riporta cosa questa build accetta — un fatto, non una supposizione;
- `LDACEncoder.Level` elenca tutti e cinque gli EQMID, e `LDACEncoder.levels()` dice quali
  funzionano davvero;
- due bug gravi trovati proprio da questo comando, vedi sotto.

**Bug: doppio free.** `ldacBT_free_handle` su un handle mai chiuso fa **segfault**. E l'init
designato liberava l'handle nel ramo di errore, ma l'handle era già in una proprietà stored: un
init che lancia esegue comunque `deinit`, che chiude e libera di nuovo. Due free, crash. Trovato
perché `codecblue abr` provava apposta EQMID che falliscono — cioè il primo codice che abbia mai
esercitato quel ramo in tre giorni.

**La lezione**: un ramo di errore che nessuno ha mai eseguito non è codice testato. Il modo per
eseguirlo è chiedere al sistema cosa rifiuta, non fidarsi di cosa il sistema dovrebbe accettare.

### 13.40 La frequenza ora è una scelta, e un bug nel driver che nessuno vedeva

Il rate del device virtuale era una costante (`kSampleRate 48000.0`). Ora è un campo nel ring:
`codecblue rate 44100` lo scrive, il driver lo legge quando `coreaudiod` lo carica.

**Perché non si può cambiare a caldo**, e perché va bene così: un device che cambia rate sotto i
client di colpo rompe ogni app che lo ha già aperto. Quindi la scelta si scrive, e si applica con
`sudo killall coreaudiod` — una volta, non a ogni brano. Il messaggio lo dice.

**Il rate è un valore, letto in un posto.** Tutto quello che prima leggeva `kSampleRate` — il
formato offerto all'host, l'orologio, il periodo dello zero timestamp — legge `ring_sample_rate()`.
Devono coincidere: un formato a 44.1 con un orologio a 48 suonerebbe tutto l'8,8% veloce. Il valore
è limitato a 44100…96000 perché il ring è dimensionato per 96 kHz; oltre, si svuoterebbe.

**E il rate che lo stream chiede è quello del device.** Era già `setUp(sampleRate: ring.sampleRate)`,
quindi con il device a 44.1 il resampler diventa identità e i campioni passano intatti — nessun
resampling per un brano che era già a 44.1. C'è un test che lo dice in modo diretto: a rapporto 1
i campioni devono uscire identici, non interpolati.

**Il bug nel driver.** Ricompilando è comparso un warning che era passato inosservato:

```
warning: incompatible pointer types passing 'AudioObjectID *' to parameter of type
         'const AudioObjectPropertyAddress *'
```

Era la notifica del volume che avevo scritto il giorno prima: passava un array di **object ID** dove
la funzione vuole un array di **indirizzi di proprietà**, con count 3. Cioè diceva all'host «sono
cambiate tre proprietà consecutive del device», e l'host leggeva tre ID come se fossero indirizzi.
Il cursore funzionava lo stesso — perché c'era anche la notifica corretta sul device — ma era una
bomba a orologeria: un host che avesse onorato quella lista avrebbe letto memoria arbitraria.

**La lezione**: un warning del compilatore su un tipo di puntatore, in codice che "funziona", è un
bug che non si è ancora manifestato. Il volume funzionava per caso, non per costruzione.

### 13.41 Installare non è copiare un file

*«Con l'install installo sia il driver che il programma?»*. No — `scripts/build-driver.sh
--install` installa **solo il driver**. È una domanda che ha esposto un problema reale: il
progetto ha tre pezzi con tre cicli di vita diversi, e nessun comando li metteva insieme.

| Dove | Cosa | Serve sudo | Quando si aggiorna |
|---|---|---|---|
| `/Library/Audio/Plug-Ins/HAL/CodecBlueDriver.driver` | il device virtuale | sì | a ogni ricompilazione, perché `coreaudiod` tiene in memoria la copia vecchia |
| `~/Applications/CodecBlue/` | `codecblue`, `codecblue-keys`, `CodecBlue.app` | no | a ogni `swift build` |
| `~/Library/LaunchAgents/com.codecblue.system.plist` | l'agente che alimenta il device | no | quando scegli un paio di cuffie |

**Perché è pericoloso installarne solo uno.** Il driver pubblica un device. Se nessuno lo alimenta,
ogni app ci suona dentro e il risultato è **silenzio senza nessun errore da nessuna parte** — il
device è selezionato, il volume è alzato, e non si sente niente. È già costato una serata (§13.1).

`scripts/install.sh` fa tutti e tre, chiede `sudo` una volta, e `--uninstall` li toglie tutti.

**Un bug trovato scrivendolo.** `LaunchAgent.resolveExecutable` cercava `.build/debug/codecblue`
risalendo dalla posizione dell'eseguibile. Dopo l'installazione il CLI vive in
`~/Applications/CodecBlue/`, e risalendo da lì non c'è nessun `.build`: l'agente avrebbe puntato a
un percorso che `swift package clean` cancella. Ora la copia installata **vince** se esiste, e il
percorso di build è il ripiego. C'è un test che verifica che il risultato non contenga mai
`/.build/out/`.

**La lezione**: un programma con più di un artefatto installabile ha bisogno di un comando che li
installi tutti, o qualcuno ne installerà uno solo. E il sintomo di quello sbagliato è il silenzio,
che è il sintomo peggiore possibile.

### 13.42 Qualità e latenza regolabili mentre suona

Le due impostazioni che contano davvero, e la differenza fra loro.

**Qualità** era già regolabile dal §13.37, ma mancava una cosa: il livello scelto a mano deve
**spegnere l'adattatore**. Un livello che l'utente sceglie e che l'adattatore poi sovrascrive è
peggio di nessuna scelta. Ora `quality` risponde `adapt=off` e lo dice.

**Latenza** era una costante decisa all'avvio. Ora `codecblue cushion 40` la cambia mentre l'audio
suona, e nel menu ci sono quattro valori (30 / 60 / 100 / 150 ms).

**Il cuscino *è* la latenza.** È l'audio tenuto fra il driver e il socket: ogni millisecondo è un
millisecondo che l'ascoltatore sente in ritardo. Ma non è un tetto — la coda si allarga da sola
quando il link stalla, perché un cuscino che non può crescere è un cuscino che schiocca. Quindi
`cushion 30` significa «30 ms quando il link lo permette», non «30 sempre». Lo dice anche il menu.

**Il retune è delicato**, e ha richiesto attenzione: una coda che sta tenendo 120 ms perché il link
li ha chiesti non va abbassata a 40 buttando via quello che ha — sarebbe uno skip nell'istante
esatto in cui l'utente chiede meno ritardo. Il budget nuovo viene **limitato** nel nuovo intervallo
e poi scende da solo attraverso `relax()`, come qualsiasi altro surplus. Tre test lo verificano,
compreso il caso in cui il chiamante passa floor e ceiling al contrario (che produrrebbe
`maxFrames = 0` e uno scarto a ogni append).

**E lo stato ora riporta la latenza vera**, non solo il cuscino:

```
$ codecblue status
cushion_ms     60
latency_ms     71
```

`latency_ms` è cuscino + quello che aspetta nel ring. Riportare solo il cuscino sottostimava di
tutto il tempo che i pacchetti già consegnati passano in volo — che è dove stanno i millisecondi
che non si vedono.

**Non verificato in vivo**: le cuffie sono spente (`off` per entrambi i paia). Il cambio di cuscino
è coperto dai test e il percorso è lo stesso di `quality`, che è verificato — ma la prova che conta,
ascoltare a 30 ms e sentire se regge, richiede le cuffie accese.

### 13.43 Quattro difetti che l'ascolto ha trovato, e nessun test

Provati in vivo con le cuffie accese. Quattro sintomi, quattro cause diverse, tutte dello stesso
tipo: **un controllo che esiste nel nostro codice e in nessun posto dove il sistema lo veda**.

#### Il volume troppo basso: due attenuazioni per un solo slider

`volume: slider 56% -> gain 23.7%` e contemporaneamente `SET ABSOLUTE VOLUME 0x7F` alle cuffie.
Lo slider finiva **due volte**: moltiplicato sui campioni (curva in dB, −28 dB al 56%) e mandato
giù per il link come attenuazione delle cuffie, che attenuavano di nuovo. Totale circa −34 dB.

Il sintomo riferito — «sono costretto ad arrivare a metà per sentire qualcosa» — è esattamente
questo: metà slider = −28 dB qui, e le cuffie aggiungono il loro.

Ora le cuffie stanno a **fondo scala** e l'attenuazione è tutta nostra, dove è istantanea (una
moltiplicazione prima dell'encoder) e non dipende dall'AVRCP essere vivo. Mandare `1.0` invece di
niente conta: un paio lasciato al 20% da una sessione precedente resterebbe piano per ragioni che
nessun processo può vedere.

#### Il mute non arrivava: il flag c'era, il controllo no

Il driver memorizzava `muted` e rispondeva a `kAudioBooleanControlPropertyValue`, ma **nessun
oggetto nella sua control list era un boolean control**. La HAL sintetizza il mute di device *dal
controllo*, quindi non c'era niente da sintetizzare: il pulsante mute del Mac non aveva dove
scrivere, e nelle cuffie l'audio continuava.

Aggiunto `kMuteControlID = 7`, classe `kAudioMuteControlClassID`, quarto elemento nella lista, e la
notifica ora parte dal controllo (stesso bug del volume: `PropertiesChanged` sul device non fa
scattare nessun listener).

`SystemVolume.readMute` ora legge il device e, se non risponde, scende ai controlli: i due possono
divergere — è uno stato reale — e leggerne uno solo rende il mute silenziosamente inerte.

#### Il doppio click non metteva in pausa: era un toggle

`NX_KEYTYPE_PLAY` è un **toggle**: significa «inverti quello che sta suonando». Quindi `play` e
`pause` diventavano la stessa pressione, e un doppio click (PAUSE poi PLAY) commutava due volte —
che si annulla contro un player già nello stato chiesto dalla prima pressione.

`codecblue-keys` ora usa `MRMediaRemoteSendCommand` (framework privato, caricato a runtime) con
comandi **espliciti**: `kMRPlay` = 0, `kMRPause` = 1. La HID key resta come ripiego se il framework
non si carica, e `status` dice quale dei due sta usando: `ok status trusted, mediaremote`.

#### La latenza che si accumulava: un budget contato due volte

Misurato su un video lungo: la coda al suo tetto di 240 ms **e** il ring fermo a 10 000–12 300
frame, altri 210–255 ms. I due ritardi si sommano, quindi l'ascoltatore sentiva circa mezzo secondo
mentre ogni numero nel report stava dentro il proprio budget. Ci stavano davvero: il ring era stato
istruito a tenere `cushionSeconds.value`, che è la profondità **della coda**.

Il ring non è un cuscino per il link: quando il link stalla si riempie la coda, l'encoder si ferma,
e il ring si riempie di conseguenza. Drenarlo alla profondità della coda tiene una seconda copia del
ritardo che la coda già possiede. Ora insegue `ringTarget` (40 ms), che è il jitter dello scrittore.

Verifica su 90 s di audio continuo: ring fra 1738 e 2081 frame (**36–43 ms**), stabile, zero skip,
`latency_ms` 99–101.

**Le piccole interruzioni restano**, e non sono di questo strato: sono gli stalli del link (100–280
ms, più volte al minuto) che riempiono la coda al tetto e fanno scartare il 12–60% dell'audio per
una finestra. Il cuscino si allarga fino a 310 ms per assorbirli. La causa a monte è che il link
porta ~330–430 kbps contro i 990 dell'HQ: il controller non negozia pacchetti 3-slot.

### 13.44 Il volume: tre tentativi, e cosa ha insegnato ognuno

Il volume è l'unico punto del progetto dove ogni correzione ha rotto qualcos'altro. Tre giri, e
vale la pena tenerli tutti perché il terzo si capisce solo dai primi due.

**Giro 1 — due attenuazioni.** Lo slider finiva moltiplicato sui campioni *e* mandato giù per il
link. Al 56%: −28 dB qui, più l'attenuazione delle cuffie. Sintomo: «devo arrivare a metà per
sentire qualcosa».

**Giro 2 — tutto qui, cuffie a fondo scala.** Sbagliato per una ragione che il log ha reso ovvia in
un minuto: mandare `1.0` fa **riportare** alle cuffie 100%, quel report è indistinguibile da un dito
sul loro tasto volume, e lo slider è **saltato a 100% da solo** — e non si è più mosso:

```
[777.252] headphone volume: absolute 100%
[777.257] headphone volume: slider 100% -> gain 100.0%
```

Un controllo che si scrive da solo è peggio di uno silenzioso. Sintomo riferito: «aumentando e
abbassando il volume non si muove lo slider del mac».

**Giro 3 — l'attenuazione va alle cuffie, e l'eco va riconosciuto.** Lo slider muove le cuffie; il
processo moltiplica per niente. Ma l'eco resta, e va distinto da una pressione vera. Due criteri,
entrambi necessari:

- **valore**, memorizzato *quantizzato* come è partito (7 bit): l'eco torna identico al bit;
- **tempo**, entro 400 ms. Il round trip AVRCP misurato su queste cuffie è 15–60 ms, a volte 180
  sotto carico.

Solo il valore non basta: una pressione delle cuffie muove di **1/127 = 0.0079**, che è esattamente
la stessa grandezza dell'errore di quantizzazione di un eco. La prima versione usava una tolleranza
di un passo intero e **inghiottiva ogni pressione fatta subito dopo un push**. Ora la tolleranza è
0.002, un quarto di passo: assorbe il giro float attraverso i 7 bit, è quattro volte più stretta di
una pressione.

**Il gain ora è solo il mute**, applicato come zero: istantaneo, e funziona anche se il link è
occupato.

### 13.45 Il mute, e perché il driver andava reinstallato

Il controllo esisteva nel driver dal §13.43 ma **il driver installato era ancora quello vecchio**:
`/Library/Audio/Plug-Ins/HAL/CodecBlueDriver.driver` era delle 11:13, il compilato delle 10:48, e
`codecblue` in esecuzione delle 10:59 — cioè **prima** del commit. Tre pezzi, tre età diverse, e
nessuno dei tre lo diceva.

Verificato con il driver nuovo: `mute set to 1` → il device risponde `1`; `mute set to 0` → `0`.
Prima il mute a livello device era `NOT SUPPORTED`, che è il motivo per cui il pulsante del Mac non
faceva niente.

### 13.46 `sudo ./scripts/install.sh` avvelenava la build

Trovato per caso, ed è un difetto dello strumento, non del codice: lanciare `install.sh` con `sudo`
faceva compilare **tutto** come root, quindi `.build/out`, `.build/CodecBlueMenu.app` e
`~/Applications/CodecBlue/CodecBlue.app` restavano di root. La build successiva moriva con

```
error opening '…/CodecBlueCore.abi.json' for output: Operation not permitted
```

che sembra un toolchain rotto e non lo è. Corretto in due punti:

- `install.sh` **rifiuta** di girare come root e lo spiega; chiede sudo da sé, solo per il driver;
- `build-menu-app.sh` ripiega su `.build/menu-app-<uid>.app` se il bundle è di un altro utente, e
  `install.sh` chiede allo script **dove** ha costruito invece di indovinare.

### 13.47 Il tasto play/pausa: cosa manca davvero

`PASS THROUGH` **non arriva**. Nel trace di una sessione intera i frame in ingresso sono solo due
tipi: `0x00` (GET CAPABILITIES, 60 volte) e `0x19` (notifica di volume, 76 volte). Zero `0x7C`.

Nella sessione precedente un `next` era arrivato una volta sola. Quindi il tasto non è rotto nel
nostro codice: **le cuffie non lo mandano**, o lo mandano su un canale che non stiamo ascoltando.
La correzione di `codecblue-keys` (comandi espliciti invece del toggle) resta giusta e verificata
con `ok status trusted, mediaremote`, ma non può essere provata finché il frame non arriva.

Candidati da verificare, in ordine: AVRCP browsing channel (PSM 0x001B) separato; le cuffie che
mandano i tasti solo quando credono che siamo un player (serve `REGISTER NOTIFICATION` per
`EVENT_PLAY_STATUS_CHANGED`, non solo per il volume); il doppio click che su queste Huawei è
configurato nell'app come gesto locale e non come AVRCP.

### 13.48 «Ho fatto partire un video ma non si sente nulla»: il permesso Bluetooth

Un pomeriggio per trovarlo, una riga per risolverlo, e il sintomo peggiore possibile: **nessun
errore che somigli a un problema di permessi**.

`codecblue` non usa CoreBluetooth. Parla a bluetoothd sul canale XPC **classico**, quello di
IOBluetooth, e da lì si prende il link delle cuffie. Quel canale è soggetto al permesso Bluetooth
(`kTCCServiceBluetoothAlways`) esattamente come CoreBluetooth — ma **niente, dentro quel canale, lo
chiede mai**. Solo CoreBluetooth lo chiede.

Quindi il permesso andava a chi lo chiedeva: lanciato da terminale, macOS chiedeva a nome del
terminale, e funzionava. Lanciato da **launchd** — che è come l'app tiene in vita lo stream —
nessuno chiedeva niente, e bluetoothd rispondeva:

```
TCC approval status for session <private>: 1
Sending 'state updated' event with state "Unsupported"
```

`Unsupported` si legge come «questo Mac non ha il Bluetooth», e lo stream moriva in un ciclo di
riavvii con `bluetoothd did not answer: check-in / power state`. La stessa label, lo stesso
binario, gli stessi argomenti: da terminale `status: 2` e `state "On"`, sotto launchd `status: 1` e
`Unsupported`, quattro volte per parte.

**Il fix**: chiedere il permesso da dentro il processo, così va a `codecblue` e non a chi l'ha
lanciato. Creare un `CBCentralManager` *è* la richiesta — non serve usarlo per niente altro. Il
`BluetoothAuthorization` lo fa all'inizio di `playSystem`, prima di toccare bluetoothd.

**La parte controintuitiva**: non bisogna aspettare il delegate. Misurato: sotto launchd il
callback **non arriva mai** — un binario nudo non ha un run loop per la main queue — eppure
l'approvazione passa da 1 a 2 e il canale classico funziona. La prima versione aspettava 8 secondi
per niente e poi falliva lo stesso; ora aspetta 2 e va avanti comunque, dicendo `asked`.

Verificato: sotto launchd, con il warm-up, `state "On"` e lo stream parte.

Seconda metà del fix: `LimitLoadToSessionType = Aqua` nel LaunchAgent, perché il permesso vive
nella sessione GUI e l'agente deve partire lì.

### 13.49 Il tasto play/pausa: il frame arriva, manca il destinatario

Terzo tentativo, e il primo che può spiegarsi. La catena funziona tutta:

```
[ 17.476] headphone button: pause
[ 17.477] headphone button pause: toggled play/pause
```

Il frame arriva (`PASS THROUGH` 0x46), il helper è `trusted`, la HID key viene postata. **Manca il
destinatario.**

`mediaremoted` instrada le media key — anche quelle HID — al **client Now Playing registrato**. Senza
un client non c'è destinazione: la key viene postata, nessuno si lamenta, e non succede niente.
Misurato su questo Mac:

```
$ MRMediaRemoteGetNowPlayingApplicationPID
nowPlayingPID=0        ← con un video che suonava nel browser
```

**La prova che il percorso è giusto**: un `AVAudioPlayer` minimo che si registra da solo riceve la
key, due volte di fila:

```
REMOTE: toggle
REMOTE: toggle
```

Quindi `codecblue-keys` ora **dice** quando non c'è destinazione:

```
ok toggle but no now-playing client (pid 0): the key has no destination
```

e lo stream lo riporta nel suo log, dove l'ascoltatore lo può leggere:

> media keys: the button was read and the key posted, but macOS has no now-playing client to send
> it to, so nothing can pause. This is the player's decision, not ours.

**Cosa resta da capire**: perché Chrome e Safari non si registrano su questa macchina. Non è una
cosa che possiamo correggere da qui — è il player che decide di esporsi ai tasti multimediali — ma
almeno ora il log lo dice invece di far sembrare rotto un tasto che funziona.

Nota sul primo tentativo, per memoria: mandare `PAUSE` esplicito funzionava **una volta sola**
(«la prima volta il doppio clic ha messo pausa, ora non funziona più») perché il secondo gesto
chiedeva a un player già in pausa di mettersi in pausa. Il toggle non ha questo problema, e resta
la scelta giusta.

### 13.50 «Riprendi»: quattro cose che il codice diceva e il log no

Ripresa del progetto dopo il commit `fa968f0`. Le note erano aggiornate; il codice aveva quattro
punti in cui una cosa funzionava per caso, o non si vedeva affatto.

#### Il log incollato era quello del §3, non un guasto nuovo

Il log con `streaming: 86 kbps, 15 packets/s, queue 351 (max 351), HQ 990 kbps` è la **prima
esecuzione del 2026-11-05**, citata pari pari al §3: quel formato di riga è stato sostituito al
commit `505a86a` e non esiste più in nessuna versione del repo (`git log -S` su tutte e 19 le
revisioni). Le altre righe — `headphones connected to macOS: taking the link over in place`,
`configured LDAC 48000 Hz stereo on SEID 34`, `playing in LDAC HQ` — sono invece **identiche** al
codice attuale, il che rende il log un ibrido: la testa è di oggi, le righe `streaming:` sono
quelle di tre giorni fa. Non è un guasto da diagnosticare, ed è bene saperlo prima di cercarne uno.

#### La Link Quality Mode si accendeva, ma non si sapeva

`status` non riportava la LQM: l'unica traccia era una riga di log all'avvio, che nessuno
aggiornava. Ora `codecblue status` risponde `link_quality=on|off|unknown`, e il menu bar la mostra
accanto alla latenza. È il numero che separa 50 kbps da 500, e un ronzio inspiegabile deve poter
dire da solo se è quello.

#### Il keeper si confermava a un ritmo più lento del proprio

`AudioStreamKeeper` chiamava `deviceIsRegistered()` — che lancia `log show` — **a ogni tentativo**,
cioè ogni secondo. Misurato su questo Mac: `log show --last 30s` e `--last 30m` costano lo stesso
**1,1 s** (il prezzo è il processo e l'archivio, non le righe). Quindi il ciclo da 1 s ne durava
1,9, e passava metà della vita bloccato in una pipe mentre l'audio aveva bisogno della CPU.

Ora l'invio e la conferma sono due task: il messaggio `BTAudioMsgIdStartAudio` parte ogni secondo
senza aspettare nessuno, e la lettura del log va per conto suo ogni 2 s. La conferma non è sul
percorso che fa funzionare l'audio — serve a dirlo, non a farlo — e adesso costa quello che deve.

#### L'UUID del device poteva essere quello di un telefono

`CBDeviceUUID.find` prendeva l'ultima riga `CBDevice … A2DP` del log. Ma bluetoothd stampa una
riga `CBDevice` per **ogni dispositivo che si annuncia nelle vicinanze**: misurate undici in trenta
minuti su questo Mac, nessuna delle nostre. Con due paia di cuffie in casa, o un telefono in
AirDrop, l'UUID poteva essere quello sbagliato — e con l'UUID sbagliato il canale audio risponde
`No device found for uid` e la LQM resta spenta, in silenzio.

Aggiunto `CBDeviceUUID.findRegistered`: legge la riga `Register audio device 40:DC:A5:XX:XX:XX-tacl`
— quella che dice *per quale indirizzo* bluetoothd ha pubblicato un device — e prende l'UUID
dell'ultima riga `CBDevice … A2DP` vista fino a lì. `find` resta come ripiego per il caso in cui la
registrazione non ci sia ancora. Cinque test nuovi coprono: la registrazione, la cancellazione, la
ri-registrazione, il telefono in mezzo, e un indirizzo che è solo una sottostringa.

#### Il check-in che non rispondeva

`bluetoothd did not answer: check-in / power state` capitava e poi si risolveva da solo al
tentativo successivo. La risposta arriva quando bluetoothd decide, e cinque secondi non bastano
sempre su una macchina che ha appena svegliato un daemon e un controller. `start()` ora ritenta su
una **connessione nuova** (tre tentativi, mezzo secondo fra l'uno e l'altro): una connessione
rimasta a metà non è uno stato da conservare, e riusarla è il modo di ottenere un errore diverso
ogni volta. Se invece bluetoothd ha detto esplicitamente che la radio è spenta, non si ritenta:
`ClassicXPCError.powerOff` chiude subito, invece di trasformare «Bluetooth spento» in un'attesa di
sedici secondi.

#### Le scelte dell'utente ora sopravvivono al riavvio dell'agente

`AppModel.start()` scriveva `--quality MQ` nel plist, sempre: la qualità scelta nel menu e il
cuscino duravano fino al primo crash o al primo login, poi tornavano a MQ e 150 ms. Peggio: con
l'adattatore acceso, un livello fissato lo spegne (è la regola del §13.42), quindi il riavvio
rimetteva l'adattatore e il livello tornava a salire da solo.

Ora qualità, adattatore e cuscino finiscono nel plist con gli stessi nomi della riga di comando, e
un livello fissato viaggia con `--no-adapt` (o al riavvio l'adattatore lo sovrascriverebbe). Un
livello che non è ancora stato scelto (`—`) **non** viene scritto: `--quality —` non è un livello,
`codecblue` stamperebbe la usage e launchd riproverebbe ogni cinque secondi per sempre.

#### Il volume: due attenuazioni, e il log che non le distingueva

La doppia attenuazione del §13.43 è corretta nel codice — le cuffie stanno a fondo scala e
l'attenuazione è nostra — ma il log mostrava solo `slider 56% -> gain 23.7%`, che è esattamente
quello che si vedeva anche quando il bug c'era. Ora, se alle cuffie è stato mandato un valore,
compare anche `volume: the headphones are at 100% and the rest is ours`: qualunque altro numero lì
è il bug che torna.

Self-test: **948 check, 0 falliti** (erano 940).

#### Una lettura del log, non due

`findRegistered(for:) ?? find(for:)` erano **due** `log show` da 1,1 s in fila sulla strada che
avvia lo stream: 2,2 s di silenzio prima ancora che la presa cominci. Ora `CBDeviceUUID.resolve`
legge una volta sola e restituisce entrambe le risposte (`registered`, `anyA2DP`, `best`).
Misurato: da 2,55 s a **1,36 s** fra l'avvio e la riga che parla della LQM.

### 13.51 «Non sento nulla», poi «molto a scatti»: la finestra da 660 ms

Prova dal vivo del 2026-11-08 con le FreeBuds 5 riconnesse. Due sintomi riferiti, una sola causa,
e la causa non era dove la cercavo.

#### Il primo: nessun suono

`codecblue status` rispondeva `link_quality off`, e il log dell'agente era pieno di

```
streaming: 239 kbps out, 44 packets/s, link took 71% of real time, queue 272 ms,
dropped 29%, socket full 88 times (2084 ms, longest 194 ms), at most 2 packet(s) per drain
```

`at most 2 packet(s) per drain` è la firma della LQM spenta (§13.12): il link porta ~50 kbps
invece di ~500, e il 29% dell'audio viene buttato. Il suono che arriva è l'altro 71%, a pezzi.

#### Perché la LQM restava spenta: due errori, non uno

**Errore 1 — l'UUID cercato troppo presto.** `play` e l'agente partono con le cuffie **spente**:
chiedono a macOS di connetterle, e solo allora bluetoothd scrive la riga `CBDevice … A2DP` da cui
si legge l'UUID. La ricerca avveniva a t = 3,9 s, prima che la cuffia fosse connessa, e falliva:

```
[  3.882] cannot find bluetoothd's UUID for this device: link quality mode stays off,
          so the link will carry ~50 kbps instead of ~500
```

Il keeper non partiva affatto, e nessuno ci riprovava. Ora la ricerca si ripete **dopo il
takeover**, quando il device è certamente pubblicato (`startKeeperIfPossible`).

**Errore 2 — la finestra è di 660 ms, e si chiedeva una volta al secondo.** Letto dal log di
bluetoothd, cronometrato:

```
18:18:01.660  Register audio device 40:DC:A5:XX:XX:XX-tacl
18:18:01.728  Received system 'audio started' notification from HAL on a2dpHandle 1   ← arrivato
18:18:02.106  Closing media channel for handle 1
18:18:02.153  Disabling Link Quality Mode
18:18:02.270  Erased 1 audio device …-tacl
```

Il device esiste per **610 ms** fra la registrazione e la cancellazione, e la LQM si spegne perché
`Stopping A2DP audio streaming` arriva subito dopo. Con un tentativo al secondo quella finestra si
manca **sempre** — non «a volte»: la fase è sbagliata di un ordine di grandezza.

Ora il keeper ha due ritmi: **0,1 s** finché bluetoothd non ha il device, `period` quando ce l'ha.
La raffica è limitata a 30 tentativi (3 s) e riparte a ogni `askAgainNow` — cioè all'avvio dello
stream — perché dieci messaggi al secondo per sempre riempivano il log di bluetoothd con **283
errori identici ogni 30 s**, misurati.

#### Il risultato, misurato

Prima e dopo, stessa macchina, stesse cuffie, stesso MQ:

| | prima | dopo |
|---|---|---|
| pacchetti per drain | 2 | nessuno stallo |
| scarti | 29% | **0%** |
| `sent % of real time` | 85,65% | **99,89%** |
| cuscino | 310 ms (allargato dagli stalli) | **60 ms** |
| latenza | 348 ms | **100 ms** |

73 report consecutivi senza un solo `dropped` e senza un solo `socket full`.

#### Il secondo sintomo, e la lezione

`link_quality` continua a dire `off` **mentre il link va a 336 kbps senza scarti**. L'indicatore
legge il log di bluetoothd e cerca `Register audio device` senza `Erased` dopo: ma `Erased` arriva
**sempre**, 600 ms dopo, perché il takeover chiude il canale media. Quindi l'indicatore misura la
presenza del device di bluetoothd, non la LQM. È il tipo di numero che sembra dire qualcosa e non
dice niente: la prossima volta va derivato da `at most N packet(s) per drain`, che è la misura vera
(§13.12 lo diceva già).

#### E una riga di log che mentiva

`volume: slider 33% -> gain 3.1% (applied before the encoder)` descriveva un'attenuazione che il
codice **non fa più** dal §13.44: la curva sta nelle cuffie, qui si moltiplica solo il mute (1 o 0).
Il numero era plausibile sia nella versione rotta sia in quella corretta, che è esattamente come il
bug delle due attenuazioni è rimasto invisibile per una serata. Ora dice il vero:

```
volume: slider 33% goes to the headphones; here only the mute is applied
volume: the headphones are at 33%
```

Self-test: **948 check, 0 falliti**.
#### L'indicatore, corretto una seconda volta

Il primo tentativo leggeva `Register audio device` nel log di bluetoothd: sbagliato, perché il
takeover cancella quel device 600 ms dopo. Il secondo leggeva i pacchetti per drain, ma **dopo**
`report()`, che azzera i contatori della finestra: rispondeva sempre 0. Il terzo, e definitivo, li
legge prima, e soprattutto capisce che cosa misurano:

- con la LQM **spenta** il socket rifiuta in ogni finestra → burst 2–3, 29% scartato;
- con la LQM **accesa** il socket non rifiuta **niente** → nessun burst da misurare.

Quindi «nessuno stallo» non è assenza di prova: è la prova. La regola sta in `LinkQuality.judge`,
con i numeri accanto e quattro self-test che la tengono ferma. `status` ora risponde:

```
link_quality   on
link_stalls    0
packets_per_dr -        ← nessuno stallo, quindi nessun burst da riportare
latency_ms     89
```

Self-test: **952 check, 0 falliti**.

### 13.52 «HQ si sente malissimo»: un livello non è una preferenza, è un tetto

Riferito dall'ascoltatore, e vero: scegliendo HQ l'audio diventa inascoltabile. Misurato subito, con
le stesse cuffie e lo stesso link:

| livello | chiede | il link porta | scartato |
|---|---|---|---|
| HQ | 990 kbps | ~530 | **41–48%** |
| SQ | 660 kbps | ~500 | **24–36%** |
| MQ | 330 kbps | 336 | **0%** |

Non è un guasto: il tetto del link con la LQM accesa è ~500 kbps (§13.14, misurato allora e
riconfermato oggi), e HQ ne chiede 990. Un livello sopra il tetto non è una preferenza, è un guasto:
butta via metà dell'audio e si sente.

#### Tre difetti, in fila

**1. `quality HQ` spegneva l'adattatore.** Il comando rispondeva `adapt=off`, e la regola del §13.42
— «un livello scelto a mano deve spegnere l'adattatore, o l'adattatore lo sovrascrive» — era giusta
per il problema che risolveva e sbagliata per questo: senza adattatore nessuno può scendere, e il
livello resta sopra il tetto per sempre.

**2. L'adattatore scendeva un gradino per volta.** Da HQ a MQ sono due passi, uno ogni
`minimumInterval` (4 s): otto secondi di audio distrutto. E si fermava a SQ, perché SQ «solo» il 24%
di scarto — che è comunque inascoltabile. La regola giusta non è «scendi finché va male», è «scegli
il livello che ci sta», e la capacità del link è già misurata: è il throughput della finestra in cui
si è scartato.

**3. Il throughput veniva letto dopo `report()`, che azzera i contatori.** Il primo tentativo
scriveva `settled on MQ (0 kbps carried)`: la divisione era su zero. Stessa famiglia di errore del
`packets_per_drain` (§13.51).

#### La regola, ora

`BitrateAdapter.fit(capacityKbps:)` sceglie il livello più alto il cui bitrate (chiesto all'encoder,
non copiato in una tabella) sta nell'**85%** della capacità misurata. L'85% è margine: un livello
che riempie il link esattamente non lascia niente ai round trip AVRCP e alle ritrasmissioni, ed è il
link che comincia a stallare.

E il livello scelto a mano è un **tetto**, non un posto dove stare: `quality HQ` significa «il
migliore che questo link permette, fino a HQ». Se il link non lo porta, lo stream scende da solo e
lo dice:

```
quality: LDAC HQ does not fit this link (557 kbps carried, 42% dropped): settled on MQ
```

#### Il tetto va abbassato, non solo il livello

Bloccare il livello abbandonato non basta: il blocco scade (30 s, poi 60) e ogni scadenza è una
prova udibile di un livello che il link non porta. Misurato:

```
[ 34.776] quality: LDAC SQ does not fit this link (468 kbps carried, 12% dropped): settled on MQ
[ 64.948] bitrate: up to LDAC SQ (the link has been clean)     ← 30 s dopo, e si sente
[ 79.933] quality: LDAC SQ does not fit this link (455 kbps carried, 30% dropped): settled on MQ
```

Quindi l'assestamento **abbassa anche il tetto** dell'adattatore: il link ha mostrato le carte, e un
livello sopra non è più una preferenza. Solo sceglierne uno a mano lo rialza.

#### Risultato

`quality HQ` su questo link: si assesta su MQ in una finestra, e non risale più. 40 s di prova,
`sent 99.87% of real time`, coda 0 ms, zero scarti.

#### E un difetto trovato per strada, che non c'entrava

Dopo un rebuild l'agente è uscito due volte con `Bluetooth is switched off` su una macchina con il
Bluetooth acceso e le cuffie connesse. Causa: `stateChanged` porta anche gli stati **transitori** di
una radio che si sta accendendo, e il codice trattava «non è 5» come «spento». Ora solo lo stato
spento stabile (`statePoweredOff = 4`) chiude l'attesa; tutto il resto aspetta il timeout che avrebbe
comunque aspettato.

Self-test: **963 check, 0 falliti**.

### 13.53 I nomi dei livelli, e cosa significano su *questo* link

Due osservazioni dell'ascoltatore, entrambe giuste.

#### «Se MQ è medio, perché compare sotto SQ?»

Perché i nomi sono di Sony e non sono una lista: **HQ** = High Quality, **SQ** = Standard Quality,
**MQ** = Mobile Quality. MQ è il livello **più basso**, pensato per l'ascolto in mobilità, e sta
sotto SQ solo perché l'alfabeto mette la M prima della S — non perché sia "più di" SQ. Un menu che
mostra tre sigle in quell'ordine chiede all'ascoltatore di indovinare.

Ora il menu dice cosa sono, in ordine di qualità decrescente, con il bitrate e il verdetto:

```
✓ High · 990 kbps · too much for this link
  Standard · 660 kbps · too much for this link
  Mobile · 330 kbps
```

E il bitrate non è un numero fisso: dipende dalla frequenza. A 44,1 kHz gli stessi tre livelli sono
909 / 606 / 303. Vengono dall'encoder, non da una tabella copiata, quindi non possono mentire.

Aggiunto anche `codecblue levels`, che stampa la stessa cosa da terminale.

#### La capacità del link va misurata, non dedotta

Il primo tentativo di `levels` diceva `MQ 330 kbps — too much for this link (334)`: assurdo, MQ che
non sta in un link che lo sta portando. Due errori sovrapposti:

1. leggeva il throughput di **qualsiasi** finestra, anche di una perfettamente pulita — dove il
   numero è il bitrate del livello, non il tetto del link;
2. poi leggeva il throughput di una finestra con **stalli assorbiti dalla coda**, che non dicono
   nulla sul tetto: il cuscino esiste apposta per assorbirli.

La regola giusta è una sola: **solo una finestra che ha perso audio misura il tetto**, perché solo
lì il livello ha chiesto più di quanto il link desse. Quindi `link_kbps` vale `0` finché non si è
misurato, e tutto ciò che lo mostra dice «non lo so» invece di indovinare:

```
$ codecblue levels                      # a riposo, MQ pulito
HQ 990 kbps
SQ 660 kbps
MQ 330 kbps

$ codecblue quality HQ                  # HQ chiede 990, il link dà 546
$ codecblue levels
HQ 990 kbps — too much for this link (546)
SQ 660 kbps — too much for this link (546)
MQ 330 kbps — fits (546 available)
```

#### La riga su 44,1 kHz, tolta

Il menu Sample rate diceva «44.1 kHz is the native rate of most music» sotto un segno di spunta su
**48 kHz**. Vero in generale, falso lì: una frase su 44,1 accanto a 48 configurato è una
contraddizione che il lettore deve risolvere da solo. Tolta. I due rate sono etichettati, e questo
basta.

Self-test: **970 check, 0 falliti**.

## 15. La scala intera, e il confronto con AAC (2026-11-08, sera)

Due domande dell'ascoltatore, la stessa risposta di fondo: **i livelli non sono tre e non sono
nomi, sono cinque bitrate**, e il confronto con macOS si fa in kbps e non a orecchio.

### 15.1 Perché tre livelli non bastano

La misura che ha reso il problema evidente (§14 sopra): questo link, con la LQM accesa, porta
**530–560 kbps**. Con tre livelli fissi la scelta è fra:

| livello | chiede | scartato |
|---|---|---|
| HQ | 990 | 41–48% |
| SQ | 660 | 24–36% |
| MQ/LQ | 330 | 0%, ma metà link inutilizzato |

Nessuna delle tre è la risposta giusta: la risposta è **492 kbps**, che nessuno dei tre nomi
descrive. E 492 esiste: `ldacBT_ex.h` dichiara `LDACBT_EQMID_Q0` e `Q1` come «undocumented, for
internal use only», e la tabella `tbl_ldacbt_eqmid_property` in `ldacBT_internal.c` le elenca in
ordine di bitrate:

```
990 HQ, 660 SQ, 492 Q0, 396 Q1, 330 MQ, 282 Q2, 246 Q3, 216 Q4, 198 Q5, 180 Q6, 162 Q7, 150 Q8, 138 Q9
```

Sono tredici gradini, non cinque. Ma `ldacBT_alter_eqmid_priority` si ferma a MQ
(`LDACBT_LIMIT_ALTER_EQMID_PRIORITY`, `ldacBT_internal.h:34`) e `ldacBT_set_eqmid` rifiuta tutto
ciò che non sia HQ/SQ/MQ (`ldacBT_assert_eqmid`, `ldacBT_internal.c:196`). Quindi **cinque** sono i
gradini raggiungibili dalla API pubblica, e sotto 330 non si scende.

**La trappola, misurata**: la scala è in ordine di bitrate, gli EQMID no. Il gradino 2 è EQMID 3 e
il gradino 4 è EQMID 2. Leggere `Quality(rawValue: rung)` sembra ovvio ed è sbagliato: il menu
offriva 330 kbps due volte e 492 mai. La mappa sta in `LDACEncoder.eqmid(forRung:)`, con il
commento che dice perché non è l'identità.

### 15.2 Cosa è cambiato nel codice

- `BitrateAdapter` lavora su **gradini** (`Int`, 0…4), non su `Quality`. `fitRung(capacityKbps:)`
  sceglie il gradino più alto il cui bitrate sta nell'85% della capacità misurata.
- `A2DPStreamer.Configuration` porta `rung: Int` invece di `quality: Quality`, e `currentRung` /
  `currentBitrateKbps` sono pubblicati per finestra: il bitrate lo dice l'encoder
  (`ldacBT_get_bitrate`), che è l'unica cosa che può dire «492».
- `--quality` e `codecblue quality` accettano **un nome o un numero**: `HQ`/`SQ`/`LQ` (e `MQ` per
  sempre, perché i plist scritti prima del rinominamento lo contengono) oppure `0`…`4`.
- Il menu a barre elenca **tutta la scala**, con il bitrate per i due gradini che non hanno nome e
  una spunta sul gradino che lo stream sceglierebbe *qui*. Il plist dell'agente riceve sempre il
  **numero**, mai il nome: `LDACEncoder.name(rung: 3)` è «396», e `--quality 396` non è un gradino.
- `codecblue levels` mostra la scala intera e la verdetto per ogni gradino.

L'etichetta di un livello sopra il tetto del link dice ora **cosa si ottiene**, non cosa chiede:

```
$ codecblue levels
  HQ 990 kbps — too much for this link (530)  (rung 0)
  SQ 660 kbps — too much for this link (530)  (rung 1)
  492 kbps — fits (530 available)  (rung 2)
  396 kbps — fits (530 available)  (rung 3)
✓ LQ 330 kbps — fits (530 available)  (rung 4)

$ # e nel menu, dove lo spazio è poco:
  High · 990 kbps · here 492 kbps
  Standard · 660 kbps · here 492 kbps
✓ 492 kbps
```

E il gradino più basso non è più «troppo per questo link» quando il link è sotto 330: è **il più
basso che c'è**. Accusare l'ultimo gradino di essere troppo alto è accusarlo di un guasto che non
può riparare.

### 15.3 Il confronto con macOS in AAC: `codecblue compare`

Il confronto non si fa a orecchio, perché i due percorsi non sono nella stanza insieme. Si fa sui
numeri che bluetoothd stampa **quando suona lui** — e non quando suoniamo noi, perché allora il suo
`Server.Audio` non c'entra e non stampa niente:

```
A2DP configured at 44.1 KHz. Codec: AAC-LC, VBR max: 230 kbps.
    1 frames * (12+668) bytes = 680 per RTP (max=879) every 23.22 ms
```

680 byte ogni 23,22 ms = 43 pacchetti/s = **234 kbps**. `codecblue compare` legge quelle righe
(`AACSession.parse`), legge il `LinkQualityReport` per ReTx e RSSI, e confronta nella sola unità che
i due percorsi condividono:

```
macOS asked for AAC at 44100 Hz: 680 bytes every 23.22 ms = 234 kbps
the link, over 5 report(s): 0.0% retransmitted, RSSI -56 dBm
macOS lowered its own bitrate 21 time(s) when the link complained: that is the machinery LDAC has nothing equivalent to

AAC asks 234 kbps, LDAC cannot ask less than 330: 1.4× the bitrate, so the link has to be 1.4× better before this path is as steady
this link has carried 245 kbps: AAC's 234 fits with room, LDAC's floor of 330 does not
```

**Perché macOS regge più lontano**, in tre fatti e non in un'opinione:

1. **Chiede un terzo in meno.** 234 contro 330. Quando il link si restringe — distanza, un muro,
   un corpo in mezzo — la prima cosa che cala è il bitrate che il link porta, e il percorso che ne
   chiede meno sopravvive più a lungo. Non è che AAC suoni meglio: è che chiede meno.
2. **Ha `adjustBitRateForMac`.** Quando il link si lamenta, macOS abbassa il proprio bitrate AAC
   (21 volte nella finestra misurata). libldac si ferma a 330: sotto quella soglia non c'è niente
   da abbassare, e l'audio viene scartato invece che compresso di più.
3. **Possiede il link.** macOS tiene la LQM accesa e fa uscire il link dallo sniff da sé
   (`Server.Audio`). Noi affittiamo lo stesso link con un takeover: stessa radio, ma quelle due
   cose le dobbiamo chiedere a mano — ed è esattamente ciò che il keeper fa, con tutti i problemi
   dei §13 e §14.

Un quarto fatto, minore ma reale: AAC è VBR, i suoi frame si accorciano quando il segnale è
semplice; la lunghezza di frame di LDAC è fissata dal packet type e non segue la musica.

### 15.4 Un difetto trovato guardando il flusso in corso

Con lo stream a 336 kbps, 62 pacchetti/s, zero stalli, il log diceva:

```
link quality mode lost: bluetoothd erased the audio device, asking again until it comes back
```

e poi niente, per venti minuti. Due cose sbagliate in una:

- **«lost» era falso.** La LQM è un'impostazione sulla connessione ACL e resta accesa; quello che
  bluetoothd cancella è il suo *device audio*, e con lo stream in corso può non ripubblicarlo mai.
  Il flusso andava a 336 kbps senza un solo stallo: il link stava benissimo. Stessa famiglia di
  errore del `link_quality` che leggeva `Register audio device` invece dello stato del socket.
- **Il keeper continuava a chiedere una volta al secondo nel vuoto**: **290 errori identici
  `No device found for uid` in cinque minuti**, ognuno un wake-up e una riga di log. Ora il ritmo
  rallenta (raddoppia fino a 30 s) quando bluetoothd è senza device, e riparte veloce a ogni
  `askAgainNow`.

Self-test: **1034 check, 0 falliti**.
