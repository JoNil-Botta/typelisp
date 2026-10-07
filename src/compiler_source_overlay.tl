;; compiler_source_overlay.tl - one immutable generation of candidate source
;; bytes for a check, and the ledger of every source that check consumed.
;;
;; A caller admits exact candidate bytes for selected project sources, each
;; named by its canonical physical path (absolute and lexically normalized).
;; Admission rejects the table as a whole before any checking starts:
;; duplicate identities, non-canonical or out-of-root paths, destinations that
;; do not exist on disk, a disk file whose bytes no longer match the content the
;; caller planned its edit against, and count or byte limits. The loader then
;; resolves imports and packages exactly as before and answers only an admitted
;; resolved source from the overlay, so an overlay can change what a file says
;; but never which file an import names.
;;
;; The ledger records each source the check consumed, in the order the loader
;; first consumed it: its class (disk, embedded stdlib or overlay), canonical
;; physical path, logical path (the loader's own spelling of the resolved path,
;; which is also what diagnostics show), content identity
;; (byte length and SHA-256 of the exact bytes, as `sha256sum` prints it) and,
;; for a disk read, whether it came from the filesystem. A repeated read of the same
;; source is recorded once; a repeated read that sees different bytes fails the
;; check. The ledger lives in the arena its owner created it in, so it outlives
;; the loader's per-file scratch and pool resets. Revalidating it re-reads every
;; disk entry, which lets a caller that later writes files detect an input that
;; went stale in between.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (stdlib.vector.vector String) as source_path_vec)

;; Stable failure reasons; callers compare these, not the messages.
(define compiler-source-overlay-error-limits : i64
  1)
(define compiler-source-overlay-error-generation : i64
  2)
(define compiler-source-overlay-error-count : i64
  3)
(define compiler-source-overlay-error-bytes : i64
  4)
(define compiler-source-overlay-error-path : i64
  5)
(define compiler-source-overlay-error-duplicate : i64
  6)
(define compiler-source-overlay-error-missing : i64
  7)
(define compiler-source-overlay-error-stale-base : i64
  8)
(define compiler-source-overlay-error-content : i64
  9)
(define compiler-source-overlay-error-ledger-limit : i64
  10)
(define compiler-source-overlay-error-changed : i64
  11)
(define compiler-source-overlay-error-unread : i64
  12)
(define compiler-source-overlay-error-not-editable : i64
  13)

(defstruct CompilerSourceOverlayLimits
  (max-entries i64)
  (max-total-bytes i64)
  (max-path-bytes i64)
  (max-ledger-entries i64)
  (max-ledger-path-bytes i64))

(define (compiler-source-overlay-default-limits) : CompilerSourceOverlayLimits
  (CompilerSourceOverlayLimits 4096 268435456 4096 65536 16777216))

(defstruct CompilerSourceOverlayError
  (code i64)
  (path String)
  (message String))

;; The identity of exact source bytes: their length and lower-case hex SHA-256.
(defstruct CompilerSourceContent
  (length i64)
  (sha256 String))

;; What a caller knows about the file its candidate replaces: nothing, or the
;; content identity it planned its edit against.
(defenum CompilerSourceOverlayBase
  (Any)
  (Expect CompilerSourceContent))

;; One requested replacement of the file at canonical `path`.
(defstruct CompilerSourceOverlayInput
  (path String)
  (bytes String)
  (base CompilerSourceOverlayBase))

(defstruct CompilerSourceOverlayEntry
  (path String)
  (bytes String)
  (content CompilerSourceContent))

(import (stdlib.vector.vector CompilerSourceOverlayInput core) as overlay_input_vec)
(import (stdlib.vector.vector CompilerSourceOverlayEntry core) as overlay_entry_vec)

;; An admitted generation. `cwd` is the directory relative loader paths were
;; resolved against when the table was admitted; lookups never consult the
;; process working directory again.
(defstruct CompilerSourceOverlay
  (generation i64)
  (root String)
  (cwd String)
  (entries overlay_entry_vec.Vec)
  (limits CompilerSourceOverlayLimits))

(defenum ResultCompilerSourceOverlay
  (Ok CompilerSourceOverlay)
  (Err CompilerSourceOverlayError))

(defenum CompilerSourceClass
  (Disk)
  (Embedded)
  (Overlay))

(defstruct CompilerSourceLedgerEntry
  (class CompilerSourceClass)
  (path String)
  (logical-path String)
  (content CompilerSourceContent))

(import (stdlib.vector.vector CompilerSourceLedgerEntry core) as ledger_entry_vec)

;; The ledger of one check. `failure` holds the first recording failure; once it
;; is set the check's result must not be published.
(defstruct CompilerSourceLedger
  (entries ledger_entry_vec.Vec)
  (path-bytes i64)
  (limits CompilerSourceOverlayLimits)
  (failure (__tl_dyn-array CompilerSourceOverlayError))
  (failed bool))

(defenum ResultCompilerSourceContent
  (Ok CompilerSourceContent)
  (Err CompilerSourceOverlayError))

(defenum CompilerSourceOverlayStatus
  (Ok)
  (Err CompilerSourceOverlayError))

(define (compiler-source-overlay-error
  [code : i64]
  [path : (& path str)]
  [message : (& message str)]) : CompilerSourceOverlayError
  (CompilerSourceOverlayError code (string.copy path) (string.copy message)))

(define (compiler-source-string-array [text : (& text str)]) : (__tl_dyn-array
    u8)
  (byte_buf.to-array (byte_buf.from-string (string.copy text))))

;; The content identity of exact bytes, hashed in place.
(define (compiler-source-content-identity
  [path : (& path str)]
  [text : (& text str)]) : ResultCompilerSourceContent
  (match (sha256.digest (byte_buf.str-as-bytes text))
    [(Sha256FinalizeOk digest)
      (Ok
        (CompilerSourceContent
          (string.string-length text)
          (sha256.to-hex (& digest))))]
    [(Sha256FinalizeErr _)
      (Err
        (compiler-source-overlay-error
          compiler-source-overlay-error-content
          path
          "SHA-256 rejected the source bytes"))]))

;; Owned copies of values held in borrowed tables.
(define (compiler-source-class-copy [class : (& class CompilerSourceClass)]) : CompilerSourceClass
  (match class
    [(Disk) (Disk)]
    [(Embedded) (Embedded)]
    [(Overlay) (Overlay)]))

(define (compiler-source-content-copy
  [content : (& content CompilerSourceContent)]) : CompilerSourceContent
  (CompilerSourceContent content.length (string.copy (& content.sha256))))

(define (compiler-source-overlay-input-copy
  [input : (& input CompilerSourceOverlayInput)]) : CompilerSourceOverlayInput
  (CompilerSourceOverlayInput
    (string.copy (& input.path))
    (string.copy (& input.bytes))
    (match (& input.base)
      [(Any) (Any)]
      [(Expect content) (Expect (compiler-source-content-copy content))])))

(define (compiler-source-content-eq?
  [left : (& left CompilerSourceContent)]
  [right : (& right CompilerSourceContent)]) : bool
  (and
    (= left.length right.length)
    (string.eq (& left.sha256) (& right.sha256))))

;; `text` with ASCII upper-case letters lowered.
(define (compiler-source-ascii-lower [text : (& text str)]) : String
  (let
    [bytes : (__tl_dyn-array u8) (compiler-source-string-array text)]
    [count : i64 (array-length bytes)]
    [index : i64 0]
    (while (< index count)
      (let
        [byte : u8 (array-ref bytes index)]
        (if (and (>= byte (cast 65 : u8)) (<= byte (cast 90 : u8)))
          (set! (array-ref bytes index) (+ byte (cast 32 : u8)))
          unit)
        (set! index (+ index 1))))
    (byte_buf.to-string (byte_buf.from-array bytes))))

;; Windows file names compare case-insensitively (ASCII); every other host
;; compares exact bytes.
(define (compiler-source-path-fold [path : (& path str)]) : String
  (cfg windows (compiler-source-ascii-lower path) (string.copy path)))

(define (compiler-source-path-eq? [left : (& left str)] [right : (& right str)]) : bool
  (string.eq (compiler-source-path-fold left) (compiler-source-path-fold right)))

;; True when `path` is absolute and already in `fs.path-normalize` form.
(define (compiler-source-path-canonical? [path : (& path str)]) : bool
  (and (fs.path-absolute? path) (string.eq path (fs.path-normalize path))))

;; The canonical physical path of a loader path, resolving a relative one
;; against the admitted working directory.
(define (compiler-source-canonical-path
  [cwd : (& cwd str)]
  [path : (& path str)]) : String
  (if (fs.path-absolute? path)
    (fs.path-normalize path)
    (fs.path-normalize (fs.path-join cwd path))))

;; Overlays replace TypeLisp sources only, never the manifests or other inputs
;; that decide which source an import names.
(define (compiler-source-tl-path? [path : (& path str)]) : bool
  (let
    [length : i64 (string.string-length path)]
    (and (> length 3) (string.eq (string.substring path (- length 3) 3) ".tl"))))

;; True when canonical `path` is `root` or below it. A filesystem root (`/`,
;; `C:/`) is the only canonical path that ends in its separator.
(define (compiler-source-path-under?
  [root : (& root str)]
  [path : (& path str)]) : bool
  (let
    [root-folded : String (compiler-source-path-fold root)]
    [path-folded : String (compiler-source-path-fold path)]
    [root-length : i64 (string.string-length root-folded)]
    (cond
      [(string.eq (& path-folded) (& root-folded)) true]
      [(= root-length 0) false]
      [(<= (string.string-length path-folded) root-length) false]
      [(not
          (string.eq
            (string.substring (& path-folded) 0 root-length)
            (& root-folded)))
        false]
      [else
        (or
          (= (string.string-ref root-folded (- root-length 1)) '/')
          (= (string.string-ref path-folded root-length) '/'))])))

(define (compiler-source-read-text [path : (& path str)]) : io.ResultIoString
  (let
    [bytes (try (io.try-read-file path))]
    (OkIoString (byte_buf.to-string bytes))))

;; An empty admission request and a way to add one replacement to it.
(define (compiler-source-overlay-inputs) : overlay_input_vec.Vec
  (overlay_input_vec.new))

(define (compiler-source-overlay-inputs-push!
  [inputs : (&mut inputs overlay_input_vec.Vec)]
  [path : String]
  [bytes : String]
  [base : CompilerSourceOverlayBase]) : unit
  (overlay_input_vec.push-ref!
    inputs
    (CompilerSourceOverlayInput path bytes base)))

;; Admit one generation. `root` bounds every entry (canonical, like the paths)
;; and `cwd` is the absolute directory relative loader paths resolve against.
(define (compiler-source-overlay-admit
  [generation : i64]
  [root : String]
  [cwd : String]
  [inputs : overlay_input_vec.Vec]
  [limits : CompilerSourceOverlayLimits]) : ResultCompilerSourceOverlay
  (let
    [count : i64 (overlay_input_vec.len (& inputs))]
    [entries : overlay_entry_vec.Vec (overlay_entry_vec.with-capacity count)]
    [total : i64 0]
    [index : i64 0]
    [failure : CompilerSourceOverlayError
      (compiler-source-overlay-error 0 "" "")]
    [failed : bool false]
    (cond
      [(or
        (< limits.max-entries 0)
        (< limits.max-total-bytes 0)
        (< limits.max-path-bytes 1)
        (< limits.max-ledger-entries 0)
        (< limits.max-ledger-path-bytes 0))
        (set!
          failure
          (compiler-source-overlay-error
            compiler-source-overlay-error-limits
            ""
            "overlay limits are invalid"))
        (set! failed true)]
      [(< generation 1)
        (set!
          failure
          (compiler-source-overlay-error
            compiler-source-overlay-error-generation
            ""
            "overlay generation must be positive"))
        (set! failed true)]
      [(> count limits.max-entries)
        (set!
          failure
          (compiler-source-overlay-error
            compiler-source-overlay-error-count
            ""
            "overlay has more entries than its limit"))
        (set! failed true)]
      [(or
        (not (compiler-source-path-canonical? (& root)))
        (not (compiler-source-path-canonical? (& cwd))))
        (set!
          failure
          (compiler-source-overlay-error
            compiler-source-overlay-error-path
            (& root)
            "overlay root and working directory must be canonical absolute paths"))
        (set! failed true)]
      [else unit])
    (while (and (not failed) (< index count))
      (let
        [input-slots (overlay_input_vec.slots (& inputs))]
        [input : CompilerSourceOverlayInput
          (compiler-source-overlay-input-copy (& (array-ref input-slots index)))]
        [size : i64 (string.string-length (& input.bytes))]
        [duplicate : bool
          (let
            [earlier : i64 0]
            [seen : bool false]
            (while (and (not seen) (< earlier index))
              (let
                [slots (overlay_input_vec.slots (& inputs))]
                (if (compiler-source-path-eq?
                  (& (array-ref slots earlier).path)
                  (& input.path))
                  (set! seen true)
                  unit)
                (set! earlier (+ earlier 1))))
            seen)]
        (cond
          [(or
            (> (string.string-length (& input.path)) limits.max-path-bytes)
            (not (compiler-source-path-canonical? (& input.path)))
            (not (compiler-source-path-under? (& root) (& input.path)))
            (not (compiler-source-tl-path? (& input.path))))
            (set!
              failure
              (compiler-source-overlay-error
                compiler-source-overlay-error-path
                (& input.path)
                "overlay path must be a canonical absolute .tl path under the overlay root"))
            (set! failed true)]
          [duplicate
            (set!
              failure
              (compiler-source-overlay-error
                compiler-source-overlay-error-duplicate
                (& input.path)
                "overlay names the same source twice"))
            (set! failed true)]
          [(or (> size (- limits.max-total-bytes total)) (< size 0))
            (set!
              failure
              (compiler-source-overlay-error
                compiler-source-overlay-error-bytes
                (& input.path)
                "overlay bytes exceed their limit"))
            (set! failed true)]
          [else
            (match (compiler-source-read-text (& input.path))
              [(ErrIoString _)
                (set!
                  failure
                  (compiler-source-overlay-error
                    compiler-source-overlay-error-missing
                    (& input.path)
                    "overlay source does not exist on disk"))
                (set! failed true)]
              [(OkIoString disk-text)
                (match (compiler-source-overlay-base-check
                  (& input.path)
                  (& disk-text)
                  (& input.base))
                  [(Err base-failure)
                    (set! failure base-failure)
                    (set! failed true)]
                  [(Ok)
                    (match (compiler-source-content-identity
                      (& input.path)
                      (& input.bytes))
                      [(Err content-failure)
                        (set! failure content-failure)
                        (set! failed true)]
                      [(Ok content)
                        (overlay_entry_vec.push-ref!
                          (&mut entries)
                          (CompilerSourceOverlayEntry
                            (string.copy (& input.path))
                            (string.copy (& input.bytes))
                            content))
                        (set! total (+ total size))])])])])
        (set! index (+ index 1))))
    (if failed
      (Err failure)
      (Ok (CompilerSourceOverlay generation root cwd entries limits)))))

;; Check a destination's current disk bytes against the base its candidate was
;; planned from.
(define (compiler-source-overlay-base-check
  [path : (& path str)]
  [disk-text : (& disk-text str)]
  [base : (& base CompilerSourceOverlayBase)]) : CompilerSourceOverlayStatus
  (match base
    [(Any) (Ok)]
    [(Expect expected)
      (let
        [current (try (compiler-source-content-identity path disk-text))]
        (if (compiler-source-content-eq? (& current) expected)
          (Ok)
          (Err
            (compiler-source-overlay-error
              compiler-source-overlay-error-stale-base
              path
              "overlay source changed on disk since its candidate was planned"))))]))

;; Reject an overlay that replaces a source below `root` (canonicalized against
;; the overlay's working directory): stdlib and other shared roots are not
;; editable through an overlay.
(define (compiler-source-overlay-check-not-under
  [overlay : (& overlay CompilerSourceOverlay)]
  [root : (& root str)]) : CompilerSourceOverlayStatus
  (let
    [canonical-root : String
      (compiler-source-canonical-path (& overlay.cwd) root)]
    [count : i64 (overlay_entry_vec.len (& overlay.entries))]
    [index : i64 0]
    [offender : i64 -1]
    (while (and (< offender 0) (< index count))
      (let
        [slots (overlay_entry_vec.slots (& overlay.entries))]
        (if (compiler-source-path-under?
          (& canonical-root)
          (& (array-ref slots index).path))
          (set! offender index)
          unit)
        (set! index (+ index 1))))
    (if (< offender 0)
      (Ok)
      (let
        [entry : CompilerSourceOverlayEntry
          (compiler-source-overlay-entry overlay offender)]
        (Err
          (compiler-source-overlay-error
            compiler-source-overlay-error-not-editable
            (& entry.path)
            "overlay replaces a source below a stdlib root"))))))

;; The empty overlay: every source is read as it would be without one.
(define (compiler-source-overlay-empty [cwd : String]) : CompilerSourceOverlay
  (CompilerSourceOverlay
    0
    (string.copy (& cwd))
    cwd
    (overlay_entry_vec.new)
    (compiler-source-overlay-default-limits)))

(define (compiler-source-overlay-entry-count
  [overlay : (& overlay CompilerSourceOverlay)]) : i64
  (overlay_entry_vec.len (& overlay.entries)))

;; The index of the admitted entry for canonical `path`, or -1.
(define (compiler-source-overlay-find
  [overlay : (& overlay CompilerSourceOverlay)]
  [path : (& path str)]) : i64
  (let
    [count : i64 (overlay_entry_vec.len (& overlay.entries))]
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index count))
      (let
        [slots (overlay_entry_vec.slots (& overlay.entries))]
        (if (compiler-source-path-eq? (& (array-ref slots index).path) path)
          (set! found index)
          unit)
        (set! index (+ index 1))))
    found))

(define (compiler-source-overlay-entry
  [overlay : (& overlay CompilerSourceOverlay)]
  [index : i64]) : CompilerSourceOverlayEntry
  (let
    [slots (overlay_entry_vec.slots (& overlay.entries))]
    [entry (& (array-ref slots index))]
    (CompilerSourceOverlayEntry
      (string.copy (& entry.path))
      (string.copy (& entry.bytes))
      (compiler-source-content-copy (& entry.content)))))

;; The admitted bytes of entry `index`, without copying them: the loader parses
;; them in place, and the overlay outlives the check.
(define (compiler-source-overlay-entry-bytes
  [overlay : (& overlay CompilerSourceOverlay)]
  [index : i64]) : String
  (let
    [slots (overlay_entry_vec.slots (& overlay.entries))]
    (owned_view.compiler-owned-string-place-shared-view
      (array-ref slots index).bytes)))

(define (compiler-source-overlay-entry-content
  [overlay : (& overlay CompilerSourceOverlay)]
  [index : i64]) : CompilerSourceContent
  (let
    [slots (overlay_entry_vec.slots (& overlay.entries))]
    (compiler-source-content-copy (& (array-ref slots index).content))))

(define (compiler-source-ledger-new [limits : CompilerSourceOverlayLimits]) : CompilerSourceLedger
  (CompilerSourceLedger
    (ledger_entry_vec.new)
    0
    limits
    (__tl_make-array (compiler-source-overlay-error 0 "" ""))
    false))

(define (compiler-source-ledger-count
  [ledger : (& ledger CompilerSourceLedger)]) : i64
  (ledger_entry_vec.len (& ledger.entries)))

(define (compiler-source-ledger-get
  [ledger : (& ledger CompilerSourceLedger)]
  [index : i64]) : CompilerSourceLedgerEntry
  (let
    [slots (ledger_entry_vec.slots (& ledger.entries))]
    [entry (& (array-ref slots index))]
    (CompilerSourceLedgerEntry
      (compiler-source-class-copy (& entry.class))
      (string.copy (& entry.path))
      (string.copy (& entry.logical-path))
      (compiler-source-content-copy (& entry.content)))))

(define (compiler-source-ledger-failed?
  [ledger : (& ledger CompilerSourceLedger)]) : bool
  ledger.failed)

(define (compiler-source-ledger-failure
  [ledger : (& ledger CompilerSourceLedger)]) : CompilerSourceOverlayError
  (let
    [failure (& (array-ref ledger.failure 0))]
    (CompilerSourceOverlayError
      failure.code
      (string.copy (& failure.path))
      (string.copy (& failure.message)))))

(define (compiler-source-ledger-fail!
  [ledger : (&mut ledger CompilerSourceLedger)]
  [failure : CompilerSourceOverlayError]) : unit
  (unless
    ledger.failed
    (set! (array-ref ledger.failure 0) failure)
    (set! ledger.failed true)))

;; Record one consumed source. An identity already recorded is not recorded
;; again; if its bytes differ the ledger fails, since the check then saw two
;; versions of one source.
(define (compiler-source-ledger-record!
  [ledger : (&mut ledger CompilerSourceLedger)]
  [class : CompilerSourceClass]
  [path : (& path str)]
  [logical-path : (& logical-path str)]
  [content : CompilerSourceContent]) : unit
  (if ledger.failed
    unit
    (let
      [existing : i64 (compiler-source-ledger-find (& (deref ledger)) path)]
      [count : i64 (compiler-source-ledger-count (& (deref ledger)))]
      (cond
        [(>= existing 0)
          (if (compiler-source-ledger-content-matches?
            (& (deref ledger))
            existing
            (& content))
            unit
            (compiler-source-ledger-fail!
              ledger
              (compiler-source-overlay-error
                compiler-source-overlay-error-changed
                path
                "a source changed while the check was reading it")))]
        [(or
            (>= count ledger.limits.max-ledger-entries)
            (>
              (+
                (string.string-length path)
                (string.string-length logical-path))
              (- ledger.limits.max-ledger-path-bytes ledger.path-bytes)))
          (compiler-source-ledger-fail!
            ledger
            (compiler-source-overlay-error
              compiler-source-overlay-error-ledger-limit
              path
              "the check read more sources than its ledger limit"))]
        [else
          (ledger_entry_vec.push-ref!
            (&mut ledger.entries)
            (CompilerSourceLedgerEntry
              class
              (string.copy path)
              (string.copy logical-path)
              content))
          (set!
            ledger.path-bytes
            (+
              ledger.path-bytes
              (string.string-length path)
              (string.string-length logical-path)))]))))

(define (compiler-source-ledger-content-matches?
  [ledger : (& ledger CompilerSourceLedger)]
  [index : i64]
  [content : (& content CompilerSourceContent)]) : bool
  (let
    [slots (ledger_entry_vec.slots (& ledger.entries))]
    (compiler-source-content-eq? (& (array-ref slots index).content) content)))

;; Record `text` as consumed from `path` under `class`.
(define (compiler-source-ledger-record-text!
  [ledger : (&mut ledger CompilerSourceLedger)]
  [class : CompilerSourceClass]
  [path : (& path str)]
  [logical-path : (& logical-path str)]
  [text : (& text str)]) : unit
  (if ledger.failed
    unit
    (match (compiler-source-content-identity path text)
      [(Err failure) (compiler-source-ledger-fail! ledger failure)]
      [(Ok content)
        (compiler-source-ledger-record! ledger class path logical-path content)])))

;; Canonical paths of the ledger's disk entries whose bytes differ from the
;; recorded content, or that can no longer be read. Embedded and overlay
;; entries do not depend on the filesystem.
(define (compiler-source-ledger-stale-paths
  [ledger : (& ledger CompilerSourceLedger)]) : source_path_vec.Vec
  (let
    [count : i64 (ledger_entry_vec.len (& ledger.entries))]
    [index : i64 0]
    [stale : source_path_vec.Vec (source_path_vec.new)]
    (while (< index count)
      (let
        [entry : CompilerSourceLedgerEntry
          (compiler-source-ledger-get ledger index)]
        (match entry.class
          [(Disk)
            (let
              [current : bool
                (match (compiler-source-read-text (& entry.path))
                  [(ErrIoString _) false]
                  [(OkIoString text)
                    (match (compiler-source-content-identity
                      (& entry.path)
                      (& text))
                      [(Err _) false]
                      [(Ok content)
                        (compiler-source-content-eq?
                          (& content)
                          (& entry.content))])])]
              (if current
                unit
                (source_path_vec.push-ref!
                  (&mut stale)
                  (string.copy (& entry.path)))))]
          [_ unit])
        (set! index (+ index 1))))
    stale))

;; Check that every admitted entry was consumed by the check. An entry the
;; check never read proves nothing about the candidate generation, so a caller
;; that relies on one is told which.
(define (compiler-source-overlay-unread
  [overlay : (& overlay CompilerSourceOverlay)]
  [ledger : (& ledger CompilerSourceLedger)]) : source_path_vec.Vec
  (let
    [count : i64 (overlay_entry_vec.len (& overlay.entries))]
    [index : i64 0]
    [unread : source_path_vec.Vec (source_path_vec.new)]
    (while (< index count)
      (let
        [entry : CompilerSourceOverlayEntry
          (compiler-source-overlay-entry overlay index)]
        [recorded : i64 (compiler-source-ledger-find ledger (& entry.path))]
        (if (and
          (>= recorded 0)
          (match (compiler-source-ledger-get ledger recorded).class
            [(Overlay) true]
            [_ false]))
          unit
          (source_path_vec.push-ref! (&mut unread) (string.copy (& entry.path))))
        (set! index (+ index 1))))
    unread))

(define (compiler-source-ledger-find
  [ledger : (& ledger CompilerSourceLedger)]
  [path : (& path str)]) : i64
  (let
    [count : i64 (ledger_entry_vec.len (& ledger.entries))]
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index count))
      (let
        [slots (ledger_entry_vec.slots (& ledger.entries))]
        (if (compiler-source-path-eq? (& (array-ref slots index).path) path)
          (set! found index)
          unit)
        (set! index (+ index 1))))
    found))