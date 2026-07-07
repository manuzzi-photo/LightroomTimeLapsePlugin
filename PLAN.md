# Piano di realizzazione — Plugin Timelapse per Lightroom Classic

Plugin open source (GPLv3) per Lightroom Classic che genera un video timelapse
(H.264/H.265, con supporto HDR) dalle fotografie selezionate, usando ffmpeg
come encoder esterno.

## Decisioni di progetto

| Aspetto | Decisione |
|---|---|
| Entry point | Menù **File → Plug-in Extras**, dialog custom LrView |
| Sorgente frame | Export automatico via `LrExportSession` (sviluppo applicato) |
| ffmpeg | Auto-rilevamento (PATH, Homebrew, percorsi tipici) + percorso manuale nelle impostazioni |
| Piattaforme | macOS nella v1; architettura predisposta per Windows (astrazione percorsi/OS) |
| Keyframes min/max | Intervallo keyframe di **codifica** (GOP): `keyint_min` / `keyint` passati a x264/x265 |
| Velocità | FPS di output selezionabile (24/25/30/60), **1 foto = 1 frame** |
| Aspect ratio | Scelta utente nel dialog: crop centrale (default) o letterbox/pillarbox |
| Preview | MP4 a 480p/240p generato dalle anteprime della libreria, aperto nel player di sistema via `LrShell` |
| HDR | H.265 10-bit con transfer **PQ (HDR10)** o **HLG**, selezionabile; attivo solo se *tutte* le foto sono HDR |
| Qualità | Preset semplici (Alta/Media/Bassa) + sezione "Avanzate" (CRF, preset encoder, bitrate max) |
| Deflicker | Sì, filtro `deflicker` di ffmpeg attivabile con checkbox |
| Distribuzione | Open source su GitHub: README curato, localizzazione IT/EN, error handling robusto |

## Architettura

Struttura *flat* (il `require` di Lightroom carica in modo affidabile solo file
nella root del plugin, quindi niente sottocartelle):

```
TimelapseCreator.lrdevplugin/
├── Info.lua                      -- manifest: menu Plug-in Extras + filtro diagnostico
├── MenuItem.lua                  -- entry point: selezione, ordinamento, analisi HDR
├── TimelapseDialog.lua           -- dialog LrView: opzioni, preview, pipeline di generazione
├── FrameExporter.lua             -- LrExportSession: rendering frame in cartella temp
├── FFmpegLocator.lua             -- rilevamento binario (prefs → percorsi noti → PATH)
├── FFmpegCommand.lua             -- costruzione comandi (LUA PURO, unit-testabile)
├── FFmpegRunner.lua              -- esecuzione via LrTasks.execute, log, progress poller
├── HdrDetector.lua               -- HDREditMode nei develop settings (SDK ≥ 13)
├── PreviewBuilder.lua            -- anteprime libreria → MP4 low-res
├── Platform.lua                  -- astrazione macOS/Windows (quoting, apertura file)
├── Log.lua                       -- LrLogger
├── DiagnosticsMenuItem.lua       -- spike Fase 0 eseguibile dentro Lightroom
├── ExportSettingsDumpFilter.lua  -- filtro export: dump delle chiavi reali (spike HDR)
└── TranslatedStrings_it.txt      -- localizzazione italiana (default inglese)

tests/
├── test_ffmpeg_command.lua       -- unit test (lua standalone)
└── integration_ffmpeg.sh         -- encode reali con frame sintetici + ffprobe
```

Principio chiave: **`FFmpegCommand.lua` è Lua puro senza dipendenze `Lr*`**, così la
logica di costruzione dei comandi è unit-testabile fuori da Lightroom (CI con luacheck
+ test con interprete lua standalone).

## Pipeline

### 1. Selezione e ordinamento
- `catalog:getTargetPhotos()` per la selezione corrente.
- Ordinamento per data di scatto (`getRawMetadata("dateTimeOriginal")`).
- Esclusione dei video; avviso se le foto sono meno di ~10.

### 2. Export dei frame (`LrExportSession`)
- Cartella temporanea dedicata (`LrPathUtils.getStandardFilePath("temp")` + sottocartella sessione).
- Naming sequenziale `frame_%06d`.
- **SDR**: JPEG qualità ~95, sRGB.
- **HDR**: TIFF 16-bit (vedi rischi §HDR).
- Dimensione export: lato lungo dimensionato per coprire il frame target
  (per il crop centrale serve esportare leggermente più grande del target).
- Progress e annullamento con `LrProgressScope`.
- Pulizia della cartella temp a fine job (anche in caso di errore, via `LrFunctionContext`).

### 3. Codifica ffmpeg
Input: `-framerate <fps> -i frame_%06d.<ext>`

| Opzione UI | Mappatura ffmpeg |
|---|---|
| Risoluzione (720p/1080p/4K, orizz./vert.) | `scale` + `crop` (o `pad` per letterbox) |
| Codec H.264 / H.265 | `-c:v libx264` / `-c:v libx265 -tag:v hvc1` |
| Keyframe min/max | x264: `-keyint_min M -g N`; x265: `-x265-params keyint=N:min-keyint=M` |
| Preset qualità | Alta=CRF 18/slow, Media=CRF 21/medium, Bassa=CRF 26/fast (x265: valori adattati) |
| Avanzate | CRF esplicito, preset encoder, `-maxrate`/`-bufsize` |
| Deflicker | `-vf deflicker=size=<N>` (primo filtro della catena, prima di scale/crop) |
| HDR PQ | `-pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc` + `-x265-params hdr10=1:...` |
| HDR HLG | come sopra con `-color_trc arib-std-b67` |
| Compatibilità player | `-movflags +faststart -pix_fmt yuv420p` (SDR) |

- Output di ffmpeg rediretto su file di log per la diagnostica degli errori.
- Su macOS: esecuzione con `LrTasks.execute`, quoting dei percorsi con spazi.

### 4. Preview (480p / 240p)
- Frame ricavati dalle **anteprime della libreria** (`photo:requestJpegThumbnail`),
  non da un export completo → generazione in pochi secondi.
- Encode H.264 `-preset ultrafast -crf 28` alla risoluzione scelta (480p o 240p).
- File in cartella temp, apertura nel player predefinito (macOS: `open`, via `Platform.lua`).
- La preview riflette fps, aspect/crop e deflicker; non riflette qualità/codec/HDR finali.

### 5. HDR
- **Rilevamento**: tutte le foto selezionate devono avere l'editing HDR attivo
  (verifica su develop settings / metadata — da confermare nello spike, vedi §Rischi).
- Se anche una sola foto non è HDR: opzioni HDR disabilitate nella UI con spiegazione.
- Se HDR attivo: export frame TIFF 16-bit, encode H.265 10-bit PQ o HLG a scelta.

## UI del dialog

Sezioni (colonna singola, `LrView`):
1. **Riepilogo** — n° foto selezionate, durata risultante calcolata (foto ÷ fps), badge HDR disponibile/no.
2. **Formato** — risoluzione (720p/1080p/4K), orientamento (orizzontale/verticale), adattamento (crop centrale / bande).
3. **Velocità** — fps output: 24/25/30/60.
4. **Codec** — H.264/H.265; se HDR disponibile: checkbox HDR + scelta PQ/HLG.
5. **Qualità** — preset Alta/Media/Bassa; sezione *Avanzate* collassata: CRF, preset encoder, keyframe min/max, bitrate max.
6. **Opzioni** — deflicker on/off (+ finestra frame).
7. **Output** — cartella destinazione, nome file.
8. Pulsanti: **Anteprima** (con scelta 480p/240p) · **Crea timelapse** · Annulla.

Le impostazioni vengono ricordate tra le sessioni via `LrPrefs`.

## Fasi di sviluppo e stato (aggiornato 2026-07-06)

### Fase 0 — Spike sui rischi — ✅ ricerca fatta, ⏳ verifica in Lightroom
Risultati della ricerca su SDK LrC 15 e ffmpeg 8.0.1 locale:
- **L'SDK non documenta alcuna impostazione di export HDR**: `LR_format`
  ammette solo JPEG/PSD/TIFF/DNG/ORIGINAL, `LR_export_colorSpace` solo
  sRGB/AdobeRGB/ProPhotoRGB. Per scoprire eventuali chiavi non documentate il
  plugin include: (a) *Timelapse Diagnostics* (probe AVIF/JXL/TIFF16 e chiavi
  speculative `LR_export_HDR`), (b) il filtro *dump export settings* da usare
  con un export manuale con HDR attivo. → Da eseguire in Lightroom.
- `LrTasks.execute` = semantica `os.execute` (0 = successo); output catturato
  via redirect su file.
- `photo:requestJpegThumbnail(w, h, callback)` confermata; latenza da
  misurare con la diagnostica.
- ffmpeg locale: libx264, libx265 (10-bit ok), `deflicker`, `zscale` presenti.

### Fase 1 — MVP end-to-end — ✅ implementato (da testare in Lightroom)
### Fase 2 — Opzioni complete — ✅ implementato (manca: annullamento encode in corso)
### Fase 3 — Preview — ✅ implementato (480p/240p da anteprime libreria → player di sistema)

### Fase 4 — HDR — ⏳ bloccata sullo spike
Il lato ffmpeg (10-bit, PQ/HLG, `hdr10=1`, tag colore BT.2020) è già
implementato e unit-testato in `FFmpegCommand`. Manca la sorgente: dipende
dall'esito dei probe di export HDR in Lightroom. Fallback se l'SDK non
espone nulla: TIFF 16-bit + conversione con `zscale`, oppure HDR rimandato.

### Fase 5 — Rifinitura open source — 🔄 parziale
Fatto: localizzazione IT, README, gestione "ffmpeg non trovato" con
selezione percorso, workflow di rilascio manuale (`scripts/release.sh`,
vedi sotto). Mancano: CI GitHub Actions (unit test + luacheck su ogni push),
test e rifinitura Windows.

## Workflow di rilascio — ✅ implementato (2026-07-06)

Rilascio manuale, non automatico su push del tag (scelta esplicita:
mantenere il controllo diretto invece di una pipeline CI). Copertura dei tre
passi richiesti:

1. **Compilazione/pacchettizzazione**: `scripts/release.sh` copia
   `TimelapseCreator.lrdevplugin/` in `dist/TimelapseCreator.lrplugin/`
   (rinominata secondo la convenzione SDK per la distribuzione), aggiunge
   `README.md` e `LICENSE`, e crea `dist/TimelapseCreator-X.Y.Z.zip`. Prima
   di pacchettizzare esegue `luac -p` su tutti i file e la suite di unit
   test (`tests/test_ffmpeg_command.lua`).
2. **Verifica versione**: `scripts/check_version.lua` — dato che `Info.lua`
   non può fare `require` (vedi Fase 0/bug fix), la sua `VERSION.display` è
   estratta per pattern-matching testuale e confrontata sia con
   `Version.lua` sia con il tag passato come argomento. Fallisce (`exit 1`)
   su qualunque disallineamento; richiamabile anche da solo durante lo
   sviluppo, senza rilasciare nulla.
3. **Release GitHub**: dopo conferma interattiva, `release.sh` pusha il tag
   su `origin` (se non già presente) e usa `gh release create <tag> <zip>
   --generate-notes` per pubblicare, allegando lo zip compilato.

Precondizioni verificate dallo script prima di procedere: il tag richiesto
deve esistere già localmente (creato a mano con `git tag -a`) e puntare
esattamente su HEAD, e il working tree deve essere pulito — tagging resta
un passo distinto e deliberato, non automatizzato dallo script.

## Versione 0.2.0 — ✅ implementata (2026-07-06)

Quattro modifiche mirate sulla base ​0.1.0, nessuna delle quali tocca la pipeline
di generazione video (che resta quella già testata). Implementate come
pianificato, con un quinto punto aggiunto in corso d'opera (pulizia delle
cartelle di anteprima).

### 1. Percorso ffmpeg spostato nelle impostazioni del plugin — ✅ implementato

Oggi il pulsante "Imposta percorso ffmpeg..." vive nel dialog di creazione
(`TimelapseDialog.lua`), che è per-video; il percorso ffmpeg è invece
un'impostazione di installazione e appartiene al **Gestione plug-in** di
Lightroom, tramite `LrPluginInfoProvider`.

- **Info.lua**: aggiungere `LrPluginInfoProvider = 'PluginInfoProvider.lua'`.
- **Nuovo file `PluginInfoProvider.lua`**:
  - `startDialog(propertyTable)` — chiamata *bloccante* da Lightroom quando il
    plugin viene selezionato in Gestione plug-in (non è un task). Deve quindi
    leggere solo `LrPrefs` in modo sincrono per popolare `propertyTable`
    subito, poi lanciare `LrTasks.startAsyncTask` per rivalidare ffmpeg
    (`FFmpegLocator.locate()`, che shella fuori e quindi deve yieldare) e
    aggiornare `propertyTable.ffmpegStatus` quando pronto. Stesso bug-pattern
    già corretto altrove (pcall/yield) — va evitato fin dal progetto.
  - `sectionsForTopOfDialog(f, propertyTable)` — ritorna una sezione con:
    logo (vedi punto 2), nome e versione del plugin, riga di stato ffmpeg
    (percorso + versione rilevata), pulsanti **"Rileva automaticamente"** e
    **"Scegli percorso..."** (logica riusata da `FFmpegLocator`), e la nota
    sulla versione minima richiesta (vedi punto 4).
- **TimelapseDialog.lua**: rimuovere il pulsante e l'azione di scelta percorso;
  mantenere solo una riga di stato **in sola lettura** (`bind 'ffmpegStatus'`);
  se ffmpeg non è configurato, il testo rimanda a *File → Gestione plug-in →
  Timelapse Creator*. La validazione che blocca "Crea timelapse" senza ffmpeg
  resta invariata.
- Nessuna migrazione dati necessaria: la preferenza `ffmpegPath` è già in
  `LrPrefs.prefsForPlugin()`, letta/scritta dagli stessi metodi di
  `FFmpegLocator` (`locate`, `validate`, `saveUserPath`).

### 2. Logo nelle impostazioni del plugin e nel README — ✅ implementato

File sorgente già presente in repo: `Logo.png` (1254×1254, RGBA), che resta
in root come master per la documentazione.

- Il controllo `LrView` `picture` richiede un file **PNG/JPG dentro la
  cartella del plugin**, referenziato con `_PLUGIN:resourceId('Icon.png')`
  (i path assoluti fuori dal bundle non sono garantiti). Va quindi generata
  una copia ridimensionata: `TimelapseCreator.lrdevplugin/Icon.png`, 128×128,
  con `sips -Z 128 Logo.png --out TimelapseCreator.lrdevplugin/Icon.png`
  (strumento già presente su macOS, nessuna nuova dipendenza).
- `PluginInfoProvider.lua`: `f:picture { value = _PLUGIN:resourceId('Icon.png'), frame_width = 0 }`
  in cima alla sezione, accanto a nome/versione.
- `README.md`: banner in testa al file,
  `<p align="center"><img src="Logo.png" width="180" alt="Timelapse Creator"></p>`,
  usando l'asset master a piena risoluzione (GitHub lo scala via l'attributo `width`).

### 3. Frequenza fotogrammi "personalizzata" — ✅ implementato

- `TimelapseDialog.lua`, popup fps: aggiungere la voce
  `{ title = LOC "…Custom=Personalizzato...", value = 'custom' }` in coda a
  24/25/30/60.
- Nuovo campo `props.customFps` (default: `30`), con un `f:edit_field`
  (`min = 1, max = 240, precision = 3` per coprire framerate frazionari tipo
  23.976/29.97) visibile solo quando `props.fps == 'custom'`, tramite binding
  calcolato:
  ```lua
  visible = LrView.bind {
    keys = { 'fps' },
    operation = function(_, values, fromTable)
      if fromTable then return values.fps == 'custom' end
      return LrBinding.kUnsupportedDirection
    end,
  }
  ```
- **Centralizzare la risoluzione del valore effettivo** in un helper
  `effectiveFps(props)` (`return props.fps == 'custom' and tonumber(props.customFps) or tonumber(props.fps) or 30`),
  usato ovunque oggi si legge `tonumber(props.fps)`: `updateSummary`,
  `applyKeyintDefaults`, `runGeneration` (chiamata a `FFmpegRunner.run`) e il
  builder della preview. Evita di duplicare la stessa logica in quattro punti.
- Validazione nel loop del dialog: se `props.fps == 'custom'`, richiedere
  `tonumber(props.customFps)` in `(0, 240]`, altrimenti messaggio di errore
  come per gli altri campi.
- `customFps` aggiunto alla lista `REMEMBERED` per persistenza tra sessioni.

### 4. Versione minima di ffmpeg — ✅ implementato

Verificata la feature più recente da cui il plugin dipende: il filtro
`deflicker` è stato introdotto in **ffmpeg 3.4** (2017); tutte le altre
funzionalità usate (libx265, tag `hvc1`, `movflags +faststart`, tag colore
BT.709/BT.2020) sono molto più datate. Il plugin è sviluppato e testato con
ffmpeg 8.0.1.

- **Minimo dichiarato: ffmpeg 4.0** (margine di sicurezza sopra la soglia
  reale di 3.4, versione facilmente reperibile su qualunque gestore pacchetti
  attuale).
- **`FFmpegCommand.lua`** (Lua puro, testabile): aggiungere
  `FFmpegCommand.MIN_FFMPEG_VERSION = '4.0'` e una funzione pura
  `FFmpegCommand.isVersionAtLeast(version, minVersion)` che confronta i
  componenti numerici (`major.minor.patch`) di due stringhe di versione;
  unit-testata come le altre funzioni pure del modulo (inclusi casi limite
  tipo `"n4.4-20220..."` o `"6.1.1"`).
- **`FFmpegLocator.lua`**: `locate()`/`validate()` restituiscono anche
  `sufficient` (booleano) accanto a path/versione.
- **UI** (main dialog in sola lettura + sezione Gestione plug-in): se ffmpeg è
  rilevato ma `sufficient == false`, mostrare un avviso non bloccante,
  es. *"ffmpeg 3.2 rilevato — richiesta versione 4.0 o superiore; funzioni
  come il deflicker potrebbero non essere disponibili."* La generazione non
  viene bloccata (ffmpeg resta generalmente retrocompatibile a livello di
  sintassi; è un avviso, non un hard gate).
- **README.md**: aggiornare i Requirements con
  "ffmpeg ≥ 4.0 (sviluppato e testato con la 8.0.1; versioni precedenti
  potrebbero non avere il filtro `deflicker`)".

### 5. Pulizia delle cartelle di anteprima (richiesta aggiunta in corso d'opera)

La preview era già generata sotto la cartella temporanea di sistema
(`LrPathUtils.getStandardFilePath('temp')/TimelapseCreator/preview_<timestamp>`),
ma non veniva mai ripulita. Aggiunta pulizia a due livelli:

- **`PreviewBuilder.lua`**: tiene traccia dell'ultima cartella di anteprima
  generata (`lastPreviewDir`) e la elimina — via `PreviewBuilder.cleanup()` —
  sia all'inizio di ogni nuova generazione, sia quando il chiamante lo
  richiede esplicitamente. Sicuro anche se il video è ancora aperto nel
  player di sistema (su macOS l'unlink di un file aperto non lo interrompe).
- **`TimelapseDialog.lua`**: registra `context:addCleanupHandler(...)` che
  chiama `PreviewBuilder.cleanup()` — eseguito automaticamente qualunque sia
  il modo in cui il dialog si chiude (Annulla, errore di validazione,
  generazione completata o fallita). Questa è la pulizia "alla chiusura del
  tool".
- **Nuovo `ShutdownApp.lua`** + `Info.lua`: `LrShutdownApp` cancella l'intera
  cartella `<temp di sistema>/TimelapseCreator` alla chiusura di Lightroom —
  rete di sicurezza per il caso in cui il cleanup handler del dialog non sia
  mai scattato (Lightroom terminato in modo anomalo), e ripulisce anche le
  cartelle di sessione di generazioni fallite lasciate apposta per debug
  (vedi Fase 2).

### File coinvolti (riepilogo)

```
TimelapseCreator.lrdevplugin/
├── Info.lua                  -- + LrPluginInfoProvider, + LrShutdownApp
├── PluginInfoProvider.lua    -- NUOVO: sezione Gestione plug-in (ffmpeg, logo, versione min)
├── ShutdownApp.lua           -- NUOVO: pulizia cartella temp alla chiusura di Lightroom
├── Icon.png                  -- NUOVO: logo ridimensionato 128×128 (da Logo.png in root)
├── TimelapseDialog.lua       -- rimosso pulsante percorso ffmpeg; + fps personalizzato; + effectiveFps();
│                                + cleanup handler per le preview
├── PreviewBuilder.lua        -- + tracking e pulizia dell'ultima cartella di anteprima
├── FFmpegCommand.lua         -- + MIN_FFMPEG_VERSION, isVersionAtLeast()
├── FFmpegLocator.lua         -- locate()/validate() restituiscono anche `sufficient`
├── DiagnosticsMenuItem.lua   -- mostra anche l'esito del controllo versione minima
└── TranslatedStrings_it.txt  -- + nuove stringhe (personalizzato, avviso versione, Gestione plug-in)

tests/test_ffmpeg_command.lua -- + casi per isVersionAtLeast()
README.md                     -- + banner logo, + requisito versione ffmpeg
```

Nessun impatto sulla pipeline export→ffmpeg né sui test di integrazione
esistenti (`integration_ffmpeg.sh`); tutti i 55 unit test e i 4 encode di
integrazione continuano a passare dopo le modifiche.

## Versione 0.3.0 — ✅ implementata (2026-07-07)

Scoperta di partenza, valida per tutto questo piano: **Lightroom Classic esegue
Lua 5.1.5**, non il Lua 5.4 di Homebrew usato finora per i test in locale.
Verificato con il `luac` incluso nell'SDK
(`AdobeSDK/LrC_15/Lua Compiler/mac/luac`, Mach-O x86_64, `Lua 5.1.5 Copyright
(C) 1994-2012 Lua.org, PUC-Rio`): tutti i file attuali del plugin passano
`luac -p` senza errori, quindi nessuna incompatibilità retroattiva — ma da qui
in avanti ogni nuovo file va controllato anche con questo compilatore, non
solo con quello di sistema.

### 1. Riquadro di anteprima statico con slider dei fotogrammi — ✅ implementato

Affianca l'anteprima MP4 esistente (non la sostituisce): feedback istantaneo
senza invocare ffmpeg, utile per controllare rapidamente inquadratura/sviluppo
lungo la sequenza.

- **`TimelapseDialog.lua`**: nuova sezione in cima al dialog (sopra il
  Riepilogo) con `f:picture` (mostra il fotogramma corrente) + `f:slider {
  min = 1, max = #photos, integral = true, value = bind 'previewFrameIndex' }`
  + testo "Foto N di M — <nome file/data>".
- Al cambio di `previewFrameIndex`, richiesta asincrona di
  `photos[i]:requestJpegThumbnail(w, h, callback)` (stesso pattern già usato
  in `PreviewBuilder.lua`), salvataggio del JPEG in un file temporaneo e
  aggiornamento di `props.previewImagePath` (bind del `value` di `f:picture`).
- **Debounce obbligatorio**: lo slider aggiorna il valore continuamente
  durante il trascinamento; senza debounce ogni micro-movimento
  spawnerebbe una richiesta di thumbnail. Uso un token/contatore di
  generazione incrementato a ogni cambiamento: la richiesta attende
  ~150 ms (`LrTasks.sleep`) e procede solo se il suo token è ancora quello
  corrente, altrimenti si auto-annulla.
- Mostra l'anteprima "as developed" (i thumbnail di libreria riflettono gli
  sviluppi e l'eventuale crop già applicati in Develop), ma **non** simula il
  crop/pad target del video finale — differenza da documentare in UI con una
  nota, per non creare l'aspettativa che l'inquadratura combaci esattamente.

### 2. Salvataggio opzionale nella cartella originale delle foto — ✅ implementato

Opzione aggiuntiva, non nuovo default (comportamento attuale invariato).

- **`TimelapseDialog.lua`**: nuovo campo `props.saveInSourceFolder`
  (default `false`) con checkbox "Salva nella cartella delle foto originali"
  nella riga Output; quando spuntata, il selettore di cartella manuale si
  disabilita.
- In `runGeneration`: se `props.saveInSourceFolder`, la cartella di
  destinazione diventa `LrPathUtils.parent(photos[1]:getRawMetadata('path'))`
  (cartella della prima foto della sequenza già ordinata per data) invece di
  `props.outputFolder`.
- **Caso foto in cartelle diverse**: si usa sempre la cartella della prima
  foto, senza rilevamento/avviso per selezioni miste — tenuto semplice
  volutamente; una nota nella UI accanto alla checkbox lo rende esplicito.
- `saveInSourceFolder` aggiunto a `REMEMBERED`.

### 3. Versione ffmpeg solo nelle informazioni del plugin — ✅ implementato

- **`TimelapseDialog.lua`**: rimossi i due `f:static_text` in fondo al
  dialog (`ffmpegStatus` e `ffmpegWarningText`, introdotti in 0.2.0).
  `props.ffmpegPath`/`ffmpegStatus` restano internamente (servono ancora
  alla validazione che blocca "Crea timelapse" con un messaggio se ffmpeg
  non è configurato), semplicemente non vengono più renderizzati come testo
  permanente nel dialog.
- **`PluginInfoProvider.lua`**: nessuna modifica, resta l'unico posto dove
  percorso/versione/avviso versione minima sono visibili in modo persistente.

### 4. Interruzione del processo di esportazione — ✅ implementato

Oggi solo la fase di export dei fotogrammi è annullabile
(`exportScope:setCancelable(true)` + `isCanceled()` nel loop di
`FrameExporter.export`); la fase di codifica ffmpeg è bloccante
(`Platform.execute` sincrono dentro `FFmpegRunner.run`) e non annullabile —
limite noto, citato nel README. L'SDK non espone alcun handle di processo
(confermato: `LrTasks.execute` è l'unica primitiva, bloccante, nessun modo
documentato per interromperla dall'esterno). Per renderla annullabile serve
cambiare il meccanismo di esecuzione, non solo aggiungere un flag:

- **`FFmpegRunner.run`**: invece di eseguire ffmpeg in modo bloccante, lo
  lancia in background catturandone il PID reale con `exec`, così il
  processo che riceve il segnale è ffmpeg stesso e non una subshell
  intermedia:
  ```sh
  sh -c 'exec <ffmpeg...> > logfile 2>&1' & echo $! > pidfile
  ```
  La chiamata a `Platform.execute` su questo wrapper ritorna quasi subito
  (il `&` mette in background), quindi il "blocco" torna al chiamante
  immediatamente e il vero lavoro prosegue in background.
- Il poller di progresso già esistente (che legge `-progress` per
  `frame=N`) viene esteso per fare anche:
  - controllare `runCfg.progressScope:isCanceled()` a ogni ciclo;
  - se annullato: `kill -INT <pid>` (stop "pulito", ffmpeg gestisce SIGINT
    per un'uscita ordinata), attesa breve con poll su `kill -0 <pid>`,
    `kill -9 <pid>` come fallback se non è terminato; poi cancella il file
    di output parziale (in caso di annullamento non si conserva nulla) e
    ritorna un esito "canceled" distinto da successo/fallimento;
  - rilevare la fine naturale del processo controllando `progress=end`
    nel file di progress (marcatore che ffmpeg scrive già di serie a fine
    encoding) oppure `kill -0 <pid>` che fallisce; l'esito ok/fallito si
    determina poi controllando che il file di output esista e non sia
    vuoto (niente più bisogno di catturare l'exit code via subshell,
    evitato apposta per poter usare `exec`).
- **`TimelapseDialog.lua`**: `encodeScope:setCancelable(true)` (oggi assente,
  va aggiunto); dopo `FFmpegRunner.run`, gestire il terzo esito "canceled"
  distinguendolo da errore (niente messaggio di errore, solo chiusura pulita
  come già avviene per l'annullamento in fase di export).
- Solo macOS per ora: `kill`/`exec` sono POSIX. Il ramo Windows (già previsto
  come "predisposto ma non implementato" nell'architettura) richiederebbe
  `taskkill /PID` — non affrontato in questa versione.
- **Verificato a livello shell** (fuori Lightroom, con `sh`/`ps`/`kill` reali):
  la tecnica `exec ... & echo $!` cattura davvero il PID di ffmpeg (confermato
  con `ps -p <pid> -o comm` → `/opt/homebrew/bin/ffmpeg`, non una subshell);
  `kill -INT` interrompe l'encoding e `progress=end` non compare (come
  atteso); con preset `veryslow` e molti fotogrammi il grace period può non
  bastare e serve il fallback `kill -9` (per questo portato a 4s). **Non
  ancora verificato dentro Lightroom**: che `LrTasks.execute` nel suo sandbox
  si comporti come il `sh`/`os.execute` usato in questo test manuale (stesso
  parsing di `&`/`exec`), e che il poller (task asincrono separato) legga
  correttamente il `pidfile`.
- Nota: siccome `FFmpegRunner.run` ora è condiviso, anche la preview via
  ffmpeg (`PreviewBuilder`) beneficia della stessa possibilità di
  annullamento in corsa, non solo la codifica finale.

### Correzioni dopo il primo test reale in Lightroom (2026-07-08)

Il primo utilizzo effettivo in Lightroom (log `debugLog/Timelapse_PluginLog.txt`)
ha rivelato due bug non rilevabili dai test fuori-Lightroom, più due richieste
di miglioramento UI:

1. **Slider e frecce dell'anteprima senza effetto** — log:
   *"Yielding is not allowed within a C or metamethod call (inside the
   callback for addObserver for condition previewFrameIndex)"*, ripetuto a
   ogni movimento. Causa: l'observer di `previewFrameIndex` chiamava
   direttamente `LrTasks.startAsyncTask(...)` — le callback di
   `addObserver` girano in un contesto ristretto dove anche solo *avviare*
   un task (non necessariamente farlo yieldare) è vietato, stessa famiglia
   del bug pcall/yield già risolto altrove ma con un innesco più sottile.
   **Fix**: l'observer ora scrive solo variabili semplici (nessuna chiamata
   che possa yieldare); un unico task "watcher" avviato una volta sola
   (fuori da qualunque observer) esegue il debounce e il fetch effettivo,
   fermandosi tramite un flag quando il dialog si chiude.
2. **Versione ffmpeg non visibile in Gestione plug-in** — non era un
   crash: la sezione veniva costruita, ma `bind 'ffmpegStatus'` non aveva
   mai un `bind_to_object` esplicito. A differenza del dialog principale
   (che lo imposta sulla `f:column` radice), le sezioni di
   `LrPluginInfoProvider` **non** si legano automaticamente alla
   propertyTable — assunzione errata fatta in 0.2.0 basandosi su un
   campione Adobe che in realtà non usava alcun binding dinamico. **Fix**:
   avvolto tutto il contenuto della sezione in `f:column { bind_to_object =
   propertyTable, ... }`.
3. **Riorganizzazione UI** — il dialog era cresciuto in una lista piatta di
   righe. Raggruppato con `f:group_box` in quattro sezioni: Anteprima
   (fotogramma statico + slider fuso con l'anteprima MP4, prima separate),
   Formato e velocità, Codifica, Output — con etichette allineate tra i
   gruppi tramite lo stesso `LrView.share 'label'`.
4. **Popup di attesa al caricamento dal menu** — prima solo la fase di
   analisi HDR aveva un indicatore; la lettura dei metadati (che su
   selezioni grandi può richiedere secondi) non ne aveva nessuno. Ora
   un'unica `LrProgressScope` copre l'intera fase di preparazione, con
   didascalia (`setCaption`) che cambia da "lettura metadati" ad "analisi
   HDR". Nota: in Lightroom questo è un indicatore di progresso nell'angolo
   (con barra reale e pulsante annulla), non una finestra modale separata —
   è il meccanismo nativo idiomatico per "attendere con barra di
   caricamento"; se si desidera una vera finestra popup centrale è un lavoro
   aggiuntivo separato.

## Distribuzione

### 5. Compilazione tramite il Lua Compiler dell'SDK — ✅ implementato

Verificato che l'intero plugin compila senza errori con
`AdobeSDK/LrC_15/Lua Compiler/mac/luac` (Lua 5.1.5, lo stesso runtime di
Lightroom) e che il bytecode prodotto è valido (`Lua bytecode, version 5.1`).
Questo sostituisce, per il pacchetto di release, la semplice copia dei
sorgenti `.lua` usata da `scripts/release.sh` in 0.2.0.

- **`scripts/release.sh`**: nella fase di build, ogni file `.lua` del
  plugin — **tranne `Info.lua`** — viene compilato con
  `luac -s -o <dest>/File.lua <src>/File.lua` (stesso nome, estensione
  `.lua` invariata: Lua carica in modo trasparente sorgente o bytecode,
  nessuna configurazione aggiuntiva lato Lightroom). `-s` rimuove le info di
  debug (righe, nomi variabili locali), utile sia per la dimensione sia per
  non esporre troppo il sorgente.
  - `Info.lua` resta sorgente non compilato: è parsato da Lightroom in un
    ambiente ristretto (vedi bug di `require` già risolto in 0.2.0) e non
    è stato ancora verificato dentro Lightroom con il bytecode — scelta
    prudente per non introdurre un secondo problema dello stesso tipo senza
    poterlo testare direttamente.
  - Asset non-Lua (`Icon.png`, `TranslatedStrings_it.txt`) copiati as-is.
- Percorso del compilatore configurabile (variabile d'ambiente, es.
  `ADOBE_LUAC`) con default sul percorso noto sotto `AdobeSDK/`. **Nota**:
  `AdobeSDK/` è in `.gitignore` (non versionato), quindi il compilatore non
  è disponibile su un clone pulito del repository — lo script fallisce con
  un messaggio chiaro se non lo trova, senza tentare di scaricarlo o
  vendorizzarlo nel repo (i termini di ridistribuzione di quel binario
  specifico dell'SDK Adobe non sono chiari; resta un prerequisito locale di
  chi esegue la release, non dei contributori/utenti).
- `scripts/check_version.lua` non cambia (continua a operare sui sorgenti
  `.lua` in `TimelapseCreator.lrdevplugin/`, prima della compilazione).

### 6. Build con ffmpeg integrato — ⏸️ rimandata

Indagine fatta, decisione di procedere rimandata a una versione successiva.
Riepilogo per non ripetere la ricerca:

- La pagina ufficiale ffmpeg.org per macOS rimanda a un solo provider,
  **evermeet.cx**: build statiche **solo x86_64**, compilate con
  `--enable-gpl`, libx264/libx265 inclusi (compatibili con l'uso che ne
  facciamo), firme GPG disponibili.
- Lo stesso sito dichiara esplicitamente di non fornire binari nativi arm64
  e suggerisce di usare i binari Intel via Rosetta 2 su Apple Silicon
  ("senza perdita di prestazioni" — affermazione loro, non verificata da
  noi per un carico intenso come l'encoding x264/x265).
- **Conflitto irrisolto**: la richiesta "solo fonte ufficiale" e "due
  pacchetti separati (arm64 nativo + x86_64)" non sono simultaneamente
  soddisfacibili con questa fonte. Opzioni sul tavolo per quando si
  riprenderà il tema: (a) un solo pacchetto x86_64 via Rosetta 2 per tutti
  i Mac, restando fedeli alla fonte ufficiale; (b) x86_64 da evermeet.cx +
  arm64 da un provider terzo non ufficiale, da individuare con
  approvazione esplicita; (c) build arm64 nativa fatta in proprio (es. via
  Homebrew sulla propria macchina arm64), con la complessità aggiuntiva
  delle dipendenze dinamiche da gestire per la ridistribuzione.
- Implicazioni legali già chiare per quando si procederà: ffmpeg con
  libx264/libx265 richiede build GPL; ridistribuirla dentro un plugin
  GPLv3 è compatibile, ma va incluso il testo di licenza di ffmpeg nel
  pacchetto "con ffmpeg" ed etichettata chiaramente la variante.

## Rischi e punti aperti

1. **Export HDR via SDK** *(rischio principale)* — l'SDK potrebbe non esporre i formati
   HDR del dialog di export di LrC. Da verificare nello spike (Fase 0). Fallback possibili:
   TIFF 16-bit lineare + conversione PQ lato ffmpeg (filtro `zscale`), oppure HDR rimandato.
2. **Ingestione TIFF 16-bit in ffmpeg** — pixel format e tagging colore corretti da
   validare; possibile alternativa PNG 16-bit.
3. **Deflicker a 10-bit** — verificare il comportamento del filtro `deflicker` con
   input ad alta profondità (per l'HDR potrebbe servire disabilitarlo o usare alternative).
4. **Spazio disco** — 4K HDR in TIFF 16-bit ≈ 50–100 MB/frame: con migliaia di foto
   servono avvisi preventivi sullo spazio richiesto e pulizia aggressiva della temp.
5. **Sequenze molto lunghe** — `LrExportSession` su migliaia di foto: gestire batch
   e annullamento senza lasciare orfani su disco.
