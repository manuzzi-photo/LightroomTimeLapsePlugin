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
