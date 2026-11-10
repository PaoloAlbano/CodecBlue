# Il tetto del link: quanto vale, e su che finestra misurarlo

Misurato il 2026-11-10 su HUAWEI FreeBuds 5 (`40:DC:A5:0E:14:48`), MacBook Pro
`BCM_4388C2`, firmware `24.2.241.1921`, macOS 27. Stesso link, stessa stanza, stesso tono
(`/tmp/tone60-441.wav`, 44.1 kHz stereo). La domanda era: **il margine del 15% nel
`fitRung` è troppo prudente?** La risposta è no, e la misura ha smentito l'ipotesi in tre
modi.

## 1. Il tetto non è ~500 kbps: è ~410

`codecblue flood` (ACL crudo, nessun codec, pacchetti da 679 byte, LQM attivo):

```
flood: 75 packets/s, 410 kbps, 22716 refused
```

22716 rifiuti su 15 s: il socket rifiuta tutto ciò che va oltre, quindi 410 kbps è il
tetto del controller, non una stima. Il README diceva "~500": era una stima, questa è una
misura, e va corretta.

Conferma indipendente, dal controller stesso (`GetControllerInfo`):

```
AuLQ [... BtRt 230 Kbps, Codc AAC-LC, RSSI -44, SNR 51 ...]
Chip BCM_4388C2, LMPv 13 (5.4)
```

e da `bluetoothd`: `A2DP Link Adaptive Packet Type: Link Adaptive Packet type support=0`.
Il controller non negozia pacchetti 3-slot, e macOS non espone `HCISetACLPacketType`:
**è hardware**. LDAC HQ (990) non è raggiungibile qui, e non lo sarà con un altro
programma.

## 2. Il tetto misurato dipende dalla finestra, e in modo che non aiuta

HQ forzato (`--quality 0`), stesso link, finestre diverse. Il numero è quello che la
regola di assestamento legge — `carriedKbps` nella finestra che ha perso audio:

| finestra | run 1 | run 2 |
|---|---|---|
| 500 ms | 343 kbps (42% drop) | 441 kbps (31% drop) |
| 1000 ms | 350 kbps (52% drop) | 398 kbps (46% drop) |
| 2000 ms | 403 kbps (51% drop) | 403 kbps (51% drop) |
| 4000 ms | 357 kbps (59% drop) | 374 kbps (57% drop) |

**Una finestra corta non è più precisa: è più rumorosa.** A 500 ms lo stesso link dà 343 e
441 in due run consecutivi — un fattore 1.3. Il motivo è aritmetico: 500 ms contengono
~35 pacchetti, e un singolo stall da 100 ms ne toglie il 20%. A 2 s lo stall è il 5% della
finestra, e il numero si stabilizza (403 e 403, identici).

Quindi la finestra da 2 s **non è troppo grossolana per misurare il tetto**: è la più
piccola che lo misura. Sotto, si misura il rumore.

## 3. Il margine del 15% è giusto, e il rung 3 non ci sta

L'ipotesi da verificare era: a 44.1 kHz il rung 3 vale 363 kbps, il tetto è 417, quindi
`417 × 0.85 = 354` lo rifiuta e si perde il 20% della qualità per niente.

Misurato: **non è per niente.** 363 kbps su questo link non è stabile.

| rung | drop | cuscino mediano | cuscino massimo |
|---|---|---|---|
| 303 kbps (LQ) | 2.0% delle finestre (7/356) | 0 ms | 150 ms |
| 363 kbps (rung 3) | 1.4% delle finestre (5/345) | 87–116 ms | 203–232 ms |

Il drop è **lo stesso** ai due rung — 2.0% contro 1.4%, cioè il rung basso droppa quanto
quello alto — ma il **cuscino** no: a 303 resta vuoto, a 363 si riempie. Il cuscino è
esattamente ciò che assorbe uno stall, quindi quando si consuma il rung è oltre il bordo,
e quando resta vuoto il rung ci sta comodamente.

Il tetto vero, quindi, non è 417 (il massimo mai visto in una finestra) ma circa **330–360
kbps sostenibili**: 303 ci sta con margine, 363 ci sta solo finché gli stall sono rari.
`417 × 0.85 = 354` rifiuta 363 ed è la risposta corretta.

## 4. Cosa NON è la causa del drop (verificato e scartato)

Tre ipotesi provate e smentite, perché ognuna avrebbe portato a una modifica sbagliata:

- **"Il drop è colpa del rung"** — no: 303 droppa quanto 363 (§3). Un passo giù da 363 a
  303 non cura niente, e suona peggio.
- **"Il drop è una lettura corta dalla sorgente"** — no: 0 finestre con drop su 21
  avevano `short read(s)`. La sorgente teneva il passo.
- **"Il cuscino pieno è un guasto"** — no: il cuscino arriva a 150 ms con **0% drop**.
  Un cuscino pieno che non perde audio ha fatto il suo lavoro.

Provate tutte e tre come modifiche al codice, misurate, e **tutte e tre annullate**: il
comportamento attuale (scendere a 303 e restarci) è quello giusto.

## 5. Il numero che resta da guardare

`link_ceiling` = 417 e `link_floor` = 417 sono **lo stesso numero** in ogni misura, perché
il floor è il massimo dei `carriedKbps` puliti e il ceiling è il `carriedKbps` della
finestra che ha droppato — e in una finestra satura i due coincidono. Non è un bug, ma
significa che il menu non distingue "ha portato" da "ha rifiutato": la distinzione esiste
nel codice (`linkIsCeiling`) e serve solo quando i due divergono, cosa che su questo link
non succede.

## Riproduzione

```sh
codecblue flood 40:DC:A5:0E:14:48 15 679 --keep-link-quality   # il tetto ACL crudo
codecblue play  40:DC:A5:0E:14:48 /tmp/tone60-441.wav --report-ms 500 --quality 0  # il tetto per finestra
codecblue play  40:DC:A5:0E:14:48 /tmp/tone60-441.wav --report-ms 500 --quality 3  # 363: il cuscino si riempie
codecblue play  40:DC:A5:0E:14:48 /tmp/tone60-441.wav --report-ms 500 --quality 4  # 303: il cuscino resta vuoto
```

`--report-ms` è stato aggiunto per questa misura: senza, la finestra è fissa a 2 s e la
domanda "e su una finestra più piccola?" non era ponibile.
