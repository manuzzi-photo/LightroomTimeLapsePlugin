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
selezione percorso. Mancano: CI GitHub Actions (unit test + luacheck),
packaging `.lrplugin` di release, test e rifinitura Windows.

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
