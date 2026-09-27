;; Build-configured embedded stdlib comptime image and production loader path.
(import stdlib.str_cat_runtime as str_cat)
(cfg test (import compiler_embedded_stdlib_tlci_payload_seed as payload))
(cfg (not test) (import compiler_embedded_stdlib_tlci_payload as payload))
(import compiler_embedded_stdlib_tlci_codec as codec)
(import tlci_loader as loader)

;; compiler_ctfe instantiates (hashmap i64 i64); the generated-module import
;; needs stdlib.hashmap in this program graph even though full compiler
;; builds get it from other modules (small graphs like the embedded verifier
;; would otherwise fail the instantiation).
;; lint-allow: unused-import -- the generated-map instantiation needs it.
(import stdlib.hashmap)
(import tlci_core as tlci)
(import stdlib.comptime)
(import compiler_ast_types as ast)
(import compiler_ctfe as ctfe_support)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.string)

;; Native-comptime session cells are process-global owner slots. Read-only
;; callbacks intentionally share their live contents; make that shallow view
;; explicit.
(defmacro (compiler-comptime-host-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

;; Global host arrays retain their elements across native callback boundaries.
;; Reading one is a shallow compiler-owned view, never an ownership transfer
;; out of the durable session slot.
(defmacro (compiler-comptime-host-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defenum CompilerEmbeddedStdlibTlciValidation
  (Ok i64)
  (Err String))

(defenum CompilerEmbeddedStdlibTlciLookup
  (Resolved loader.TlciResolvedMacroEntry)
  (Shell loader.TlciResolvedMacroEntry)
  (Missing)
  (Unavailable String))

(defenum CompilerEmbeddedStdlibTlciSurface
  (Ok String String (__tl_dyn-array u8))
  (Unavailable String))

(define (compiler-embedded-stdlib-tlci-compressed-shared-view) : (__tl_dyn-array
    u8)
  (unsafe
    (ptr-read (ptr-addr-of payload.embedded-stdlib-tlci-bytes))))

;; The compiler maps the image lazily on the first embedded-stdlib macro call
;; and keeps it mapped through that macro-expansion pass. State values are
;; 0 = closed, 1 = loaded, and -1 = load failed. The separate cells avoid
;; requiring an artificial zero-value TlciLoadedImage enum variant.
(define compiler-embedded-stdlib-tlci-session-state : (__tl_dyn-array i64)
  (__tl_make-array 0))
(define compiler-embedded-stdlib-tlci-session-image : (__tl_dyn-array
    loader.TlciLoadedImage)
  (__tl_make-array loader.TlciLoadedImage 1))
(define compiler-embedded-stdlib-tlci-session-error : (__tl_dyn-array String)
  (__tl_make-array ""))

;; #5926: bounded lifecycle evidence for the production-route stress compiler.
;; These cells are absent from ordinary/published builds. They count successful
;; image maps, releases, and callback-host sessions across compile --batch pool
;; resets; paired canaries make the durable checkpoint fail closed if the old
;; sustained-dispatch corruption reaches adjacent compiler globals.
(cfg
  tlci-native-route-stress
  (define compiler-embedded-stdlib-tlci-stress-image-generations : i64
    0))
(cfg
  tlci-native-route-stress
  (define compiler-embedded-stdlib-tlci-stress-release-generations : i64
    0))
(cfg
  tlci-native-route-stress
  (define compiler-embedded-stdlib-tlci-stress-session-generations : i64
    0))
(cfg
  tlci-native-route-stress
  (define compiler-embedded-stdlib-tlci-stress-canary-a : i64
    610839776))
(cfg
  tlci-native-route-stress
  (define compiler-embedded-stdlib-tlci-stress-canary-b : i64
    270544960))

(cfg
  tlci-native-route-stress
  (define (compiler-embedded-stdlib-tlci-stress-image-generation) : i64
    compiler-embedded-stdlib-tlci-stress-image-generations))

(cfg
  tlci-native-route-stress
  (define (compiler-embedded-stdlib-tlci-stress-release-generation) : i64
    compiler-embedded-stdlib-tlci-stress-release-generations))

(cfg
  tlci-native-route-stress
  (define (compiler-embedded-stdlib-tlci-stress-session-generation) : i64
    compiler-embedded-stdlib-tlci-stress-session-generations))

(cfg
  tlci-native-route-stress
  (define (compiler-embedded-stdlib-tlci-stress-canaries-ok?) : bool
    (and
      (= compiler-embedded-stdlib-tlci-stress-canary-a 610839776)
      (= compiler-embedded-stdlib-tlci-stress-canary-b 270544960))))

(define (compiler-embedded-stdlib-tlci-session-image-shared-view) : loader.TlciLoadedImage
  (unsafe
    (ptr-read
      (ptr-offset
        (__tl_array-data compiler-embedded-stdlib-tlci-session-image)
        0))))

(define (compiler-embedded-stdlib-tlci-session-error-shared-view) : String
  (unsafe
    (ptr-read
      (ptr-offset
        (__tl_array-data compiler-embedded-stdlib-tlci-session-error)
        0))))

;; R3-P2d. The session is opened LAZILY, from inside whatever the compiler
;; happens to be doing when the first embedded-stdlib macro fires, and it is
;; then read by every later macro call in the pass. Under the R3-P1 macro walk
;; that first call lands inside a firing declaration's arena generation, which
;; is destroyed a couple of batches later -- so anything the session retains
;; that was allocated in "whatever arena is current" is a use-after-free at the
;; next dispatch. Measured: the image was mapped in the generation covering
;; declarations 33-64, that generation was destroyed entering declaration 97,
;; and declaration 98's dispatch read the freed host callback table.
;;
;; The session therefore owns an arena, and that arena is created once and
;; NEVER destroyed or reset -- the same shape, and for the same reason, as
;; `compiler-ir-label-arena`. Two consequences are deliberate:
;;
;; * Nothing allocated here can ever dangle, whatever a later packet does to
;;   the arenas around it. The bug being fixed is a dangling read; an owner
;;   that is never released cannot reintroduce one, and it needs no
;;   head-tracking to keep an overflow segment reachable for a destroy that
;;   does not happen (H4).
;; * The retention is two 8-word arrays, the loader's one-element liveness
;;   cell, and at most one failure message per process. The payload bytes and
;;   parse, which are megabytes, are the driver surface's (owned by its surface
;;   arena) or a copy in the caller's current arena that is dropped with it, so
;;   this does not move the macro-walk peak.
(define compiler-embedded-stdlib-tlci-session-arena-handle : i64
  0)

(define (compiler-embedded-stdlib-tlci-session-arena) : i64
  (begin
    (if (= compiler-embedded-stdlib-tlci-session-arena-handle 0)
      (set!
        compiler-embedded-stdlib-tlci-session-arena-handle
        (arena.tl_arena_make_small))
      unit)
    compiler-embedded-stdlib-tlci-session-arena-handle))

;: A copy of `text` owned by the session arena. Loader messages are built in
;: whatever arena was current at the load, and the load-failure state is sticky
;: for the whole pass, so the message it hands back must not be.
(define (compiler-embedded-stdlib-tlci-session-own-text [text : String]) : String
  (in-arena
    (arena.Arena (compiler-embedded-stdlib-tlci-session-arena))
    (string.substring (& text) 0 (string.string-length text))))

;; The image is embedded through a TLCI-only canonical-Huffman layer over the
;; proven LZSS matches. The ordinary `.tlci` bytes are restored before the
;; existing parser and mapper, while the source fallback retains its separate
;; lazy per-module `include-str-lzss` payloads and decoder.
;;
;; Expansion is per call, exactly where the byte copy used to be: the decoded
;; image is transient working memory owned by whatever arena the caller made
;; current, and caching it for the process would retain megabytes. The one
;; reuse is the driver's surface expansion below, whose owner already keeps it.
;; 256 MiB is far above the current image while bounding a corrupt static
;; length before allocation.
(define (compiler-embedded-stdlib-tlci-raw-limit) : i64
  268435456)

;; Uncompressed image length. Zero means "no image in this build" -- the seed
;; and test payloads are empty rather than compressed -- and every caller
;; treats that as unavailable before touching the bytes.
(define (compiler-embedded-stdlib-tlci-length) : i64
  (let
    [compressed : (__tl_dyn-array u8)
      (compiler-embedded-stdlib-tlci-compressed-shared-view)]
    (if (= (array-length compressed) 0)
      0
      (match (codec.compiler-embedded-stdlib-tlci-codec-frame
        (& compressed)
        (compiler-embedded-stdlib-tlci-raw-limit))
        [(codec.CompilerEmbeddedStdlibTlciCodecFrame.Ok raw-len _ _) raw-len]
        [(codec.CompilerEmbeddedStdlibTlciCodecFrame.Err _)
          (begin
            (string.tl_oob_abort)
            0)]))))

(define (compiler-embedded-stdlib-tlci-copy) : (__tl_dyn-array u8)
  (let
    [compressed : (__tl_dyn-array u8)
      (compiler-embedded-stdlib-tlci-compressed-shared-view)]
    (if (= (array-length compressed) 0)
      (__tl_make-array u8 0)
      (match (codec.compiler-embedded-stdlib-tlci-codec-decode
        (& compressed)
        (compiler-embedded-stdlib-tlci-raw-limit))
        [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Ok bytes) bytes]
        [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Err _)
          (begin
            (string.tl_oob_abort)
            (__tl_make-array u8 0))]))))

;; The one expansion a driver's prelude surface made, and the arena holding it.
;; The driver builds its surface with its own surface arena current, so those
;; bytes already stay mapped for the driver state's whole lifetime; the session
;; open that follows in that lifetime (and any nested package's surface) maps
;; the same bytes instead of expanding the 16 MB image again, which was a tenth
;; of a mid-sized compile. Nothing outlives its owner: the driver forgets the
;; bytes before it destroys that arena, and a session opened with no surface
;; still expands into the caller's current arena as before.
(define compiler-embedded-stdlib-tlci-decoded-owner : i64
  0)
(define compiler-embedded-stdlib-tlci-decoded : (__tl_dyn-array
    (__tl_dyn-array u8))
  (__tl_make-array (__tl_dyn-array u8) 1))

(define (compiler-embedded-stdlib-tlci-decoded-shared-view) : (__tl_dyn-array
    u8)
  (unsafe
    (ptr-read
      (ptr-offset (__tl_array-data compiler-embedded-stdlib-tlci-decoded) 0))))

;; The expanded image: the surface's bytes while their owner is alive, else a
;; fresh expansion in the caller's current arena.
(define (compiler-embedded-stdlib-tlci-image-bytes) : (__tl_dyn-array u8)
  (if (= compiler-embedded-stdlib-tlci-decoded-owner 0)
    (compiler-embedded-stdlib-tlci-copy)
    (compiler-embedded-stdlib-tlci-decoded-shared-view)))

;; `owner` must be the current arena, and must stay alive until the caller
;; passes it to `compiler-embedded-stdlib-tlci-forget-decoded!`.
(define (compiler-embedded-stdlib-tlci-surface-bytes [owner : i64]) : (__tl_dyn-array
    u8)
  (if (= compiler-embedded-stdlib-tlci-decoded-owner 0)
    (let
      [bytes : (__tl_dyn-array u8) (compiler-embedded-stdlib-tlci-copy)]
      (begin
        (set!
          (array-ref compiler-embedded-stdlib-tlci-decoded 0)
          (owned_view.compiler-owned-shared-view bytes))
        (set! compiler-embedded-stdlib-tlci-decoded-owner owner)
        bytes))
    (compiler-embedded-stdlib-tlci-decoded-shared-view)))

;; Called before `owner` is destroyed.
(define (compiler-embedded-stdlib-tlci-forget-decoded! [owner : i64]) : unit
  (if (and (> owner 0) (= compiler-embedded-stdlib-tlci-decoded-owner owner))
    (set! compiler-embedded-stdlib-tlci-decoded-owner 0)
    unit))

(define (compiler-embedded-stdlib-tlci-surface [owner : i64]) : CompilerEmbeddedStdlibTlciSurface
  (if (= (compiler-embedded-stdlib-tlci-length) 0)
    (CompilerEmbeddedStdlibTlciSurface.Unavailable
      "embedded stdlib tlci is unavailable in the seed/test build")
    (let
      [bytes : (__tl_dyn-array u8)
        (compiler-embedded-stdlib-tlci-surface-bytes owner)]
      (match (tlci.tlci-parse-image bytes)
        [(tlci.ResultTlciImage.Err message)
          (CompilerEmbeddedStdlibTlciSurface.Unavailable message)]
        [(tlci.ResultTlciImage.Ok image)
          (CompilerEmbeddedStdlibTlciSurface.Ok
            image.compiler-build-hash
            (payload.embedded-stdlib-tlci-source-hash-shared-view)
            image.rodata)]))))

(define (compiler-embedded-stdlib-tlci-host-table) : tlci.TlciHostCallbackTable
  (compiler-comptime-host-table))

(define (compiler-embedded-stdlib-tlci-session-open!) : bool
  (let
    [state : i64 (array-ref compiler-embedded-stdlib-tlci-session-state 0)]
    (cond
      [(= state 1) true]
      [(= state -1) false]
      [else
        (if (= (compiler-embedded-stdlib-tlci-length) 0)
          (begin
            (set! (array-ref compiler-embedded-stdlib-tlci-session-state 0) -1)
            (set!
              (array-ref compiler-embedded-stdlib-tlci-session-error 0)
              "embedded stdlib tlci is unavailable in the seed/test build")
            false)
          ;; The owner is the session's own arena, not the arena that happens
          ;; to be current on the first embedded-stdlib macro call: this image
          ;; is retained for the rest of the pass and dispatched from
          ;; declarations that outlive any macro-walk generation.
          (let
            [bytes : (__tl_dyn-array u8)
              (compiler-embedded-stdlib-tlci-image-bytes)]
            [host : tlci.TlciHostCallbackTable (compiler-comptime-host-table)]
            (match (loader.tlci-loader-load-from-bytes-with-host
              (compiler-embedded-stdlib-tlci-session-arena)
              bytes
              host)
              [(loader.ResultTlciLoadedImage.Err message)
                (begin
                  (set!
                    (array-ref compiler-embedded-stdlib-tlci-session-state 0)
                    -1)
                  (set!
                    (array-ref compiler-embedded-stdlib-tlci-session-error 0)
                    (compiler-embedded-stdlib-tlci-session-own-text message))
                  false)]
              [(loader.ResultTlciLoadedImage.Ok loaded)
                (begin
                  (set!
                    (array-ref compiler-embedded-stdlib-tlci-session-image 0)
                    loaded)
                  (set!
                    (array-ref compiler-embedded-stdlib-tlci-session-state 0)
                    1)
                  (cfg
                    tlci-native-route-stress
                    (set!
                      compiler-embedded-stdlib-tlci-stress-image-generations
                      (+
                        compiler-embedded-stdlib-tlci-stress-image-generations
                        1)))
                  true)])))])))

(define (compiler-embedded-stdlib-tlci-catalog-lookup [name : String]) : CompilerEmbeddedStdlibTlciLookup
  (if (compiler-embedded-stdlib-tlci-session-open!)
    (let
      [loaded : loader.TlciLoadedImage
        (compiler-embedded-stdlib-tlci-session-image-shared-view)]
      (match (loader.tlci-loader-resolve-macro-entry (& loaded) name)
        [(loader.TlciMacroEntryLookup.Resolved resolved)
          (CompilerEmbeddedStdlibTlciLookup.Resolved resolved)]
        [(loader.TlciMacroEntryLookup.Shell resolved)
          (CompilerEmbeddedStdlibTlciLookup.Shell resolved)]
        [(loader.TlciMacroEntryLookup.Missing)
          CompilerEmbeddedStdlibTlciLookup.Missing]
        [(loader.TlciMacroEntryLookup.Err message)
          (CompilerEmbeddedStdlibTlciLookup.Unavailable message)]))
    (CompilerEmbeddedStdlibTlciLookup.Unavailable
      (compiler-embedded-stdlib-tlci-session-error-shared-view))))

;; Dispatch a cataloged entry on the mapped pass session. The caller owns the
;; comptime host session (operands, fuel, cookie) around this call.
(define (compiler-embedded-stdlib-tlci-session-dispatch
  [resolved : loader.TlciResolvedMacroEntry]
  [session-cookie : i64]) : loader.ResultTlciMacroDispatch
  (if (= (array-ref compiler-embedded-stdlib-tlci-session-state 0) 1)
    (let
      [loaded : loader.TlciLoadedImage
        (compiler-embedded-stdlib-tlci-session-image-shared-view)]
      (loader.tlci-loader-dispatch-resolved-macro
        (& loaded)
        resolved
        session-cookie
        (__tl_make-array i64 0)
        0))
    (loader.ResultTlciMacroDispatch.Err
      "embedded stdlib tlci session is not loaded")))

(define (compiler-embedded-stdlib-tlci-session-mark-shell!
  [resolved : loader.TlciResolvedMacroEntry]) : loader.ResultTlciLoaderUnit
  (if (= (array-ref compiler-embedded-stdlib-tlci-session-state 0) 1)
    (let
      [loaded : loader.TlciLoadedImage
        (compiler-embedded-stdlib-tlci-session-image-shared-view)]
      (loader.tlci-loader-mark-macro-entry-shell! (& loaded) resolved))
    (loader.ResultTlciLoaderUnit.Err
      "embedded stdlib tlci session is not loaded")))

(define (compiler-embedded-stdlib-tlci-session-close!) : unit
  (let
    [state : i64 (array-ref compiler-embedded-stdlib-tlci-session-state 0)]
    (begin
      (set! (array-ref compiler-embedded-stdlib-tlci-session-state 0) 0)
      (set! (array-ref compiler-embedded-stdlib-tlci-session-error 0) "")
      (if (= state 1)
        (begin
          (match (loader.tlci-loader-release
            (compiler-embedded-stdlib-tlci-session-image-shared-view))
            [(loader.ResultTlciLoaderUnit.Ok) unit]
            [(loader.ResultTlciLoaderUnit.Err _) unit])
          (cfg
            tlci-native-route-stress
            (set!
              compiler-embedded-stdlib-tlci-stress-release-generations
              (+ compiler-embedded-stdlib-tlci-stress-release-generations 1))))
        unit))))

;; Map the embedded image through the production W^X loader, execute its image
;; registration entry, validate every registered macro record, and release the
;; mapping. Callback addresses are nonzero sentinels because validation never
;; invokes a transformer; real dispatch installs compiler-owned callbacks.
(define (compiler-embedded-stdlib-tlci-validate) : CompilerEmbeddedStdlibTlciValidation
  (if (= (compiler-embedded-stdlib-tlci-length) 0)
    (CompilerEmbeddedStdlibTlciValidation.Err
      "embedded stdlib tlci is unavailable in the seed/test build")
    ;; This image is released before this function returns, so the caller's
    ;; current arena already outlives it and is the honest owner.
    (let
      [bytes : (__tl_dyn-array u8) (compiler-embedded-stdlib-tlci-copy)]
      [host : tlci.TlciHostCallbackTable
        (compiler-embedded-stdlib-tlci-host-table)]
      (match (loader.tlci-loader-load-from-bytes-with-host
        (arena.tl_arena_current)
        bytes
        host)
        [(loader.ResultTlciLoadedImage.Err message)
          (CompilerEmbeddedStdlibTlciValidation.Err message)]
        [(loader.ResultTlciLoadedImage.Ok loaded)
          (let
            [count : i64 loaded.macro-entry-count]
            [has-native-sentinel : bool
              (match (loader.tlci-loader-find-macro-entry
                (& loaded)
                "stdlib.core_macros/__tl-box-place")
                [(loader.ResultTlciMacroEntry.Ok _) true]
                [(loader.ResultTlciMacroEntry.Err _) false])]
            (match (loader.tlci-loader-release loaded)
              [(loader.ResultTlciLoaderUnit.Err message)
                (CompilerEmbeddedStdlibTlciValidation.Err message)]
              [(loader.ResultTlciLoaderUnit.Ok)
                (if (and (> count 0) has-native-sentinel)
                  (CompilerEmbeddedStdlibTlciValidation.Ok count)
                  (CompilerEmbeddedStdlibTlciValidation.Err
                    "embedded stdlib tlci is missing its macro catalog"))]))]))))

;; --- compiler-owned native-comptime host session (refs #5212) -----------------
;;
;; One session spans one native transformer invocation. Values under
;; construction live on this compiler-owned stack: the image drives it through
;; direct named callbacks and never holds result handles, so the emitted native
;; code stays a pure callback sequence. Every callback validates the session
;; cookie and answers with the SPEC status contract; kind or arity
;; violations return bad-request without committing any state.
(define compiler-comptime-host-session-cookie : i64
  0)
(define compiler-comptime-host-session-fuel : i64
  0)
(define compiler-comptime-host-session-status : i64
  tlci.tlci-host-callback-status-ok)
(define compiler-comptime-host-pools : (__tl_dyn-array ast.AstNodePoolContext)
  (__tl_make-array ast.AstNodePoolContext 1))
(define compiler-comptime-host-operand-cap : i64
  16)
(define compiler-comptime-host-operands : (__tl_dyn-array
    ctfe_support.CompilerCtfeValue)
  (__tl_make-array
    ctfe_support.CompilerCtfeValue
    compiler-comptime-host-operand-cap))
(define compiler-comptime-host-operand-count : i64
  0)
(define compiler-comptime-host-reflections : (__tl_dyn-array
    ctfe_support.CtfeReflectInfoList)
  (__tl_make-array ctfe_support.CtfeReflectInfoList 1))
(define compiler-comptime-host-session-source-names : (__tl_dyn-array
    ci.InternSourceNameSessionHandle)
  (__tl_make-array ci.InternSourceNameSessionHandle 1))
(define compiler-comptime-host-session-macro-state : (__tl_dyn-array
    ctfe_support.CompilerCtfeMacroState)
  (__tl_make-array ctfe_support.CompilerCtfeMacroState 1))
(define compiler-comptime-host-stack-base : (__tl_dyn-array
    ctfe_support.CompilerCtfeValue)
  (__tl_make-array ctfe_support.CompilerCtfeValue 64))
(define compiler-comptime-host-stack : (__tl_dyn-array
    ctfe_support.CompilerCtfeValue)
  (__tl_make-array ctfe_support.CompilerCtfeValue 64))
(define compiler-comptime-host-stack-len : i64
  0)
(define compiler-comptime-host-result : (__tl_dyn-array
    ctfe_support.CompilerCtfeValue)
  (__tl_make-array ctfe_support.CompilerCtfeValue 1))
(define compiler-comptime-host-result-ready : bool
  false)
(define compiler-comptime-host-diagnostic : (__tl_dyn-array String)
  (__tl_make-array ""))

;; The host pool is a process-global owner cell. Pass its state-cell addresses
;; across constructor boundaries so by-value AstNodePoolContext parameters do
;; not detach the count/dedup state from the session that receives the result.
(define (compiler-comptime-host-pool-cell-address [field-index : i64]) : u64
  (let
    [descriptor-address : u64
      (unsafe
        (ptr-read
          (ptr-offset
            (ptr-cast
              (__tl_array-data compiler-comptime-host-pools)
              : (Ptr u64))
            field-index)))]
    (unsafe
      (ptr-read (int->ptr descriptor-address : (Ptr u64))))))

;; Computed-body local slots for let-bound transformer bodies (refs #5603).
;; Slots are addressed by immediate operand and validated per session.
(define compiler-comptime-host-locals-cap : i64
  64)
(define compiler-comptime-host-locals : (__tl_dyn-array
    ctfe_support.CompilerCtfeValue)
  (__tl_make-array
    ctfe_support.CompilerCtfeValue
    compiler-comptime-host-locals-cap))
(define compiler-comptime-host-locals-live : (__tl_dyn-array bool)
  (__tl_make-array bool compiler-comptime-host-locals-cap))

;; Pop `count` patterns into a fresh list (last-pushed becomes the final
;; element), or report failure when any value is not a pattern.
(defenum CompilerCtfeMaybePatternList
  (Some ast.AstPatternList)
  (None))

(define (compiler-comptime-host-pop-pattern-list [count : i64]) : CompilerCtfeMaybePatternList
  (let
    [out : ast.AstPatternList (ast.ast-pattern-list-new)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [value : ctfe_support.CompilerCtfeValue
            (compiler-comptime-host-stack-value (- count index))]
          (match value
            [(ctfe_support.CompilerCtfeValue.Pattern pattern)
              (begin
                (ast.ast-pattern-list-push (&mut out) pattern)
                (set! index (+ index 1)))]
            [_ (set! ok false)])))
      (if ok
        (begin
          (compiler-comptime-host-drop! count)
          (CompilerCtfeMaybePatternList.Some out))
        (CompilerCtfeMaybePatternList.None)))))

(define (compiler-comptime-host-locals-clear!) : unit
  (compiler-comptime-host-locals-clear-from! 0))

(define (compiler-comptime-host-locals-clear-from! [index : i64]) : unit
  (if (>= index compiler-comptime-host-locals-cap)
    unit
    (begin
      (set! (array-ref compiler-comptime-host-locals-live index) false)
      (compiler-comptime-host-locals-clear-from! (+ index 1)))))

;; Open the compiler-owned state addressed by the opaque session cookie passed
;; to every named callback. The callback's hidden environment carries the host
;; context; its explicit arguments begin with this cookie.
(define (compiler-comptime-host-session-open-with-macro-state!
  [pools : ast.AstNodePoolContext]
  [operands : (& operands (__tl_dyn-array ctfe_support.CompilerCtfeValue))]
  [operand-count : i64]
  [fuel : i64]
  [cookie : i64]
  [reflections : ctfe_support.CtfeReflectInfoList]
  [source-names : ci.InternSourceNameSessionHandle]
  [macro-state : ctfe_support.CompilerCtfeMacroState]) : unit
  (begin
    (cfg
      tlci-native-route-stress
      (set!
        compiler-embedded-stdlib-tlci-stress-session-generations
        (+ compiler-embedded-stdlib-tlci-stress-session-generations 1)))
    (set! (array-ref compiler-comptime-host-pools 0) pools)
    (set! (array-ref compiler-comptime-host-reflections 0) reflections)
    (set!
      (array-ref compiler-comptime-host-session-source-names 0)
      source-names)
    (set! (array-ref compiler-comptime-host-session-macro-state 0) macro-state)
    (let
      [index : i64 0]
      (while (and
        (< index operand-count)
        (< index compiler-comptime-host-operand-cap))
        (begin
          (set!
            (array-ref compiler-comptime-host-operands index)
            (array-ref operands index))
          (set! index (+ index 1)))))
    (set! compiler-comptime-host-operand-count operand-count)
    (set! compiler-comptime-host-session-fuel fuel)
    (set!
      compiler-comptime-host-session-status
      tlci.tlci-host-callback-status-ok)
    ;; A grown stack belongs to the current compilation arena. Never retain
    ;; that allocation in this process-global slot across batch entries.
    (set!
      compiler-comptime-host-stack
      (compiler-comptime-host-global-shared-view
        compiler-comptime-host-stack-base))
    (set! compiler-comptime-host-stack-len 0)
    (set! compiler-comptime-host-result-ready false)
    (compiler-comptime-host-locals-clear!)
    (set! (array-ref compiler-comptime-host-diagnostic 0) "")
    (set! compiler-comptime-host-session-cookie cookie)))

;; Standalone callback tests intentionally use the serial CTFE adapter. The
;; production macro route calls the explicit entry above with its CtfeEnv's
;; job-owned state; the callback ABI then carries that capability for exactly
;; one validated native session.
(define (compiler-comptime-host-session-open!
  [pools : ast.AstNodePoolContext]
  [operands : (__tl_dyn-array ctfe_support.CompilerCtfeValue)]
  [operand-count : i64]
  [fuel : i64]
  [cookie : i64]
  [reflections : ctfe_support.CtfeReflectInfoList]) : unit
  (let
    [source-names : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-capture-active-handle)]
    [macro-state : ctfe_support.CompilerCtfeMacroState
      (ctfe_support.compiler-ctfe-serial-macro-state)]
    (begin
      (ctfe_support.compiler-ctfe-macro-state-bind-source-names!
        macro-state
        source-names)
      (compiler-comptime-host-session-open-with-macro-state!
        pools
        operands
        operand-count
        fuel
        cookie
        reflections
        source-names
        macro-state))))

(defmacro (compiler-comptime-host-session-macro-state-value) : Expr
  `(compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-session-macro-state
    0))

(define (compiler-comptime-host-session-source-names-value) : ci.InternSourceNameSessionHandle
  (array-ref compiler-comptime-host-session-source-names 0))

(define (compiler-comptime-host-template-source-id [source-name-id : i64]) : i64
  (cis.intern-template-source-identity-raw
    (cis.intern-structural-session-template-source-identity
      (cis.intern-structural-session-handle-from-source-names
        (compiler-comptime-host-session-source-names-value))
      source-name-id)))

;; Rebuild the lightweight CTFE adapter used by native callbacks with the
;; source-name capability of the transformer being evaluated. In particular,
;; a generated identity may have the same spelling as a parsed module name but
;; must still resolve in its original session.
(define (compiler-comptime-host-ctfe-env) : ctfe_support.CtfeEnv
  (ctfe_support.ctfe-env-empty-with-pools-and-source-names
    (compiler-comptime-host-session-pools)
    (compiler-comptime-host-array-element-shared-view
      compiler-comptime-host-session-source-names
      0)))

(define (compiler-comptime-host-session-close!) : unit
  (begin
    (set! compiler-comptime-host-session-cookie 0)
    (set!
      (array-ref compiler-comptime-host-session-macro-state 0)
      (ctfe_support.CompilerCtfeMacroState 0))
    (set!
      (array-ref compiler-comptime-host-session-source-names 0)
      (ci.InternSourceNameSessionHandle 0))
    (set!
      compiler-comptime-host-session-status
      tlci.tlci-host-callback-status-ok)
    (set! compiler-comptime-host-stack-len 0)
    (set! compiler-comptime-host-operand-count 0)
    (set! compiler-comptime-host-result-ready false)))

(define (compiler-comptime-host-result-value) : ctfe_support.CompilerCtfeValue
  (compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-result
    0))

(define (compiler-comptime-host-result-ready?) : bool
  compiler-comptime-host-result-ready)

(define (compiler-comptime-host-result-consume-for-test!) : unit
  (set! compiler-comptime-host-result-ready false))

(define (compiler-comptime-host-diagnostic-text) : String
  (compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-diagnostic
    0))

(define (compiler-comptime-host-stack-grow!) : unit
  (let
    [old-cap : i64 (array-length compiler-comptime-host-stack)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array ctfe_support.CompilerCtfeValue)
      (__tl_make-array ctfe_support.CompilerCtfeValue new-cap)]
    [index : i64 0]
    (begin
      (while (< index compiler-comptime-host-stack-len)
        (begin
          (set!
            (array-ref bigger index)
            (array-ref compiler-comptime-host-stack index))
          (set! index (+ index 1))))
      (set! compiler-comptime-host-stack bigger))))

(define (compiler-comptime-host-push! [value : ctfe_support.CompilerCtfeValue]) : i64
  (begin
    (when
      (>=
        compiler-comptime-host-stack-len
        (array-length compiler-comptime-host-stack))
      (compiler-comptime-host-stack-grow!))
    (set!
      (array-ref compiler-comptime-host-stack compiler-comptime-host-stack-len)
      value)
    (set!
      compiler-comptime-host-stack-len
      (+ compiler-comptime-host-stack-len 1))
    tlci.tlci-host-callback-status-ok))

(define (compiler-comptime-host-push-expr! [node : i64]) : i64
  (compiler-comptime-host-push!
    (ctfe_support.CompilerCtfeValue.Expr node (ast.AstType.Expr))))

;; A callback consumes its operands from the top of the value stack. Values are
;; read in place (`depth` 1 is the top) after the caller has checked the stack
;; length, and replaced by the result once every operand has been read.
(define (compiler-comptime-host-stack-value [depth : i64]) : ctfe_support.CompilerCtfeValue
  (compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-stack
    (- compiler-comptime-host-stack-len depth)))

(define (compiler-comptime-host-stack-node [depth : i64]) : i64
  (let
    [value : ctfe_support.CompilerCtfeValue
      (compiler-comptime-host-stack-value depth)]
    (compiler-comptime-host-value-node value)))

(define (compiler-comptime-host-drop! [count : i64]) : unit
  (set!
    compiler-comptime-host-stack-len
    (- compiler-comptime-host-stack-len count)))

(define (compiler-comptime-host-replace!
  [count : i64]
  [value : ctfe_support.CompilerCtfeValue]) : i64
  (begin
    (compiler-comptime-host-drop! count)
    (compiler-comptime-host-push! value)))

(define (compiler-comptime-host-replace-expr! [count : i64] [node : i64]) : i64
  (compiler-comptime-host-replace!
    count
    (ctfe_support.CompilerCtfeValue.Expr node (ast.AstType.Expr))))

(define (compiler-comptime-host-session-pools) : ast.AstNodePoolContext
  (compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-pools
    0))

(define (compiler-comptime-host-session-reflections) : ctfe_support.CtfeReflectInfoList
  (compiler-comptime-host-array-element-shared-view
    compiler-comptime-host-reflections
    0))

;; Record an authored diagnostic for the dispatch and answer its status.
(define (compiler-comptime-host-diagnostic! [message : String]) : i64
  (begin
    (set! (array-ref compiler-comptime-host-diagnostic 0) message)
    tlci.tlci-host-callback-status-diagnostic))

;; Commit a shared builder's result in place of `count` operands, or report its
;; authored diagnostic.
(define (compiler-comptime-host-replace-built!
  [count : i64]
  [built : ctfe_support.CtfeBuilt]) : i64
  (match built
    [(ctfe_support.CtfeBuilt.Ok value)
      (compiler-comptime-host-replace! count value)]
    [(ctfe_support.CtfeBuilt.Err message)
      (compiler-comptime-host-diagnostic! message)]))

;; Expression list of a variadic operand or stack value. Captured lists carry
;; the caller's pools; the session's pools are the caller's, so they project
;; the same way the interpreted quote accepts a storage-sharing capture.
;; Refs #5617.
(defenum CompilerCtfeMaybeExprList
  (Some ast.AstExprList)
  (None))

(defenum CompilerCtfeMaybeExprClauseList
  (Some ast.AstExprClauseList)
  (None))

(define (compiler-comptime-host-value-expr-list
  [value : (& value ctfe_support.CompilerCtfeValue)]) : CompilerCtfeMaybeExprList
  (match value
    [(ctfe_support.CompilerCtfeValue.ExprList items)
      (CompilerCtfeMaybeExprList.Some
        (owned_view.compiler-owned-reference-shared-view items))]
    [(ctfe_support.CompilerCtfeValue.CapturedExprList items _)
      (CompilerCtfeMaybeExprList.Some
        (owned_view.compiler-owned-reference-shared-view items))]
    [_ (CompilerCtfeMaybeExprList.None)]))

(define (compiler-comptime-host-value-expr-clause-list
  [value : (& value ctfe_support.CompilerCtfeValue)]) : CompilerCtfeMaybeExprClauseList
  (match value
    [(ctfe_support.CompilerCtfeValue.ExprClauseList items)
      (CompilerCtfeMaybeExprClauseList.Some
        (owned_view.compiler-owned-reference-shared-view items))]
    [(ctfe_support.CompilerCtfeValue.CapturedExprClauseList items _)
      (CompilerCtfeMaybeExprClauseList.Some
        (owned_view.compiler-owned-reference-shared-view items))]
    [_ (CompilerCtfeMaybeExprClauseList.None)]))

;; An unspanned expression held in a session local. Captured expressions retain
;; their caller pool context, just like operand probes and local ExprList
;; projections. Refs #5656.
(defenum CompilerCtfeMaybeExpr
  (Some ast.AstExpr)
  (None))

(define (compiler-comptime-host-local-expr [slot : i64]) : CompilerCtfeMaybeExpr
  (if (or
    (< slot 0)
    (>= slot compiler-comptime-host-locals-cap)
    (not
      (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-locals-live
        slot)))
    (CompilerCtfeMaybeExpr.None)
    (let
      [value : ctfe_support.CompilerCtfeValue
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals
          slot)]
      [node : i64 (compiler-comptime-host-value-node value)]
      [pools : ast.AstNodePoolContext
        (compiler-comptime-host-value-pools value)]
      (if (< node 0)
        (CompilerCtfeMaybeExpr.None)
        (CompilerCtfeMaybeExpr.Some
          (compiler-comptime-host-unspanned-expr
            pools
            (ast.ast-node-pool-context-expr-get pools node)))))))

;; Comptime String text held in a session local, for the scanner ops that read
;; a bound template or type key by slot. `live` is checked by the caller, which
;; distinguishes an out-of-range slot from a slot holding a non-String value.
;; Refs #5701.
(define (compiler-comptime-host-local-string [slot : i64]) : ctfe_support.CtfeMaybeNamed
  (if (or
    (< slot 0)
    (>= slot compiler-comptime-host-locals-cap)
    (not
      (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-locals-live
        slot)))
    (ctfe_support.CtfeMaybeNamed.None)
    (ctfe_support.ctfe-value-named
      (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-locals
        slot))))

(define (compiler-comptime-host-value-module-index
  [value : ctfe_support.CompilerCtfeValue]) : ctfe_support.CtfeMaybeNamed
  (ctfe_support.ctfe-value-module-index
    (compiler-comptime-host-session-source-names-value)
    value))

(define (compiler-comptime-host-value-name-id
  [value : ctfe_support.CompilerCtfeValue]) : ctfe_support.CtfeMaybeNameId
  (ctfe_support.ctfe-value-syntax-name-id
    (compiler-comptime-host-session-source-names-value)
    value))

;; The pools that own an operand's expression nodes: a captured operand keeps
;; its caller pools, every other value reads the session pools. Refs #5602.
(define (compiler-comptime-host-value-pools
  [value : (& value ctfe_support.CompilerCtfeValue)]) : ast.AstNodePoolContext
  (match value
    [(ctfe_support.CompilerCtfeValue.CapturedExpr _ _ pools)
      (owned_view.compiler-owned-reference-shared-view pools)]
    [(ctfe_support.CompilerCtfeValue.CapturedExprList _ pools)
      (owned_view.compiler-owned-reference-shared-view pools)]
    [(ctfe_support.CompilerCtfeValue.CapturedExprClause _ pools)
      (owned_view.compiler-owned-reference-shared-view pools)]
    [(ctfe_support.CompilerCtfeValue.CapturedExprClauseList _ pools)
      (owned_view.compiler-owned-reference-shared-view pools)]
    [_ (compiler-comptime-host-session-pools)]))

(define (compiler-comptime-host-expr-value-for-owner
  [owner : ctfe_support.CompilerCtfeValue]
  [node : i64]) : ctfe_support.CompilerCtfeValue
  (match (ctfe_support.ctfe-value-syntax-pools owner)
    [(ctfe_support.CtfeMaybeSyntaxPools.Some pools)
      (ctfe_support.CompilerCtfeValue.CapturedExpr
        node
        (ast.AstType.Expr)
        pools)]
    [(ctfe_support.CtfeMaybeSyntaxPools.None)
      (ctfe_support.CompilerCtfeValue.Expr node (ast.AstType.Expr))]))

;; The diagnostic-wrapper-free expression an operand denotes, mirroring
;; `ctfe-match-expr-variant`'s `ctfe-expr-unspan` before it inspects a variant.
(define (compiler-comptime-host-unspanned-expr
  [pools : (& pools ast.AstNodePoolContext)]
  [expr : ast.AstExpr]) : ast.AstExpr
  (match (owned_view.compiler-owned-shared-view expr)
    [(ast.AstExpr.Spanned inner _)
      (compiler-comptime-host-unspanned-expr
        pools
        (ast.ast-node-pool-context-expr-get pools inner))]
    [(ast.AstExpr.MacroExpansion inner _ _)
      (compiler-comptime-host-unspanned-expr
        pools
        (ast.ast-node-pool-context-expr-get pools inner))]
    [_ expr]))

;; The unspanned expression of operand `index`, or a unit literal when the
;; operand is out of range or carries no expression node. Callers probe the
;; range separately, so the fallback is only a total-function placeholder.
(define (compiler-comptime-host-operand-expr [index : i64]) : ast.AstExpr
  (let
    [value : ctfe_support.CompilerCtfeValue
      (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        index)]
    [node : i64 (compiler-comptime-host-value-node value)]
    [pools : ast.AstNodePoolContext (compiler-comptime-host-value-pools value)]
    (if (< node 0)
      (ast.AstExpr.Literal (ast.AstLiteral.Unit))
      (compiler-comptime-host-unspanned-expr
        pools
        (ast.ast-node-pool-context-expr-get pools node)))))

;; Expression node id of a stack value, or -1 when the value does not carry
;; one. Captured operands keep their caller-pool node id; the pool-context
;; bridging refinement is tracked with the real-body slice. A type operand
;; converts to its type-syntax expression, matching the interpreted
;; quasiquote's unquote substitution for `,T`.
(define (compiler-comptime-host-value-node
  [value : (& value ctfe_support.CompilerCtfeValue)]) : i64
  (match value
    [(ctfe_support.CompilerCtfeValue.Expr node _)
      (owned_view.compiler-owned-reference-shared-view node)]
    [(ctfe_support.CompilerCtfeValue.CapturedExpr node _ _)
      (owned_view.compiler-owned-reference-shared-view node)]
    [(ctfe_support.CompilerCtfeValue.Type ty)
      (let
        [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
        (ctfe_support.ctfe-type-to-expr
          (owned_view.compiler-owned-reference-shared-view ty)
          env))]
    [_ -1]))

;; Pop two operand expressions (second then target) and push a two-operand
;; intrinsic node: kind 0 is array-ref, kind 1 is array-push, and kind 2 is
;; replace. All take the node ids the interpreted builders receive.
(define (compiler-comptime-host-build-binary-intrinsic! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 2)
    tlci.tlci-host-callback-status-bad-request
    (let
      [operand-node : i64 (compiler-comptime-host-stack-node 1)]
      [target-node : i64 (compiler-comptime-host-stack-node 2)]
      (if (or (< operand-node 0) (< target-node 0))
        tlci.tlci-host-callback-status-bad-request
        (let
          [pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          [node : i64
            (if (= kind 0)
              (ast.ast-expr-array-ref-with-pools pools target-node operand-node)
              (if (= kind 1)
                (ast.ast-expr-array-push-with-pools
                  pools
                  target-node
                  operand-node)
                (ast.ast-expr-replace-with-pools pools target-node operand-node)))]
          (compiler-comptime-host-replace-expr! 2 node))))))

;; Decode the scalar AstType ordinal a native image passes for type-scalar.
;; The producer and consumer are always the same source-bound binary, so the
;; ordinal contract stays in sync with the producer's encoder.
(define (compiler-comptime-host-scalar-type-for-ordinal [ordinal : i64]) : ast.AstType
  (cond
    [(= ordinal 0) (ast.AstType.I64)]
    [(= ordinal 1) (ast.AstType.I32)]
    [(= ordinal 2) (ast.AstType.I16)]
    [(= ordinal 3) (ast.AstType.I8)]
    [(= ordinal 4) (ast.AstType.U64)]
    [(= ordinal 5) (ast.AstType.U32)]
    [(= ordinal 6) (ast.AstType.U16)]
    [(= ordinal 7) (ast.AstType.U8)]
    [(= ordinal 8) (ast.AstType.F64)]
    [(= ordinal 9) (ast.AstType.F32)]
    [(= ordinal 10) (ast.AstType.Bool)]
    [(= ordinal 11) (ast.AstType.Char)]
    [(= ordinal 12) (ast.AstType.String)]
    [(= ordinal 13) (ast.AstType.Str)]
    [(= ordinal 14) (ast.AstType.Bytes)]
    [(= ordinal 15) (ast.AstType.Expr)]
    [(= ordinal 16) (ast.AstType.ExprList)]
    [(= ordinal 17) (ast.AstType.Unit)]
    [(= ordinal 18) (ast.AstType.Never)]
    [else (ast.AstType.Unit)]))

;; Decode the AstBinOp ordinal a native image passes for expr-binary-op. The
;; producer and consumer are always the same source-bound binary, so the
;; ordinal contract stays in sync with the producer's encoder. Callers range
;; check the ordinal before decoding, so the fallback is unreachable.
(define (compiler-comptime-host-binop-for-ordinal [ordinal : i64]) : ast.AstBinOp
  (cond
    [(= ordinal 0) (ast.AstBinOp.Add)]
    [(= ordinal 1) (ast.AstBinOp.Sub)]
    [(= ordinal 2) (ast.AstBinOp.Mul)]
    [(= ordinal 3) (ast.AstBinOp.Div)]
    [(= ordinal 4) (ast.AstBinOp.Mod)]
    [(= ordinal 5) (ast.AstBinOp.Eq)]
    [(= ordinal 6) (ast.AstBinOp.Ne)]
    [(= ordinal 7) (ast.AstBinOp.Lt)]
    [(= ordinal 8) (ast.AstBinOp.Le)]
    [(= ordinal 9) (ast.AstBinOp.Gt)]
    [(= ordinal 10) (ast.AstBinOp.Ge)]
    [(= ordinal 11) (ast.AstBinOp.And)]
    [(= ordinal 12) (ast.AstBinOp.Or)]
    [(= ordinal 13) (ast.AstBinOp.BitAnd)]
    [(= ordinal 14) (ast.AstBinOp.BitOr)]
    [(= ordinal 15) (ast.AstBinOp.BitXor)]
    [(= ordinal 16) (ast.AstBinOp.Shl)]
    [(= ordinal 17) (ast.AstBinOp.Shr)]
    [else (ast.AstBinOp.Add)]))

;; Decode the AstUnOp ordinal a native image passes for expr-unary-op.
(define (compiler-comptime-host-unop-for-ordinal [ordinal : i64]) : ast.AstUnOp
  (cond
    [(= ordinal 0) (ast.AstUnOp.Neg)]
    [(= ordinal 1) (ast.AstUnOp.Not)]
    [(= ordinal 2) (ast.AstUnOp.BitNot)]
    [else (ast.AstUnOp.Neg)]))

;; Pop one expression from the value stack and push the single-operand node
;; the parser produces for the shape named by `kind` (0 return, 1 box, 2
;; box-get, 3 ptr-read, 4 ptr-to-int, 5 string-data, 6 array-data, 7 box-take,
;; and 8 ptr-addr-of), matching the interpreted quote's reconstruction. Returns
;; the callback status. Refs #5605, #6215.
(define (compiler-comptime-host-unary-node-step! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (let
      [inner-node : i64 (compiler-comptime-host-stack-node 1)]
      (if (< inner-node 0)
        tlci.tlci-host-callback-status-bad-request
        (let
          [pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          (compiler-comptime-host-replace-expr!
            1
            (cond
              [(= kind 0) (ast.ast-expr-return-with-pools pools inner-node)]
              [(= kind 1) (ast.ast-expr-box-with-pools pools inner-node)]
              [(= kind 2) (ast.ast-expr-box-get-with-pools pools inner-node)]
              [(= kind 3) (ast.ast-expr-ptr-read-with-pools pools inner-node)]
              [(= kind 4) (ast.ast-expr-ptr-to-int-with-pools pools inner-node)]
              [(= kind 5)
                (ast.ast-expr-string-data-with-pools pools inner-node)]
              [(= kind 6) (ast.ast-expr-array-data-with-pools pools inner-node)]
              [(= kind 7) (ast.ast-expr-box-take-with-pools pools inner-node)]
              [else (ast.ast-expr-ptr-addr-of-id-with-pools pools inner-node)])))))))

;; Pop a type and one expression, normalize direct types and captured type
;; syntax through the same conversion as interpreted quasiquote, and push the
;; requested typed pointer node (0 ptr-cast, 1 int-to-ptr). Refs #6215.
(define (compiler-comptime-host-typed-pointer-node-step! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 2)
    tlci.tlci-host-callback-status-bad-request
    (let
      [type-value : ctfe_support.CompilerCtfeValue
        (compiler-comptime-host-stack-value 1)]
      [value-node : i64 (compiler-comptime-host-stack-node 2)]
      (if (< value-node 0)
        tlci.tlci-host-callback-status-bad-request
        (match (ctfe_support.ctfe-pattern-binding-type-value
          type-value
          (ast.AstExpr.Literal (ast.AstLiteral.Unit))
          (compiler-comptime-host-ctfe-env)
          compiler-comptime-host-session-fuel)
          [(ctfe_support.ResultCtfeQuoteType.Ok ty next-fuel)
            (let
              [pools : ast.AstNodePoolContext
                (compiler-comptime-host-session-pools)]
              (begin
                (set! compiler-comptime-host-session-fuel next-fuel)
                (compiler-comptime-host-replace-expr!
                  2
                  (if (= kind 0)
                    (ast.ast-expr-ptr-cast-with-pools pools value-node ty)
                    (ast.ast-expr-int-to-ptr-with-pools pools value-node ty)))))]
          [(ctfe_support.ResultCtfeQuoteType.Err diag)
            (begin
              (set!
                (array-ref compiler-comptime-host-diagnostic 0)
                (__tl-project-field (__tl-box-place diag) message))
              tlci.tlci-host-callback-status-diagnostic)])))))

;; The compiler-owned callback invoke installed into the tlci host callback
;; table. TypeLisp's native convention passes scalar arguments in the SysV
;; integer registers, so this function is directly callable from the mapped
;; image on Linux; the Windows adapter is tracked with the dispatch slice.
;; Pop the second then the first operand expression and push the two-operand
;; raw-pointer/data node the parser produces: kind 0 is `(ptr-write! p v)`,
;; kind 1 is `(ptr-offset p n)`, and kind 2 is `(string-from-bytes d n)`.
;; Captured Expr type syntax is normalized before wrapping, matching
;; interpreted quasiquote's type-unquote path. Refs #5605, #6215.
(define (compiler-comptime-host-ptr-binary-step! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 2)
    tlci.tlci-host-callback-status-bad-request
    (let
      [second-node : i64 (compiler-comptime-host-stack-node 1)]
      [first-node : i64 (compiler-comptime-host-stack-node 2)]
      (if (or (< second-node 0) (< first-node 0))
        tlci.tlci-host-callback-status-bad-request
        (let
          [pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          (compiler-comptime-host-replace-expr!
            2
            (cond
              [(= kind 0)
                (ast.ast-expr-ptr-write-with-pools pools first-node second-node)]
              [(= kind 1)
                (ast.ast-expr-ptr-offset-with-pools
                  pools
                  first-node
                  second-node)]
              [else
                (ast.ast-expr-string-from-bytes-with-pools
                  pools
                  first-node
                  second-node)])))))))

;; Pop a type value and push the composite that wraps it: kind 0 is
;; `(Ptr T)`/`(MutPtr T)` selected by `flag`, 1 is `(Box T)`, 2 is the private
;; `(__tl_dyn-array T)`, 3 is `(Array T N)` with `flag` as the count, and 4 is
;; `(& r T)`/`(&mut r T)` with `flag` selecting mutability and the lifetime name
;; arriving as caller bytes, and 5 is `(Slice T)`. The lifetime name is
;; interned through the same source-slice path template variable names use.
;; Refs #5605.
(define (compiler-comptime-host-type-wrap-step!
  [kind : i64]
  [flag : i64]
  [name-ptr : i64]
  [name-len : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (if (or
      (< kind 0)
      (> kind 5)
      (and (= kind 4) (or (<= name-ptr 0) (< name-len 0))))
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        (match (ctfe_support.ctfe-pattern-binding-type-value
          type-value
          (ast.AstExpr.Literal (ast.AstLiteral.Unit))
          (compiler-comptime-host-ctfe-env)
          compiler-comptime-host-session-fuel)
          [(ctfe_support.ResultCtfeQuoteType.Ok inner next-fuel)
            (let
              [pools : ast.AstNodePoolContext
                (compiler-comptime-host-session-pools)]
              [region : i64
                (if (= kind 4)
                  (let
                    [name : String
                      (unsafe
                        (string-from-bytes
                          (int->ptr name-ptr : (Ptr u8))
                          name-len))]
                    (ci.intern-source-slice name 0 (string.string-length name)))
                  0)]
              (begin
                (set! compiler-comptime-host-session-fuel next-fuel)
                (compiler-comptime-host-replace!
                  1
                  (ctfe_support.CompilerCtfeValue.Type
                    (cond
                      [(= kind 0)
                        (if (= flag 0)
                          (ast.ast-ty-ptr-with-pools pools inner)
                          (ast.ast-ty-mut-ptr-with-pools pools inner))]
                      [(= kind 1) (ast.ast-ty-box-with-pools pools inner)]
                      [(= kind 2) (ast.ast-ty-dyn-array-with-pools pools inner)]
                      [(= kind 3)
                        (ast.ast-ty-array-with-pools pools inner flag)]
                      [(= kind 4)
                        (if (= flag 0)
                          (ast.ast-ty-ref-with-pools pools region inner)
                          (ast.ast-ty-mut-ref-with-pools pools region inner))]
                      [(= kind 5) (ast.ast-ty-slice-with-pools pools inner)]
                      [else inner])))))]
          [(ctfe_support.ResultCtfeQuoteType.Err diag)
            (begin
              (set!
                (array-ref compiler-comptime-host-diagnostic 0)
                (__tl-project-field (__tl-box-place diag) message))
              tlci.tlci-host-callback-status-diagnostic)])))))

;; Replace the type value at the top of the session stack with one reflected
;; field/variant name. `kind` is 0 for a struct field and 1 for an enum
;; variant. The returned `Name` preserves the declaration's intern identity,
;; matching the interpreted reflection path rather than materializing a fresh
;; computed String. Refs #5626.
(define (compiler-comptime-host-reflection-name-step!
  [kind : i64]
  [index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (match (compiler-comptime-host-stack-value 1)
      [(ctfe_support.CompilerCtfeValue.Type ty)
        (match (let
          [host-pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          [host-reflections : ctfe_support.CtfeReflectInfoList
            (compiler-comptime-host-session-reflections)]
          (ctfe_support.ctfe-reflect-info-for-type-with-pools
            host-pools
            host-reflections
            ty))
          [(ctfe_support.CtfeMaybeReflectInfo.Some info)
            (match info
              [(ctfe_support.CtfeReflectInfo.Struct _ _ _ _ _ fields _)
                (if (= kind 0)
                  (match (ctfe_support.ctfe-reflect-field-name-at fields index)
                    [(ctfe_support.ResultCtfeNameLookup.Ok name)
                      (compiler-comptime-host-replace!
                        1
                        (ctfe_support.ctfe-name-value-for-source-names
                          (compiler-comptime-host-session-source-names-value)
                          name))]
                    [(ctfe_support.ResultCtfeNameLookup.Err _)
                      tlci.tlci-host-callback-status-bad-request])
                  tlci.tlci-host-callback-status-bad-request)]
              [(ctfe_support.CtfeReflectInfo.Enum _ _ _ _ _ variants _)
                (if (= kind 1)
                  (match (ctfe_support.ctfe-reflect-variant-name-at
                    variants
                    index)
                    [(ctfe_support.ResultCtfeNameLookup.Ok name)
                      (compiler-comptime-host-replace!
                        1
                        (ctfe_support.ctfe-name-value-for-source-names
                          (compiler-comptime-host-session-source-names-value)
                          name))]
                    [(ctfe_support.ResultCtfeNameLookup.Err _)
                      tlci.tlci-host-callback-status-bad-request])
                  tlci.tlci-host-callback-status-bad-request)])]
          [(ctfe_support.CtfeMaybeReflectInfo.None)
            tlci.tlci-host-callback-status-bad-request])]
      [_ tlci.tlci-host-callback-status-bad-request])))

;; Reflection counts return their value directly through the callback ABI, so
;; success consumes the type stack value and failure uses the negative data-op
;; sentinel. `kind` is struct fields, enum variants, enum variant payloads, or
;; tuple elements (0 through 3). Refs #5626.
(define (compiler-comptime-host-reflection-count-step!
  [kind : i64]
  [index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    -3
    (match (compiler-comptime-host-stack-value 1)
      [(ctfe_support.CompilerCtfeValue.Type ty)
        (let
          [pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          [infos : ctfe_support.CtfeReflectInfoList
            (compiler-comptime-host-session-reflections)]
          [count : i64
            (cond
              [(= kind 0)
                (match (ctfe_support.ctfe-reflect-info-for-type-with-pools
                  pools
                  infos
                  ty)
                  [(ctfe_support.CtfeMaybeReflectInfo.Some
                      (ctfe_support.CtfeReflectInfo.Struct _ _ _ _ _ fields _))
                    (ctfe_support.ctfe-reflect-field-list-count fields)]
                  [_ -3])]
              [(= kind 1)
                (match (ctfe_support.ctfe-reflect-info-for-type-with-pools
                  pools
                  infos
                  ty)
                  [(ctfe_support.CtfeMaybeReflectInfo.Some
                      (ctfe_support.CtfeReflectInfo.Enum _ _ _ _ _ variants _))
                    (ctfe_support.ctfe-reflect-variant-list-count variants)]
                  [_ -3])]
              [(= kind 2)
                (match (ctfe_support.ctfe-reflect-info-for-type-with-pools
                  pools
                  infos
                  ty)
                  [(ctfe_support.CtfeMaybeReflectInfo.Some
                      (ctfe_support.CtfeReflectInfo.Enum _ _ _ _ _ variants _))
                    (match (ctfe_support.ctfe-reflect-variant-payloads-at
                      variants
                      index)
                      [(ctfe_support.ResultCtfeTypeListLookup.Ok payloads)
                        (ctfe_support.ctfe-type-list-count payloads)]
                      [(ctfe_support.ResultCtfeTypeListLookup.Err _) -3])]
                  [_ -3])]
              [else
                (match (ctfe_support.ctfe-reflect-resolve-type-with-pools
                  pools
                  infos
                  ty)
                  [(ast.AstType.Tuple elems)
                    (ctfe_support.ctfe-type-list-count (deref elems))]
                  [_ -3])])]
          (if (< count 0)
            -3
            (begin
              (compiler-comptime-host-drop! 1)
              count)))]
      [_ -3])))

;; Replace the type stack value with one indexed reflected type. `kind` is a
;; struct field, enum payload, or tuple element (0 through 2). Refs #5626.
(define (compiler-comptime-host-reflection-type-step!
  [kind : i64]
  [first-index : i64]
  [second-index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (match (compiler-comptime-host-stack-value 1)
      [(ctfe_support.CompilerCtfeValue.Type ty)
        (let
          [pools : ast.AstNodePoolContext
            (compiler-comptime-host-session-pools)]
          [infos : ctfe_support.CtfeReflectInfoList
            (compiler-comptime-host-session-reflections)]
          (cond
            [(= kind 0)
              (match (ctfe_support.ctfe-reflect-info-for-type-with-pools
                pools
                infos
                ty)
                [(ctfe_support.CtfeMaybeReflectInfo.Some
                    (ctfe_support.CtfeReflectInfo.Struct _ _ _ _ _ fields _))
                  (match (ctfe_support.ctfe-reflect-field-type-at
                    fields
                    pools
                    infos
                    first-index)
                    [(ctfe_support.ResultCtfeTypeLookup.Ok field-ty)
                      (compiler-comptime-host-replace!
                        1
                        (ctfe_support.CompilerCtfeValue.Type field-ty))]
                    [(ctfe_support.ResultCtfeTypeLookup.Err _)
                      tlci.tlci-host-callback-status-bad-request])]
                [_ tlci.tlci-host-callback-status-bad-request])]
            [(= kind 1)
              (match (ctfe_support.ctfe-reflect-info-for-type-with-pools
                pools
                infos
                ty)
                [(ctfe_support.CtfeMaybeReflectInfo.Some
                    (ctfe_support.CtfeReflectInfo.Enum _ _ _ _ _ variants _))
                  (match (ctfe_support.ctfe-reflect-variant-payloads-at
                    variants
                    first-index)
                    [(ctfe_support.ResultCtfeTypeListLookup.Ok payloads)
                      (match (ctfe_support.ctfe-type-list-ref-with-pools
                        payloads
                        pools
                        infos
                        second-index)
                        [(ctfe_support.ResultCtfeTypeLookup.Ok payload-ty)
                          (compiler-comptime-host-replace!
                            1
                            (ctfe_support.CompilerCtfeValue.Type payload-ty))]
                        [(ctfe_support.ResultCtfeTypeLookup.Err _)
                          tlci.tlci-host-callback-status-bad-request])]
                    [(ctfe_support.ResultCtfeTypeListLookup.Err _)
                      tlci.tlci-host-callback-status-bad-request])]
                [_ tlci.tlci-host-callback-status-bad-request])]
            [else
              (match (ctfe_support.ctfe-reflect-resolve-type-with-pools
                pools
                infos
                ty)
                [(ast.AstType.Tuple elems)
                  (match (ctfe_support.ctfe-type-list-ref-with-pools
                    (deref elems)
                    pools
                    infos
                    first-index)
                    [(ctfe_support.ResultCtfeTypeLookup.Ok element-ty)
                      (compiler-comptime-host-replace!
                        1
                        (ctfe_support.CompilerCtfeValue.Type element-ty))]
                    [(ctfe_support.ResultCtfeTypeLookup.Err _)
                      tlci.tlci-host-callback-status-bad-request])]
                [_ tlci.tlci-host-callback-status-bad-request])]))]
      [_ tlci.tlci-host-callback-status-bad-request])))

;; Every named host callback takes the session cookie plus three raw i64
;; arguments (immediates or a caller byte range) and returns an i64. Its body
;; runs under one shared guard: a closed or foreign session answers
;; bad-request, and an already latched failure is replayed, so the first
;; failing callback decides the dispatch status.
;;
;; A data callback answers a value (a 1/0 predicate, a count, a byte) and does
;; not latch it; a negative value is a malformed-request sentinel the
;; generated entry translates to bad-request before unwinding.
(defmacro (compiler-comptime-host-data-callback [session : Expr] [body : Expr]) : i64
  `(if (or
    (= compiler-comptime-host-session-cookie 0)
    (not (= ,session compiler-comptime-host-session-cookie)))
    tlci.tlci-host-callback-status-bad-request
    (if (not
      (=
        compiler-comptime-host-session-status
        tlci.tlci-host-callback-status-ok))
      compiler-comptime-host-session-status
      ,body)))

;; A status callback latches its own first non-ok result into the session.
(defmacro (compiler-comptime-host-status-callback
  [session : Expr]
  [body : Expr]) : i64
  `(compiler-comptime-host-data-callback
    ,session
    (let
      [result : i64 ,body]
      (begin
        (when
          (not (= result tlci.tlci-host-callback-status-ok))
          (set! compiler-comptime-host-session-status result))
        result))))

(define (compiler-comptime-host-callback-fuel-check
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (> compiler-comptime-host-session-fuel 0)
      (begin
        (set!
          compiler-comptime-host-session-fuel
          (- compiler-comptime-host-session-fuel 1))
        tlci.tlci-host-callback-status-ok)
      tlci.tlci-host-callback-status-fuel-exhausted)))

(define (compiler-comptime-host-callback-diagnostic
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (begin
      (if (and (> arg-a 0) (>= arg-b 0))
        (set!
          (array-ref compiler-comptime-host-diagnostic 0)
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b)))
        unit)
      tlci.tlci-host-callback-status-diagnostic)))

;; Native traps and explicit aborts use the fixed table slot rather than the
;; named callback registry. The callback follows the same first-failure rule
;; as status-returning helpers: it records status 3 without committing the
;; value stack, and a later commit observes the latched abort. The raw ABI
;; supplies host context through the hidden-environment register, leaving the
;; five explicit arguments below.
(define (compiler-comptime-host-callback-abort
  [session : i64]
  [_reason : i64]
  [message-address : i64]
  [message-length : i64]
  [_symbol : i64]) : i64
  (if (or
    (= compiler-comptime-host-session-cookie 0)
    (not (= session compiler-comptime-host-session-cookie)))
    tlci.tlci-host-callback-status-bad-request
    (begin
      (when
        (and (> message-address 0) (>= message-length 0))
        (set!
          (array-ref compiler-comptime-host-diagnostic 0)
          (unsafe
            (string-from-bytes
              (int->ptr message-address : (Ptr u8))
              message-length))))
      (when
        (=
          compiler-comptime-host-session-status
          tlci.tlci-host-callback-status-ok)
        (set!
          compiler-comptime-host-session-status
          tlci.tlci-host-callback-status-abort))
      tlci.tlci-host-callback-status-ok)))

;; Scratch lifecycle ops: the compiler-owned session builds results on its
;; value stack, not through host scratch, so these are no-ops. Registration
;; shells issue only scratch-reset, so accepting it lets a shell dispatch
;; run cleanly and commit no result -- the route then interprets it.
(define (compiler-comptime-host-callback-scratch-alloc
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    tlci.tlci-host-callback-status-ok))

(define (compiler-comptime-host-callback-scratch-reset
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    tlci.tlci-host-callback-status-ok))

(define (compiler-comptime-host-callback-expr-var
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [name : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        ;; Reproduce the interpreted quote's variable exactly: the lexer's
        ;; source-name id for the spelling, marked as template source so
        ;; dotted spellings resolve through the same hygiene path as an
        ;; interpreted expansion.
        [node : i64
          (ast.ast-node-pool-context-expr-push
            (compiler-comptime-host-session-pools)
            (ast.AstExpr.Var
              (compiler-comptime-host-template-source-id
                (ci.intern-source-slice name 0 (string.string-length name)))))]
        (compiler-comptime-host-push-expr! node)))))

;; Module values cross the callback boundary as their canonical identity
;; String. module-name preserves that exact value and identity for a
;; following computed String consumer such as expr-var-from-value.
(define (compiler-comptime-host-callback-module-name
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      ;; Interpreted string arguments also accept inspected syntax names,
      ;; normalized to the public String result.
      (match (ctfe_support.ctfe-value-named
        (compiler-comptime-host-stack-value 1))
        [(ctfe_support.CtfeMaybeNamed.Some text id)
          (compiler-comptime-host-replace!
            1
            (ctfe_support.CompilerCtfeValue.String text id))]
        [(ctfe_support.CtfeMaybeNamed.None)
          tlci.tlci-host-callback-status-bad-request]))))

;; Resolve a named macro hook exactly like interpreted CTFE: the module and
;; hook are comptime Strings on the stack, and a successful lookup becomes
;; one canonical qualified Var expression.
(define (compiler-comptime-host-callback-module-hook
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (match (ctfe_support.ctfe-value-named
        (compiler-comptime-host-stack-value 2))
        [(ctfe_support.CtfeMaybeNamed.Some module module-id)
          (match (ctfe_support.ctfe-value-named
            (compiler-comptime-host-stack-value 1))
            [(ctfe_support.CtfeMaybeNamed.Some name name-id)
              (compiler-comptime-host-replace-built!
                2
                (ctfe_support.ctfe-module-hook
                  (compiler-comptime-host-session-macro-state-value)
                  (compiler-comptime-host-session-pools)
                  module
                  module-id
                  name
                  name-id))]
            [(ctfe_support.CtfeMaybeNamed.None)
              tlci.tlci-host-callback-status-bad-request])]
        [(ctfe_support.CtfeMaybeNamed.None)
          tlci.tlci-host-callback-status-bad-request]))))

;; Module-value queries over the two String/Name stack values, `query-kind` as
;; in ctfe-module-value. Existence (kind 0) is answered as data: 1/0, or a
;; negative malformed-request sentinel.
(define (compiler-comptime-host-module-value-query! [query-kind : i64]) : i64
  (let
    [malformed : i64
      (if (= query-kind 0)
        -3
        tlci.tlci-host-callback-status-bad-request)]
    (if (< compiler-comptime-host-stack-len 2)
      malformed
      (match (compiler-comptime-host-value-module-index
        (compiler-comptime-host-stack-value 2))
        [(ctfe_support.CtfeMaybeNamed.Some module module-id)
          (match (compiler-comptime-host-value-module-index
            (compiler-comptime-host-stack-value 1))
            [(ctfe_support.CtfeMaybeNamed.Some name name-id)
              (let
                [built : ctfe_support.CtfeBuilt
                  (ctfe_support.ctfe-module-value
                    (compiler-comptime-host-session-macro-state-value)
                    (compiler-comptime-host-session-pools)
                    query-kind
                    module
                    module-id
                    name
                    name-id)]
                (if (= query-kind 0)
                  (begin
                    (compiler-comptime-host-drop! 2)
                    (match built
                      [(ctfe_support.CtfeBuilt.Ok
                          (ctfe_support.CompilerCtfeValue.Bool found))
                        (if found
                          1
                          0)]
                      [_ 0]))
                  (compiler-comptime-host-replace-built! 2 built)))]
            [(ctfe_support.CtfeMaybeNamed.None) malformed])]
        [(ctfe_support.CtfeMaybeNamed.None) malformed]))))

(define (compiler-comptime-host-callback-module-value?
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (compiler-comptime-host-module-value-query! 0)))

(define (compiler-comptime-host-callback-module-value-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-module-value-query! 1)))

(define (compiler-comptime-host-callback-module-value-expr
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-module-value-query! 2)))

;; Validate the formatting protocol signature as a data callback. Both Type
;; values are consumed; 1/0 is the predicate result and negative values retain
;; the callback ABI's malformed-request meaning.
(define (compiler-comptime-host-callback-function-shared-borrow-returns-string?
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      -3
      (let
        [value-type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [signature-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match signature-value
          [(ctfe_support.CompilerCtfeValue.Type signature)
            (match value-type-value
              [(ctfe_support.CompilerCtfeValue.Type value-type)
                (begin
                  (compiler-comptime-host-drop! 2)
                  (if (ctfe_support.ctfe-function-shared-borrow-returns-string?
                    (compiler-comptime-host-ctfe-env)
                    signature
                    value-type)
                    1
                    0))]
              [_ -3])]
          [_ -3])))))

(define (compiler-comptime-host-callback-expr-list-empty
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.ExprList (ast.ast-expr-list-new)))))

;; Public list cons keeps the computed head before every existing tail item;
;; this differs from the append op used while walking quasiquote source order.
(define (compiler-comptime-host-callback-expr-list-cons
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [rest-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [head-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< head-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match rest-value
            [(ctfe_support.CompilerCtfeValue.ExprList rest)
              (let
                [next : ast.AstExprList
                  (ast.ast-expr-list-with-capacity (+ rest.len 1))]
                (begin
                  (ast.ast-expr-list-push (&mut next) head-node)
                  (ast.ast-expr-list-append-from (&mut next) (& rest) 0)
                  (compiler-comptime-host-replace!
                    2
                    (ctfe_support.CompilerCtfeValue.ExprList next))))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

(define (compiler-comptime-host-callback-expr-list-append
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< node 0)
          tlci.tlci-host-callback-status-bad-request
          (match list-value
            [(ctfe_support.CompilerCtfeValue.ExprList items)
              (let
                [next : ast.AstExprList items]
                (begin
                  (ast.ast-expr-list-push (&mut next) node)
                  (compiler-comptime-host-replace!
                    2
                    (ctfe_support.CompilerCtfeValue.ExprList next))))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

(define (compiler-comptime-host-callback-push-operand
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-push!
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-operands
          arg-a)))))

(define (compiler-comptime-host-callback-expr-call
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [args-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [callee-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< callee-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match args-value
            [(ctfe_support.CompilerCtfeValue.ExprList items)
              (let
                [pools : ast.AstNodePoolContext
                  (compiler-comptime-host-session-pools)]
                ;; The callee arrives spanned or unspanned exactly as the
                ;; template built it: expr-span re-wraps a template head
                ;; before this op runs, and the provenance note reads
                ;; through any wrapper. Refs #5212.
                [node : i64
                  (ctfe_support.ctfe-ast-expr-call-with-provenance
                    (compiler-comptime-host-session-macro-state-value)
                    pools
                    callee-node
                    items)]
                (compiler-comptime-host-replace-expr! 2 node))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

(define (compiler-comptime-host-callback-expr-shared-call1
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [value-node : i64 (compiler-comptime-host-stack-node 1)]
        [callee-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< value-node 0) (< callee-node 0))
          tlci.tlci-host-callback-status-bad-request
          (let
            [pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            [node : i64
              (ctfe_support.ctfe-expr-shared-call1-node-with-pools
                (compiler-comptime-host-session-macro-state-value)
                pools
                callee-node
                value-node)]
            (compiler-comptime-host-replace-expr! 2 node)))))))

;; Does `node` already carry a parser or template source-span wrapper?
;; `ctfe-quote-preserve-unquoted-source-span?` asks exactly this question of a
;; substituted unquote result before it decides to keep the caller's origin.
(define (compiler-comptime-host-node-spanned?
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools node)
    [(ast.AstExpr.Spanned _ _) true]
    [_ false]))

;; Re-wrap the stack top in one template source span. `unquoted?` marks a
;; template position that was an unquote, where a value that already carries
;; its own call-site span keeps it; every other position takes the template's
;; span unconditionally. A stack top holding no expression node -- a type, a
;; comptime scalar, a list under construction -- is left alone, matching the
;; interpreted quote, which only ever spans expressions.
(define (compiler-comptime-host-span-step!
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]
  [unquoted? : bool]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (let
      [value : ctfe_support.CompilerCtfeValue
        (compiler-comptime-host-stack-value 1)]
      [span : ast.AstSourceSpan
        (ast.ast-source-span
          arg-a
          arg-b
          (shr arg-c 32)
          (bit-and arg-c 4294967295))]
      (match value
        [(ctfe_support.CompilerCtfeValue.Expr node ty)
          (let
            [pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            (if (and
              unquoted?
              (compiler-comptime-host-node-spanned? pools node))
              tlci.tlci-host-callback-status-ok
              (compiler-comptime-host-replace!
                1
                (ctfe_support.CompilerCtfeValue.Expr
                  (ast.ast-expr-source-view-with-pools pools node span)
                  ty))))]
        [(ctfe_support.CompilerCtfeValue.CapturedExpr node ty pools)
          (if (and unquoted? (compiler-comptime-host-node-spanned? pools node))
            tlci.tlci-host-callback-status-ok
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.CapturedExpr
                (ast.ast-expr-source-view-with-pools pools node span)
                ty
                pools)))]
        [_ tlci.tlci-host-callback-status-ok]))))

(define (compiler-comptime-host-callback-expr-span
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-span-step! arg-a arg-b arg-c false)))

(define (compiler-comptime-host-callback-expr-span-unquoted
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-span-step! arg-a arg-b arg-c true)))

;; Tuple templates share the expression-list builder with calls and other
;; variadic nodes. Consume that list and preserve its child node identities
;; and template-source marks exactly as interpreted quasiquote does.
(define (compiler-comptime-host-callback-expr-tuple
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.ExprList items)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-node-pool-context-expr-push
              (compiler-comptime-host-session-pools)
              (ast.AstExpr.Tuple items)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

(define (compiler-comptime-host-callback-expr-array
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.ExprList items)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-node-pool-context-expr-push
              (compiler-comptime-host-session-pools)
              (ast.AstExpr.Array items)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Intrinsic two-operand place/array nodes: pop the second operand then the
;; target and push the node the parser recognizes for array-ref, replace!, or
;; array-push, matching the interpreted quasiquote builders.
(define (compiler-comptime-host-callback-expr-array-ref
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-build-binary-intrinsic! 0)))

;; array-take!: pop the target, liveness bitmap, and index expressions and
;; push the dedicated consuming extraction node reconstructed by interpreted
;; quasiquote.
(define (compiler-comptime-host-callback-expr-array-take
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 3)
      tlci.tlci-host-callback-status-bad-request
      (let
        [index-node : i64 (compiler-comptime-host-stack-node 1)]
        [live-node : i64 (compiler-comptime-host-stack-node 2)]
        [target-node : i64 (compiler-comptime-host-stack-node 3)]
        (if (or (< index-node 0) (< live-node 0) (< target-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            3
            (ast.ast-expr-array-take-with-pools
              (compiler-comptime-host-session-pools)
              target-node
              live-node
              index-node)))))))

(define (compiler-comptime-host-callback-expr-replace
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-build-binary-intrinsic! 2)))

(define (compiler-comptime-host-callback-expr-array-push
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-build-binary-intrinsic! 1)))

;; make-array: pop the size expression and the element type value and push
;; the make-array node, matching the interpreted quote (the type passes
;; through by identity).
(define (compiler-comptime-host-callback-expr-make-array
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [size-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< size-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match type-value
            [(ctfe_support.CompilerCtfeValue.Type ty)
              (let
                [node : i64
                  (ast.ast-expr-make-array-with-cells
                    (compiler-comptime-host-pool-cell-address 0)
                    (compiler-comptime-host-pool-cell-address 1)
                    ty
                    size-node)]
                (compiler-comptime-host-replace-expr! 2 node))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; Reflection: 1/0 as data when the type operand's kind string matches
;; the caller bytes (the same ctfe mapping interpretation uses); negative
;; reports a bad request without touching session state.
(define (compiler-comptime-host-callback-operand-type-kind-eq
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-operand-count)
      (<= arg-b 0)
      (< _arg-c 0))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        arg-a)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (if (string.eq
            (let
              [host-pools : ast.AstNodePoolContext
                (compiler-comptime-host-session-pools)]
              [host-reflections : ctfe_support.CtfeReflectInfoList
                (compiler-comptime-host-session-reflections)]
              (ctfe_support.ctfe-type-kind-with-reflections-and-pools
                host-pools
                host-reflections
                ty))
            (unsafe
              (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
            1
            0)]
        [_ -3]))))

;; operand-expr-type-kind-eq: the same probe over an Expr operand's
;; produced type, so `(match (type-kind (comptime.expr-type v)) ...)`
;; dispatches without materializing the type on the value stack. An
;; untyped Expr operand is a malformed request here; the value-position
;; expr-type op reports the interpreted diagnostic instead.
(define (compiler-comptime-host-callback-operand-expr-type-kind-eq
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-operand-count)
      (<= arg-b 0)
      (< _arg-c 0))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        arg-a)
        [(ctfe_support.CompilerCtfeValue.Expr _ ty)
          (let
            [pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            [actual-ty : ast.AstType
              (ctfe_support.ctfe-captured-expr-type-inner-with-pools pools ty)]
            (if (ctfe_support.ctfe-untyped-expr-type? actual-ty)
              -3
              (if (string.eq
                (let
                  [host-reflections : ctfe_support.CtfeReflectInfoList
                    (compiler-comptime-host-session-reflections)]
                  (ctfe_support.ctfe-type-kind-with-reflections-and-pools
                    pools
                    host-reflections
                    (ctfe_support.ctfe-reflect-resolve-type-with-pools
                      pools
                      host-reflections
                      actual-ty)))
                (unsafe
                  (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
                1
                0)))]
        [_ -3]))))

;; operand-type-key-eq: the canonical type-key of a type operand against
;; caller bytes, the `(match (type-key T) ...)` dispatch.
(define (compiler-comptime-host-callback-operand-type-key-eq
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-operand-count)
      (<= arg-b 0)
      (< _arg-c 0))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        arg-a)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (if (string.eq
            (let
              [host-pools : ast.AstNodePoolContext
                (compiler-comptime-host-session-pools)]
              [host-reflections : ctfe_support.CtfeReflectInfoList
                (compiler-comptime-host-session-reflections)]
              (ctfe_support.ctfe-type-key-with-reflections-and-pools
                host-pools
                host-reflections
                ty))
            (unsafe
              (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
            1
            0)]
        [_ -3]))))

;; expr-type: pop an Expr value and push its resolved produced type, the
;; same mapping `ctfe-eval-expr-type-call` uses -- including its
;; "expr-type requires a typechecked Expr" diagnostic.
(define (compiler-comptime-host-callback-expr-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Expr _ ty)
          (let
            [reflections : ctfe_support.CtfeReflectInfoList
              (compiler-comptime-host-session-reflections)]
            (compiler-comptime-host-replace-built!
              1
              (ctfe_support.ctfe-expr-type-value
                (compiler-comptime-host-session-pools)
                reflections
                ty)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; type-expr: pop one reflected Type value and push one opaque TypeLiteral Expr
;; allocated in the active host pools. This is the exact inverse node shape of
;; expr-list-type-nth and mirrors ctfe-eval-type-expr-call.
(define (compiler-comptime-host-callback-type-expr
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (let
            [pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            (compiler-comptime-host-replace-expr!
              1
              (ast.ast-expr-type-literal-with-pools pools ty)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; expr-cast: pop the type value then the operand expression and push the
;; cast node the parser produces for `(cast e : T)`. The producer emits the
;; operand template first and the type second.
(define (compiler-comptime-host-callback-expr-cast
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [value-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< value-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match type-value
            [(ctfe_support.CompilerCtfeValue.Type ty)
              (compiler-comptime-host-replace-expr!
                2
                (ast.ast-expr-cast-with-pools
                  (compiler-comptime-host-session-pools)
                  value-node
                  ty))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; expr-ann: pop the type value then the operand expression and preserve the
;; annotation node produced by `(ann e : T)`.
(define (compiler-comptime-host-callback-expr-ann
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [value-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< value-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match type-value
            [(ctfe_support.CompilerCtfeValue.Type ty)
              (compiler-comptime-host-replace-expr!
                2
                (ast.ast-expr-ann-with-pools
                  (compiler-comptime-host-session-pools)
                  value-node
                  ty))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; expr-init: pop a type value and push the typed `(init : T)` node produced by
;; the parser. Contextual `(init)` remains outside the native template subset.
(define (compiler-comptime-host-callback-expr-init
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-init-with-pools
              (compiler-comptime-host-session-pools)
              ty))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

(define (compiler-comptime-host-callback-expr-bool-literal
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push-expr!
      (ast.ast-node-pool-context-expr-push
        (compiler-comptime-host-session-pools)
        (ast.AstExpr.Literal (ast.AstLiteral.Bool (not (= arg-a 0))))))))

(define (compiler-comptime-host-callback-expr-int-literal
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push-expr!
      (ast.ast-node-pool-context-expr-push
        (compiler-comptime-host-session-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int arg-a))))))

;; Template string literal: the lexer interns literal text through the
;; source-name session, so the same spelling maps to the same id here.
(define (compiler-comptime-host-callback-expr-string
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [text : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (compiler-comptime-host-push-expr!
          (ast.ast-node-pool-context-expr-push
            (compiler-comptime-host-session-pools)
            (ast.AstExpr.Literal
              (ast.AstLiteral.String
                (ci.intern-source-slice text 0 (string.string-length text))))))))))

;; Pop a splice ExprList then the list under construction and push the
;; concatenation, matching the interpreted quote's unquote-splicing step.
(define (compiler-comptime-host-callback-expr-splice
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [splice-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match list-value
          [(ctfe_support.CompilerCtfeValue.ExprList items)
            (match (compiler-comptime-host-value-expr-list splice-value)
              [(CompilerCtfeMaybeExprList.Some splice-items)
                (let
                  [next : ast.AstExprList
                    (ctfe_support.ctfe-expr-list-append items splice-items)]
                  (compiler-comptime-host-replace!
                    2
                    (ctfe_support.CompilerCtfeValue.ExprList next)))]
              [(CompilerCtfeMaybeExprList.None)
                tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

;; Pop else, then, and cond expressions and push the if node the parser
;; produces, matching the interpreted quote.
(define (compiler-comptime-host-callback-expr-if
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 3)
      tlci.tlci-host-callback-status-bad-request
      (let
        [else-node : i64 (compiler-comptime-host-stack-node 1)]
        [then-node : i64 (compiler-comptime-host-stack-node 2)]
        [cond-node : i64 (compiler-comptime-host-stack-node 3)]
        (if (or (< else-node 0) (< then-node 0) (< cond-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            3
            (ast.ast-expr-if-with-pools
              (compiler-comptime-host-session-pools)
              cond-node
              then-node
              else-node)))))))

;; Item count of a variadic ExprList operand as data; negative reports a
;; bad request without touching session state (the generated entry
;; translates it to the public bad-request status before unwinding).
(define (compiler-comptime-host-callback-expr-list-length
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (let
        [value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-operands
            arg-a)]
        (match (compiler-comptime-host-value-expr-list value)
          [(CompilerCtfeMaybeExprList.Some items)
            (ctfe_support.ctfe-expr-list-length items)]
          [(CompilerCtfeMaybeExprList.None) -3])))))

;; Item count of a variadic ExprBindingClauseList operand as data.
(define (compiler-comptime-host-callback-expr-binding-clause-list-length
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        arg-a)
        [(ctfe_support.CompilerCtfeValue.ExprBindingClauseList clauses)
          (ctfe_support.ctfe-expr-binding-clause-list-length clauses)]
        [_ -3]))))

;; syntax-name-fresh: replace a comptime String/Name value with the generated
;; syntax identity interpreted CTFE materializes for the same spelling.
(define (compiler-comptime-host-callback-syntax-name-fresh
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.String text _)
          (compiler-comptime-host-replace!
            1
            (ctfe_support.CompilerCtfeValue.Name
              (owned_view.compiler-owned-shared-view text)
              (ctfe_support.ctfe-materialize-generated-name-id text)))]
        [(ctfe_support.CompilerCtfeValue.Name text _)
          (compiler-comptime-host-replace!
            1
            (ctfe_support.CompilerCtfeValue.Name
              (owned_view.compiler-owned-shared-view text)
              (ctfe_support.ctfe-materialize-generated-name-id text)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; expr-begin-unit: replace an expression-list value with a begin node whose
;; final expression is unit, matching the public builder used by `for`.
(define (compiler-comptime-host-callback-expr-begin-unit
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        (match (compiler-comptime-host-value-expr-list value)
          [(CompilerCtfeMaybeExprList.Some items)
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Expr
                (ctfe_support.ctfe-expr-begin-unit-node
                  items
                  (compiler-comptime-host-session-pools))
                (ast.AstType.Unit)))]
          [(CompilerCtfeMaybeExprList.None)
            tlci.tlci-host-callback-status-bad-request])))))

;; Index a variadic ExprList operand: `a` names the operand and `b` the
;; element, mirroring the interpreted `expr-list-nth` builtin (an
;; out-of-range index is a bad request, and a captured operand keeps its
;; caller pools on the pushed element). Refs #5617.
(define (compiler-comptime-host-callback-expr-list-nth
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (let
        [operand : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-operands
            arg-a)]
        (match (compiler-comptime-host-value-expr-list operand)
          [(CompilerCtfeMaybeExprList.Some items)
            (if (or
              (< arg-b 0)
              (>= arg-b (ctfe_support.ctfe-expr-list-length items)))
              tlci.tlci-host-callback-status-bad-request
              (let
                [node : i64 (ctfe_support.ctfe-expr-list-nth items arg-b)]
                (match operand
                  [(ctfe_support.CompilerCtfeValue.CapturedExprList _ pools)
                    (compiler-comptime-host-push!
                      (ctfe_support.CompilerCtfeValue.CapturedExpr
                        node
                        (ctfe_support.ctfe-untyped-expr-type)
                        pools))]
                  [_
                    (compiler-comptime-host-push!
                      (ctfe_support.CompilerCtfeValue.Expr
                        node
                        (ctfe_support.ctfe-untyped-expr-type)))])))]
          [(CompilerCtfeMaybeExprList.None)
            tlci.tlci-host-callback-status-bad-request])))))

;; Index a variadic ExprList operand and resolve the selected captured
;; TypeLiteral into a comptime Type value. Refs #6552.
(define (compiler-comptime-host-callback-expr-list-type-nth
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-replace-built!
        0
        (ctfe_support.ctfe-expr-list-type-nth
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-operands
            arg-a)
          arg-b
          (compiler-comptime-host-session-pools))))))

;; Index a variadic ExprBindingClauseList operand and push the selected clause.
(define (compiler-comptime-host-callback-expr-binding-clause-list-nth
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-operands
        arg-a)
        [(ctfe_support.CompilerCtfeValue.ExprBindingClauseList clauses)
          (if (or
            (< arg-b 0)
            (>=
              arg-b
              (ctfe_support.ctfe-expr-binding-clause-list-length clauses)))
            tlci.tlci-host-callback-status-bad-request
            (compiler-comptime-host-push!
              (ctfe_support.CompilerCtfeValue.ExprBindingClause
                (ctfe_support.ctfe-expr-binding-clause-list-nth clauses arg-b))))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Project name/type/init from an ExprBindingClause on the session stack.
;; selector: 0=name, 1=type syntax, 2=initializer expression.
(define (compiler-comptime-host-expr-binding-clause-project! [selector : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci.tlci-host-callback-status-bad-request
    (match (compiler-comptime-host-stack-value 1)
      [(ctfe_support.CompilerCtfeValue.ExprBindingClause clause)
        (let
          [value : ctfe_support.CompilerCtfeValue
            (cond
              [(= selector 0)
                (ctfe_support.ctfe-name-value
                  (ci.intern-syntax-id-value
                    (ctfe_support.ctfe-expr-binding-clause-name-id clause)))]
              [(= selector 1)
                (ctfe_support.CompilerCtfeValue.Expr
                  (ctfe_support.ctfe-expr-binding-clause-type clause)
                  (ctfe_support.ctfe-untyped-expr-type))]
              [else
                (let
                  [produced : ast.AstType
                    (owned_view.compiler-owned-place-shared-view
                      clause.init-produced)]
                  [pools : ast.AstNodePoolContext
                    (compiler-comptime-host-session-pools)]
                  (ctfe_support.CompilerCtfeValue.Expr
                    (ctfe_support.ctfe-caller-origin-expr-node-with-pools
                      pools
                      (ctfe_support.ctfe-expr-binding-clause-init clause)
                      (owned_view.compiler-owned-shared-view produced))
                    (ctfe_support.ctfe-caller-origin-expr-type-inner-with-pools
                      pools
                      produced)))])]
          (compiler-comptime-host-replace! 1 value))]
      [_ tlci.tlci-host-callback-status-bad-request])))

(define (compiler-comptime-host-callback-expr-binding-clause-name
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-expr-binding-clause-project! 0)))

(define (compiler-comptime-host-callback-expr-binding-clause-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-expr-binding-clause-project! 1)))

(define (compiler-comptime-host-callback-expr-binding-clause-init
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-expr-binding-clause-project! 2)))

;; Data probe for whether a clause stored in local slot `a` has an annotation.
(define (compiler-comptime-host-callback-expr-binding-clause-has-type?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-locals
        arg-a)
        [(ctfe_support.CompilerCtfeValue.ExprBindingClause clause)
          (if (ctfe_support.ctfe-expr-binding-clause-has-type? clause)
            1
            0)]
        [_ -3]))))

;; Pop an expression list and push the begin node the parser produces.
(define (compiler-comptime-host-callback-expr-begin
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.ExprList items)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-node-pool-context-expr-push
              (compiler-comptime-host-session-pools)
              (ast.AstExpr.Begin items)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Pop the right then the left operand expression and push a binary node
;; for the AstBinOp ordinal in `a`.
(define (compiler-comptime-host-callback-expr-binary-op
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< compiler-comptime-host-stack-len 2) (< arg-a 0) (> arg-a 17))
      tlci.tlci-host-callback-status-bad-request
      (let
        [right-node : i64 (compiler-comptime-host-stack-node 1)]
        [left-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< right-node 0) (< left-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            2
            (ast.ast-expr-binary-with-pools
              (compiler-comptime-host-session-pools)
              (compiler-comptime-host-binop-for-ordinal arg-a)
              left-node
              right-node)))))))

;; Pop the operand expression and push a unary node for the AstUnOp
;; ordinal in `a`.
(define (compiler-comptime-host-callback-expr-unary-op
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< compiler-comptime-host-stack-len 1) (< arg-a 0) (> arg-a 2))
      tlci.tlci-host-callback-status-bad-request
      (let
        [inner-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< inner-node 0)
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-unary-with-pools
              (compiler-comptime-host-session-pools)
              (compiler-comptime-host-unop-for-ordinal arg-a)
              inner-node)))))))

(define (compiler-comptime-host-callback-expr-char-literal
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push-expr!
      (ast.ast-node-pool-context-expr-push
        (compiler-comptime-host-session-pools)
        (ast.AstExpr.Literal (ast.AstLiteral.Char (cast arg-a : char)))))))

(define (compiler-comptime-host-callback-expr-unit-literal
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push-expr!
      (ast.ast-node-pool-context-expr-push
        (compiler-comptime-host-session-pools)
        (ast.AstExpr.Literal (ast.AstLiteral.Unit))))))

;; Computed-body locals: local-set pops one value into the named session
;; slot; local-get pushes the slot's value.
(define (compiler-comptime-host-callback-local-set
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (< compiler-comptime-host-stack-len 1))
      tlci.tlci-host-callback-status-bad-request
      (begin
        (set!
          (array-ref compiler-comptime-host-locals arg-a)
          (compiler-comptime-host-stack-value 1))
        (set! (array-ref compiler-comptime-host-locals-live arg-a) true)
        (compiler-comptime-host-drop! 1)
        tlci.tlci-host-callback-status-ok))))

(define (compiler-comptime-host-callback-local-get
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-push!
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals
          arg-a)))))

;; Pop a comptime String (or Name) value and push the variable node the
;; interpreted (comptime.)expr-var builtin produces.
(define (compiler-comptime-host-callback-expr-var-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-value-name-id
        (compiler-comptime-host-stack-value 1))
        [(ctfe_support.CtfeMaybeNameId.Some name-id)
          (let
            [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
            (compiler-comptime-host-replace!
              1
              (ctfe_support.ctfe-syntax-expr-push
                env
                (ast.AstExpr.Var name-id)
                (ctfe_support.ctfe-untyped-expr-type))))]
        [(ctfe_support.CtfeMaybeNameId.None)
          tlci.tlci-host-callback-status-bad-request]))))

;; Pop an expression list and push the bracket-clause node.
(define (compiler-comptime-host-callback-expr-bracket-clause
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.ExprList items)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-bracket-clause-with-pools
              (compiler-comptime-host-session-pools)
              items))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Pop the place expression and push a borrow node; immediate `a` is 1
;; for &mut and 0 for &, and `b`/`c` are the optional named lifetime's
;; byte pointer and length (0/0 for an inferred lifetime).
(define (compiler-comptime-host-callback-expr-borrow
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [place-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< place-node 0)
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-borrow-with-pools
              (compiler-comptime-host-session-pools)
              (not (= arg-a 0))
              (if (> arg-b 0)
                (ast.AstBorrowLifetime.Named
                  (ci.intern-source-slice
                    (unsafe
                      (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c))
                    0
                    _arg-c))
                (ast.AstBorrowLifetime.Inferred))
              place-node)))))))

;; Type identity reflection shares one registered callback: selector 0 is the
;; canonical type key, selector 1 is the nominal declaration module, and
;; selector 2 is its name. Keeping this as one host-table row avoids rebuilding
;; and relinking another callback for every macro dispatch. Refs #6000, #5606.
(define (compiler-comptime-host-callback-type-key
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (cond
            [(= arg-a 0)
              (compiler-comptime-host-replace!
                1
                (ctfe_support.ctfe-generated-string-value
                  (let
                    [host-pools : ast.AstNodePoolContext
                      (compiler-comptime-host-session-pools)]
                    [host-reflections : ctfe_support.CtfeReflectInfoList
                      (compiler-comptime-host-session-reflections)]
                    (ctfe_support.ctfe-type-key-with-reflections-and-pools
                      host-pools
                      host-reflections
                      ty))))]
            [(or (= arg-a 1) (= arg-a 2))
              (match (let
                [host-pools : ast.AstNodePoolContext
                  (compiler-comptime-host-session-pools)]
                [host-reflections : ctfe_support.CtfeReflectInfoList
                  (compiler-comptime-host-session-reflections)]
                (ctfe_support.ctfe-reflect-info-for-type-with-pools
                  host-pools
                  host-reflections
                  ty))
                [(ctfe_support.CtfeMaybeReflectInfo.Some info)
                  (compiler-comptime-host-replace!
                    1
                    (ctfe_support.ctfe-name-value
                      (if (= arg-a 1)
                        (ctfe_support.ctfe-reflect-info-nominal-module-id info)
                        (ctfe_support.ctfe-reflect-info-nominal-name-id info))))]
                [(ctfe_support.CtfeMaybeReflectInfo.None)
                  (compiler-comptime-host-diagnostic!
                    (if (= arg-a 1)
                      "type-nominal-module requires struct or enum type"
                      "type-nominal-name requires struct or enum type"))])]
            [else tlci.tlci-host-callback-status-bad-request])]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Indexed nominal-name reflection. The producer leaves the type value on
;; the stack and passes its generated i64 index in `a`.
(define (compiler-comptime-host-callback-struct-field-name
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-reflection-name-step! 0 arg-a)))

(define (compiler-comptime-host-callback-enum-variant-name
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-reflection-name-step! 1 arg-a)))

(define (compiler-comptime-host-callback-struct-field-count
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (compiler-comptime-host-reflection-count-step! 0 0)))

(define (compiler-comptime-host-callback-enum-variant-count
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (compiler-comptime-host-reflection-count-step! 1 0)))

(define (compiler-comptime-host-callback-enum-variant-payload-count
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (compiler-comptime-host-reflection-count-step! 2 arg-a)))

(define (compiler-comptime-host-callback-tuple-element-count
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (compiler-comptime-host-reflection-count-step! 3 0)))

(define (compiler-comptime-host-callback-struct-field-type
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-reflection-type-step! 0 arg-a 0)))

(define (compiler-comptime-host-callback-enum-variant-payload-type
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-reflection-type-step! 1 arg-a arg-b)))

(define (compiler-comptime-host-callback-tuple-element-type
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-reflection-type-step! 2 arg-a 0)))

;; string-append: pop the second then the first comptime String/Name value and
;; push the concatenation with the identity-aware dotted-name construction
;; used by interpretation. Generated-module protocol names depend on retaining
;; their structural prefix through `module + "." + member`. Refs #5606.
(define (compiler-comptime-host-callback-string-append
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [right-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [left-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match (ctfe_support.ctfe-value-named left-value)
          [(ctfe_support.CtfeMaybeNamed.Some left-text left-id)
            (match (ctfe_support.ctfe-value-named right-value)
              [(ctfe_support.CtfeMaybeNamed.Some right-text right-id)
                (compiler-comptime-host-replace!
                  2
                  (ctfe_support.ctfe-generated-string-append-value
                    left-text
                    left-id
                    right-text
                    right-id))]
              [(ctfe_support.CtfeMaybeNamed.None)
                tlci.tlci-host-callback-status-bad-request])]
          [(ctfe_support.CtfeMaybeNamed.None)
            tlci.tlci-host-callback-status-bad-request])))))

;; Pattern construction, mirroring the interpreted quote's pattern rebuild:
;; variant names pass through unmarked while Var/Binding names carry the
;; template-source mark.
(define (compiler-comptime-host-callback-pattern-wildcard
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.Pattern (ast.AstPattern.Wildcard)))))

(define (compiler-comptime-host-callback-pattern-binding
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (and (> arg-a 0) (>= arg-b 0))
      (let
        [name : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (compiler-comptime-host-push!
          (ctfe_support.CompilerCtfeValue.Pattern
            (ast.AstPattern.Binding
              (compiler-comptime-host-template-source-id
                (ci.intern-source-slice name 0 (string.string-length name)))))))
      (if (< compiler-comptime-host-stack-len 1)
        tlci.tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-value-name-id
          (compiler-comptime-host-stack-value 1))
          [(ctfe_support.CtfeMaybeNameId.Some name-id)
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Pattern
                (ctfe_support.ctfe-pat-binding-id name-id)))]
          [(ctfe_support.CtfeMaybeNameId.None)
            tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-build-pattern-binding-typed!
  [name-id : i64]
  [type-value : ctfe_support.CompilerCtfeValue]) : i64
  (let
    [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
    (match (ctfe_support.ctfe-pattern-binding-type-value
      type-value
      (ast.AstExpr.Literal (ast.AstLiteral.Unit))
      env
      compiler-comptime-host-session-fuel)
      [(ctfe_support.ResultCtfeQuoteType.Ok ty next-fuel)
        (begin
          (set! compiler-comptime-host-session-fuel next-fuel)
          (compiler-comptime-host-replace!
            2
            (ctfe_support.CompilerCtfeValue.Pattern
              (ast.AstPattern.Var name-id (ast.AstMaybeType.Some ty)))))]
      [(ctfe_support.ResultCtfeQuoteType.Err diag)
        (begin
          (set!
            (array-ref compiler-comptime-host-diagnostic 0)
            (__tl-project-field (__tl-box-place diag) message))
          tlci.tlci-host-callback-status-diagnostic)])))

(define (compiler-comptime-host-callback-pattern-binding-typed
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [name-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match (compiler-comptime-host-value-name-id name-value)
          [(ctfe_support.CtfeMaybeNameId.Some name-id)
            (compiler-comptime-host-build-pattern-binding-typed!
              name-id
              type-value)]
          [(ctfe_support.CtfeMaybeNameId.None)
            tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-pattern-variant
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (<= arg-a 0)
      (< arg-b 0)
      (< _arg-c 0)
      (< compiler-comptime-host-stack-len (+ _arg-c 1)))
      tlci.tlci-host-callback-status-bad-request
      (let
        [name : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (match (compiler-comptime-host-pop-pattern-list _arg-c)
          [(CompilerCtfeMaybePatternList.None)
            tlci.tlci-host-callback-status-bad-request]
          [(CompilerCtfeMaybePatternList.Some items)
            (compiler-comptime-host-push!
              (ctfe_support.CompilerCtfeValue.Pattern
                (ast.ast-pat-variant-id
                  (ci.intern-source-slice name 0 (string.string-length name))
                  items)))])))))

(define (compiler-comptime-host-callback-pattern-list-empty
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.PatternList (ast.ast-pattern-list-new)))))

(define (compiler-comptime-host-callback-pattern-list-cons
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [pattern-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match list-value
          [(ctfe_support.CompilerCtfeValue.PatternList items)
            (match pattern-value
              [(ctfe_support.CompilerCtfeValue.Pattern pattern)
                (let
                  [next : ast.AstPatternList items]
                  (begin
                    (ast.ast-pattern-list-push (&mut next) pattern)
                    (compiler-comptime-host-replace!
                      2
                      (ctfe_support.CompilerCtfeValue.PatternList next))))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-pattern-list-cons-from-values
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [rest-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [head-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match head-value
          [(ctfe_support.CompilerCtfeValue.Pattern head)
            (match rest-value
              [(ctfe_support.CompilerCtfeValue.PatternList rest)
                (compiler-comptime-host-replace!
                  2
                  (ctfe_support.CompilerCtfeValue.PatternList
                    (ast.ast-pattern-cons head rest)))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-pattern-list-bindings
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (cond
      [(or (< arg-a 0) (< compiler-comptime-host-stack-len 1))
        tlci.tlci-host-callback-status-bad-request]
      [(> arg-a compiler-comptime-host-session-fuel)
        tlci.tlci-host-callback-status-fuel-exhausted]
      [else
        (match (compiler-comptime-host-stack-value 1)
          [(ctfe_support.CompilerCtfeValue.String prefix _)
            (let
              [patterns : ast.AstPatternList
                (ast.ast-pattern-list-with-capacity arg-a)]
              [index : i64 0]
              (begin
                (while (< index arg-a)
                  (let
                    [name : String
                      (str_cat.str-cat
                        (owned_view.compiler-owned-shared-view prefix)
                        (string.int->string index))]
                    (begin
                      (ast.ast-pattern-list-push
                        (&mut patterns)
                        (ast.ast-pat-binding-id
                          (ctfe_support.ctfe-materialize-generated-name-id name)))
                      (set! index (+ index 1)))))
                (set!
                  compiler-comptime-host-session-fuel
                  (- compiler-comptime-host-session-fuel arg-a))
                (compiler-comptime-host-replace!
                  1
                  (ctfe_support.CompilerCtfeValue.PatternList patterns))))]
          [_ tlci.tlci-host-callback-status-bad-request])])))

(define (compiler-comptime-host-callback-pattern-variant-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [payloads-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [name-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match (ctfe_support.ctfe-value-named name-value)
          [(ctfe_support.CtfeMaybeNamed.Some text name-id)
            (match payloads-value
              [(ctfe_support.CompilerCtfeValue.PatternList payloads)
                (compiler-comptime-host-replace!
                  2
                  (ctfe_support.CompilerCtfeValue.Pattern
                    (ctfe_support.ctfe-pattern-variant
                      (compiler-comptime-host-session-source-names-value)
                      text
                      name-id
                      payloads)))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [(ctfe_support.CtfeMaybeNamed.None)
            tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-match-arm-list-cons-from-values
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [rest-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [head-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match head-value
          [(ctfe_support.CompilerCtfeValue.MatchArm head)
            (match rest-value
              [(ctfe_support.CompilerCtfeValue.MatchArmList rest)
                (compiler-comptime-host-replace!
                  2
                  (ctfe_support.CompilerCtfeValue.MatchArmList
                    (ast.ast-match-arm-cons head rest)))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-match-arm
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [pattern-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [body-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< body-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match pattern-value
            [(ctfe_support.CompilerCtfeValue.Pattern pattern)
              (compiler-comptime-host-replace!
                2
                (ctfe_support.CompilerCtfeValue.MatchArm
                  (ast.ast-match-arm pattern body-node)))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

(define (compiler-comptime-host-callback-match-arm-list-empty
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.MatchArmList (ast.ast-match-arm-list-new)))))

(define (compiler-comptime-host-callback-match-arm-list-cons
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [arm-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match list-value
          [(ctfe_support.CompilerCtfeValue.MatchArmList items)
            (match arm-value
              [(ctfe_support.CompilerCtfeValue.MatchArm arm)
                (let
                  [next : ast.AstMatchArmList items]
                  (begin
                    (ast.ast-match-arm-list-push (&mut next) arm)
                    (compiler-comptime-host-replace!
                      2
                      (ctfe_support.CompilerCtfeValue.MatchArmList next))))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-expr-match
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [arms-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [scrutinee-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< scrutinee-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match arms-value
            [(ctfe_support.CompilerCtfeValue.MatchArmList arms)
              (compiler-comptime-host-replace-expr!
                2
                (ast.ast-expr-match-with-pools
                  (compiler-comptime-host-session-pools)
                  scrutinee-node
                  arms))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; string-value: push the comptime String value for caller bytes, keeping
;; a parsed-source identity like the lexer's string tokens.
(define (compiler-comptime-host-callback-string-value
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [text : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        [string-id : i64
          (ci.intern-source-slice text 0 (string.string-length text))]
        (compiler-comptime-host-push!
          (ctfe_support.CompilerCtfeValue.String
            (ci.intern-str string-id)
            string-id))))))

;; diagnostic-from-value: pop a comptime String into the session
;; diagnostic and answer with the diagnostic status.
(define (compiler-comptime-host-callback-diagnostic-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.String text _)
          (begin
            (set! (array-ref compiler-comptime-host-diagnostic 0) text)
            (compiler-comptime-host-drop! 1)
            tlci.tlci-host-callback-status-diagnostic)]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; pattern-var: a unit/variable pattern for caller bytes with the
;; template-source mark, matching the interpreted quote.
(define (compiler-comptime-host-callback-pattern-var
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [name : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (compiler-comptime-host-push!
          (ctfe_support.CompilerCtfeValue.Pattern
            (ast.AstPattern.Var
              (compiler-comptime-host-template-source-id
                (ci.intern-source-slice name 0 (string.string-length name)))
              (ast.AstMaybeType.No))))))))

;; string-eq: pop two comptime String/Name values and answer 1/0 as data (a
;; negative value reports a bad request without touching session state).
;; Reflected names are accepted by interpreted public string helpers and by
;; native string-append, so comparisons must use the same conversion. Refs
;; #5606.
(define (compiler-comptime-host-callback-string-eq
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      -3
      (let
        [right-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [left-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match (ctfe_support.ctfe-value-named left-value)
          [(ctfe_support.CtfeMaybeNamed.Some left-text _)
            (match (ctfe_support.ctfe-value-named right-value)
              [(ctfe_support.CtfeMaybeNamed.Some right-text _)
                (begin
                  (compiler-comptime-host-drop! 2)
                  (if (string.eq left-text right-text)
                    1
                    0))]
              [(ctfe_support.CtfeMaybeNamed.None) -3])]
          [(ctfe_support.CtfeMaybeNamed.None) -3])))))

;; tuple-ref: pop the target expression and use the computed index in `a`.
(define (compiler-comptime-host-callback-expr-tuple-ref
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [target-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (or (< target-node 0) (< arg-a 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-tuple-ref-with-pools
              (compiler-comptime-host-session-pools)
              target-node
              arg-a)))))))

;; struct-get: pop the target expression and push the field access node
;; for the field name in `a`/`b`.
(define (compiler-comptime-host-callback-expr-struct-get
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 1))
      tlci.tlci-host-callback-status-bad-request
      (let
        [target-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< target-node 0)
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-struct-get-id-with-pools
              (compiler-comptime-host-session-pools)
              target-node
              (ci.intern-source-slice
                (unsafe
                  (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                0
                arg-b))))))))

;; Dynamic struct-get: pop the computed name after the target expression.
(define (compiler-comptime-host-callback-expr-struct-get-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [name-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [target-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< target-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match (compiler-comptime-host-value-name-id name-value)
            [(ctfe_support.CtfeMaybeNameId.Some name-id)
              (compiler-comptime-host-replace-expr!
                2
                (ast.ast-expr-struct-get-id-with-pools
                  (compiler-comptime-host-session-pools)
                  target-node
                  name-id))]
            [(ctfe_support.CtfeMaybeNameId.None)
              tlci.tlci-host-callback-status-bad-request]))))))

;; Dynamic struct-set: pop the value expression after the computed field name
;; and target expression. Name values preserve their structural source id;
;; String values receive the same syntax identity as interpreted CTFE.
(define (compiler-comptime-host-callback-expr-struct-set-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 3)
      tlci.tlci-host-callback-status-bad-request
      (let
        [name-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [value-node : i64 (compiler-comptime-host-stack-node 1)]
        [target-node : i64 (compiler-comptime-host-stack-node 3)]
        (if (or (< value-node 0) (< target-node 0))
          tlci.tlci-host-callback-status-bad-request
          (match (compiler-comptime-host-value-name-id name-value)
            [(ctfe_support.CtfeMaybeNameId.Some name-id)
              (compiler-comptime-host-replace!
                3
                (ctfe_support.CompilerCtfeValue.Expr
                  (ast.ast-expr-struct-set-id-with-pools
                    (compiler-comptime-host-session-pools)
                    target-node
                    name-id
                    value-node)
                  (ast.AstType.Unit)))]
            [(ctfe_support.CtfeMaybeNameId.None)
              tlci.tlci-host-callback-status-bad-request]))))))

;; Dynamic quasiquote set!: pop the reconstructed value after the evaluated
;; unquoted place, inspect that place through transparent source wrappers, and
;; build the same assignment node as interpreted CTFE. Every other place shape
;; uses the interpreted path's exact diagnostic. Refs #6550.
(define (compiler-comptime-host-callback-expr-set-from-place
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [value-node : i64 (compiler-comptime-host-stack-node 1)]
        [place-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< value-node 0) (< place-node 0))
          tlci.tlci-host-callback-status-bad-request
          (let
            [pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            [place : ast.AstExpr
              (compiler-comptime-host-unspanned-expr
                pools
                (ast.ast-node-pool-context-expr-get pools place-node))]
            [result-node : i64
              (match place
                [(ast.AstExpr.Var name)
                  (ast.ast-expr-set-id-with-pools pools name value-node)]
                [(ast.AstExpr.StructGet receiver field)
                  (ast.ast-expr-struct-set-id-with-pools
                    pools
                    receiver
                    field
                    value-node)]
                [(ast.AstExpr.BoxGet receiver)
                  (ast.ast-expr-box-set-with-pools pools receiver value-node)]
                [_ -1])]
            (if (< result-node 0)
              (compiler-comptime-host-diagnostic!
                "quasiquote set! target must evaluate to a name, struct field place, or box place")
              (compiler-comptime-host-replace!
                2
                (ctfe_support.CompilerCtfeValue.Expr
                  result-node
                  (ast.AstType.Unit))))))))))

;; array-set!: pop the value, index, and target expressions and push the
;; node the parser produces.
(define (compiler-comptime-host-callback-expr-array-set
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 3)
      tlci.tlci-host-callback-status-bad-request
      (let
        [value-node : i64 (compiler-comptime-host-stack-node 1)]
        [index-node : i64 (compiler-comptime-host-stack-node 2)]
        [target-node : i64 (compiler-comptime-host-stack-node 3)]
        (if (or (< value-node 0) (< index-node 0) (< target-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            3
            (ast.ast-expr-array-set-with-pools
              (compiler-comptime-host-session-pools)
              target-node
              index-node
              value-node)))))))

;; expr-struct-set: pop the value then the target expression and push the
;; internal StructSet node for the field name in
;; `a`/`b`, matching the interpreted quote's non-unquoted set! target path.
(define (compiler-comptime-host-callback-expr-struct-set
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 2))
      tlci.tlci-host-callback-status-bad-request
      (let
        [value-node : i64 (compiler-comptime-host-stack-node 1)]
        [target-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< value-node 0) (< target-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            2
            (ast.ast-expr-struct-set-id-with-pools
              (compiler-comptime-host-session-pools)
              target-node
              (ci.intern-source-slice
                (unsafe
                  (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                0
                arg-b)
              value-node)))))))

;; expr-return / expr-box / expr-box-get: pop one expression and push the
;; node the parser produces, matching the interpreted quote's unary
;; reconstruction of Return, Box, and BoxGet AST nodes.
(define (compiler-comptime-host-callback-expr-return
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 0)))

(define (compiler-comptime-host-callback-expr-box
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 1)))

(define (compiler-comptime-host-callback-expr-box-get
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 2)))

(define (compiler-comptime-host-callback-expr-box-take
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 7)))

;; Raw-pointer and `unsafe` template nodes (refs #5605).
(define (compiler-comptime-host-callback-expr-ptr-read
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 3)))

(define (compiler-comptime-host-callback-expr-ptr-addr-of
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 8)))

(define (compiler-comptime-host-callback-expr-ptr-to-int
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 4)))

(define (compiler-comptime-host-callback-expr-int-to-ptr
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-typed-pointer-node-step! 1)))

(define (compiler-comptime-host-callback-expr-string-data
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 5)))

(define (compiler-comptime-host-callback-expr-array-data
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-unary-node-step! 6)))

(define (compiler-comptime-host-callback-expr-string-from-bytes
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-ptr-binary-step! 2)))

(define (compiler-comptime-host-callback-expr-ptr-write
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-ptr-binary-step! 0)))

(define (compiler-comptime-host-callback-expr-ptr-offset
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-ptr-binary-step! 1)))

;; expr-unsafe pops an expression list and pushes the `(unsafe ...)` node
;; the parser produces, matching expr-begin's shape.
(define (compiler-comptime-host-callback-expr-unsafe
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.ExprList items)
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-node-pool-context-expr-push
              (compiler-comptime-host-session-pools)
              (ast.AstExpr.Unsafe items)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; expr-float-literal: push a float literal node carrying the caller bytes
;; verbatim, the same source text the interpreted quote preserves.
(define (compiler-comptime-host-callback-expr-float-literal
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [text : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (compiler-comptime-host-push-expr!
          (ast.ast-node-pool-context-expr-push
            (compiler-comptime-host-session-pools)
            (ast.AstExpr.Literal
              (ast.AstLiteral.Float
                (ci.intern-str
                  (ci.intern-source-slice text 0 (string.string-length text)))))))))))

;; let-binding: pop the init expression and push a binding for the name in
;; `a`/`b` with the template-source mark and no type annotation.
(define (compiler-comptime-host-callback-let-binding
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 1))
      tlci.tlci-host-callback-status-bad-request
      (let
        [init-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< init-node 0)
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace!
            1
            (ctfe_support.CompilerCtfeValue.LetBinding
              (ast.ast-let-binding-id
                (compiler-comptime-host-template-source-id
                  (ci.intern-source-slice
                    (unsafe
                      (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                    0
                    arg-b))
                (ast.AstMaybeType.No)
                init-node))))))))

(define (compiler-comptime-host-callback-let-binding-list-empty
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.LetBindingList
        (ast.ast-let-binding-list-new)))))

(define (compiler-comptime-host-callback-let-binding-list-cons
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [binding-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        (match list-value
          [(ctfe_support.CompilerCtfeValue.LetBindingList items)
            (match binding-value
              [(ctfe_support.CompilerCtfeValue.LetBinding binding)
                (let
                  [next : ast.AstLetBindingList items]
                  (begin
                    (ast.ast-let-binding-list-push (&mut next) binding)
                    (compiler-comptime-host-replace!
                      2
                      (ctfe_support.CompilerCtfeValue.LetBindingList next))))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [_ tlci.tlci-host-callback-status-bad-request])))))

;; expr-let: pop the body then the binding list and push the let node.
(define (compiler-comptime-host-callback-expr-let
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [list-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [body-node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< body-node 0)
          tlci.tlci-host-callback-status-bad-request
          (match list-value
            [(ctfe_support.CompilerCtfeValue.LetBindingList items)
              (compiler-comptime-host-replace-expr!
                2
                (ast.ast-expr-let-with-pools
                  (compiler-comptime-host-session-pools)
                  items
                  body-node))]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; Reconstruct a quasiquoted lambda. `arg-c` encodes parameter-count * 2 plus
;; one when an explicit return annotation is present. Parameter types, then
;; the optional return type, then the body are on the value stack. `arg-a` /
;; `arg-b` carry `<flags>:<name>\n` records for the parameters. Refs #6868.
(define (compiler-comptime-host-lambda-push!
  [param-count : i64]
  [has-ret? : bool]
  [payload : String]) : i64
  (let
    [value-count : i64
      (+
        param-count
        (if has-ret?
          1
          0)
        1)]
    [base : i64 (- compiler-comptime-host-stack-len value-count)]
    [payload-len : i64 (string.string-length payload)]
    [valid : bool (and (>= param-count 0) (>= base 0))]
    [params : ast.AstParamList (ast.ast-param-list-with-capacity param-count)]
    [index : i64 0]
    [start : i64 0]
    [maybe-ret : ast.AstMaybeType (ast.AstMaybeType.No)]
    (begin
      (while (and valid (< index param-count))
        (let
          [name-start : i64 (+ start 2)]
          [end : i64 name-start]
          [flags : i64
            (if (< start payload-len)
              (- (cast (string.string-ref payload start) : i64) 48)
              -1)]
          (begin
            (while (and
              (< end payload-len)
              (not (= (string.string-ref payload end) '\n')))
              (set! end (+ end 1)))
            (if (or
              (< flags 0)
              (> flags 1)
              (>= (+ start 1) payload-len)
              (not (= (string.string-ref payload (+ start 1)) ':'))
              (= end name-start)
              (>= end payload-len))
              (set! valid false)
              (match (compiler-comptime-host-array-element-shared-view
                compiler-comptime-host-stack
                (+ base index))
                [(ctfe_support.CompilerCtfeValue.Type ty)
                  (ast.ast-param-list-push
                    (&mut params)
                    (ast.AstParam.Param
                      (compiler-comptime-host-template-source-id
                        (ci.intern-source-slice
                          payload
                          name-start
                          (- end name-start)))
                      ty
                      (= flags 1)))]
                [_ (set! valid false)]))
            (set! start (+ end 1))
            (set! index (+ index 1)))))
      (when (not (= start payload-len)) (set! valid false))
      (when
        (and valid has-ret?)
        (match (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-stack
          (+ base param-count))
          [(ctfe_support.CompilerCtfeValue.Type ty)
            (set! maybe-ret (ast.AstMaybeType.Some ty))]
          [_ (set! valid false)]))
      (if (not valid)
        tlci.tlci-host-callback-status-bad-request
        (let
          [body-index : i64
            (+
              base
              param-count
              (if has-ret?
                1
                0))]
          [body-value : ctfe_support.CompilerCtfeValue
            (compiler-comptime-host-array-element-shared-view
              compiler-comptime-host-stack
              body-index)]
          [body-node : i64 (compiler-comptime-host-value-node body-value)]
          (if (< body-node 0)
            tlci.tlci-host-callback-status-bad-request
            (begin
              (set! compiler-comptime-host-stack-len base)
              (compiler-comptime-host-push-expr!
                (ast.ast-expr-lambda-with-pools
                  (compiler-comptime-host-session-pools)
                  params
                  maybe-ret
                  body-node)))))))))

(define (compiler-comptime-host-callback-expr-lambda
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0) (< arg-c 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [param-count : i64 (/ arg-c 2)]
        [has-ret? : bool (= (- arg-c (* param-count 2)) 1)]
        (compiler-comptime-host-lambda-push!
          param-count
          has-ret?
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b)))))))

;; expr-lambda1: pop a hygienic parameter name, its reflected type, and an
;; already assembled body, then push one inferred-result lambda expression.
(define (compiler-comptime-host-callback-expr-lambda1
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 3)
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 2)]
        [name-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 3)]
        [body-node : i64 (compiler-comptime-host-stack-node 1)]
        (match (compiler-comptime-host-value-name-id name-value)
          [(ctfe_support.CtfeMaybeNameId.Some name-id)
            (match type-value
              [(ctfe_support.CompilerCtfeValue.Type parameter-type)
                (if (< body-node 0)
                  tlci.tlci-host-callback-status-bad-request
                  (compiler-comptime-host-replace!
                    3
                    (ctfe_support.CompilerCtfeValue.Expr
                      (ctfe_support.ctfe-expr-lambda1-node
                        (compiler-comptime-host-session-pools)
                        name-id
                        parameter-type
                        body-node)
                      (ctfe_support.ctfe-untyped-expr-type))))]
              [_ tlci.tlci-host-callback-status-bad-request])]
          [(ctfe_support.CtfeMaybeNameId.None)
            tlci.tlci-host-callback-status-bad-request])))))

;; type-var: push the AstType.Var for caller bytes (unmarked, matching
;; the interpreted type quote for a plain name).
(define (compiler-comptime-host-callback-type-var
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0))
      tlci.tlci-host-callback-status-bad-request
      (let
        [name : String
          (unsafe
            (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
        (compiler-comptime-host-push!
          (ctfe_support.CompilerCtfeValue.Type
            (ast.AstType.Var
              (ci.intern-source-slice name 0 (string.string-length name)))))))))

;; Reconstruct one unresolved lifetime-parameterized nominal type. The payload
;; is `name\nlifetime...`, paired with the exact lifetime count in `arg-a`.
;; Names are interned from source slices so the resulting VarArgs carries the
;; same nominal and ordered lifetime identities as interpreted quasiquote.
;; Validate the complete payload before publishing a stack value. Refs #6551.
(define (compiler-comptime-host-type-var-args-push!
  [lifetime-count : i64]
  [payload : String]) : i64
  (let
    [payload-len : i64 (string.string-length payload)]
    [nominal-end : i64 0]
    [valid : bool
      (and
        (> lifetime-count 0)
        (> payload-len 0)
        (<= lifetime-count (/ (- payload-len 1) 2)))]
    (begin
      (while (and
        valid
        (< nominal-end payload-len)
        (not (= (string.string-ref payload nominal-end) '\n')))
        (set! nominal-end (+ nominal-end 1)))
      (when
        (or (= nominal-end 0) (>= nominal-end payload-len))
        (set! valid false))
      (let
        [lifetimes : ast.AstLifetimeList
          (ast.ast-lifetime-list-with-capacity lifetime-count)]
        [index : i64 0]
        [start : i64 (+ nominal-end 1)]
        (begin
          (while (and valid (< index lifetime-count))
            (let
              [end : i64 start]
              (begin
                (while (and
                  (< end payload-len)
                  (not (= (string.string-ref payload end) '\n')))
                  (set! end (+ end 1)))
                (if (= end start)
                  (set! valid false)
                  (begin
                    (ast.ast-lifetime-list-push
                      (&mut lifetimes)
                      (ci.intern-source-slice payload start (- end start)))
                    (if (= index (- lifetime-count 1))
                      (when (not (= end payload-len)) (set! valid false))
                      (if (>= end payload-len)
                        (set! valid false)
                        (set! start (+ end 1))))))
                (set! index (+ index 1)))))
          (if (not valid)
            tlci.tlci-host-callback-status-bad-request
            (compiler-comptime-host-push!
              (ctfe_support.CompilerCtfeValue.Type
                (ast.ast-ty-var-args
                  (ci.intern-source-slice payload 0 nominal-end)
                  lifetimes)))))))))

(define (compiler-comptime-host-callback-type-var-args
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (<= arg-b 0) (<= arg-c 0))
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-type-var-args-push!
        arg-a
        (unsafe
          (string-from-bytes (int->ptr arg-b : (Ptr u8)) arg-c))))))

;; type-scalar: push the scalar AstType variant for immediate `a`.
(define (compiler-comptime-host-callback-type-scalar
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push!
      (ctfe_support.CompilerCtfeValue.Type
        (compiler-comptime-host-scalar-type-for-ordinal arg-a)))))

;; array-element-type: pop an array type value and push the element type,
;; matching the interpreted reflection.
(define (compiler-comptime-host-callback-array-element-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
        (match (compiler-comptime-host-stack-value 1)
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Array elem _))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.DynArray elem))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Slice elem))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [_ tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-reference-element-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
        (match (compiler-comptime-host-stack-value 1)
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Ref _ elem))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.MutRef _ elem))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [_ tlci.tlci-host-callback-status-bad-request])))))

;; box-element-type: pop a box type and push its element type, preserving the
;; interpreted malformed-type diagnostic. Refs #6552.
(define (compiler-comptime-host-callback-box-element-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
        (match (compiler-comptime-host-stack-value 1)
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Box elem))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env elem)))]
          [_
            (compiler-comptime-host-diagnostic!
              "box-element-type requires box type")])))))

;; Function reflection used by the `for` protocol validator. Count is returned
;; as data; return-type replaces the function value on the session stack.
(define (compiler-comptime-host-callback-function-param-count
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      -3
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Func params _))
          (begin
            (compiler-comptime-host-drop! 1)
            (ctfe_support.ctfe-type-list-count (deref params)))]
        [_ -3]))))

(define (compiler-comptime-host-callback-function-return-type
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
        (match (compiler-comptime-host-stack-value 1)
          [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Func _ ret))
            (compiler-comptime-host-replace!
              1
              (ctfe_support.CompilerCtfeValue.Type
                (ctfe_support.ctfe-ty-get env ret)))]
          [_ tlci.tlci-host-callback-status-bad-request])))))

;; Cleanup ownership is a total boolean reflection query. The paired function
;; lookup is value-producing and retains the interpreted diagnostic on a
;; non-owning type.
(define (compiler-comptime-host-callback-type-cleanup-owning?
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      -3
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (let
            [owning : bool
              (match (let
                [host-pools : ast.AstNodePoolContext
                  (compiler-comptime-host-session-pools)]
                [host-reflections : ctfe_support.CtfeReflectInfoList
                  (compiler-comptime-host-session-reflections)]
                (ctfe_support.ctfe-reflect-info-for-type-with-pools
                  host-pools
                  host-reflections
                  ty))
                [(ctfe_support.CtfeMaybeReflectInfo.Some info)
                  (match info
                    [(ctfe_support.CtfeReflectInfo.Struct _ _ _ _ cleanup _ _)
                      (match cleanup
                        [(ctfe_support.CtfeReflectCleanup.No) false]
                        [(ctfe_support.CtfeReflectCleanup.Fn _ _) true])]
                    [(ctfe_support.CtfeReflectInfo.Enum _ _ _ _ cleanup _ _)
                      (match cleanup
                        [(ctfe_support.CtfeReflectCleanup.No) false]
                        [(ctfe_support.CtfeReflectCleanup.Fn _ _) true])])]
                [(ctfe_support.CtfeMaybeReflectInfo.None) false])]
            (begin
              (compiler-comptime-host-drop! 1)
              (if owning
                1
                0)))]
        [_ -3]))))

(define (compiler-comptime-host-callback-type-cleanup-function
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (match (let
            [host-pools : ast.AstNodePoolContext
              (compiler-comptime-host-session-pools)]
            [host-reflections : ctfe_support.CtfeReflectInfoList
              (compiler-comptime-host-session-reflections)]
            (ctfe_support.ctfe-reflect-info-for-type-with-pools
              host-pools
              host-reflections
              ty))
            [(ctfe_support.CtfeMaybeReflectInfo.Some info)
              (let
                [cleanup : ctfe_support.CtfeReflectCleanup
                  (match info
                    [(ctfe_support.CtfeReflectInfo.Struct _ _ _ _ value _ _)
                      value]
                    [(ctfe_support.CtfeReflectInfo.Enum _ _ _ _ value _ _)
                      value])]
                (match cleanup
                  [(ctfe_support.CtfeReflectCleanup.Fn
                      cleanup-name
                      cleanup-name-id)
                    (compiler-comptime-host-replace!
                      1
                      (ctfe_support.CompilerCtfeValue.String
                        cleanup-name
                        cleanup-name-id))]
                  [(ctfe_support.CtfeReflectCleanup.No)
                    (compiler-comptime-host-diagnostic!
                      "type-cleanup-function requires cleanup-owning type")]))]
            [(ctfe_support.CtfeMaybeReflectInfo.None)
              (compiler-comptime-host-diagnostic!
                "type-cleanup-function requires cleanup-owning type")])]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; array-length: the fixed element count of an array type as data; a
;; dynamic type or non-array reports the negative sentinel.
(define (compiler-comptime-host-callback-array-length
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      -3
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Array _ count))
          (begin
            (compiler-comptime-host-drop! 1)
            count)]
        [_ -3]))))

;; array-dynamic?: 1 for a dynamic array type, 0 for a fixed one, and the
;; negative sentinel otherwise.
(define (compiler-comptime-host-callback-array-dynamic?
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      -3
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.Array _ _))
          (begin
            (compiler-comptime-host-drop! 1)
            0)]
        [(ctfe_support.CompilerCtfeValue.Type (ast.AstType.DynArray _))
          (begin
            (compiler-comptime-host-drop! 1)
            1)]
        [_ -3]))))

;; expr-int-from-data: push an int literal node for the value in `a`.
;; Expression-shape probe and accessors for a computed body matching on
;; `(comptime.Expr.Call callee args)`. The probe answers as data and
;; bypasses the status latch; the accessors push exactly the two values
;; the interpreted pattern binds. Refs #5602.
(define (compiler-comptime-host-callback-operand-expr-call?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Call _ _) 1]
        [_ 0]))))

(define (compiler-comptime-host-callback-operand-expr-call-callee
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Call callee _)
          (compiler-comptime-host-push!
            (ctfe_support.CompilerCtfeValue.Expr
              callee
              (ctfe_support.ctfe-untyped-expr-type)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

(define (compiler-comptime-host-callback-operand-expr-call-args
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Call _ call-args)
          (compiler-comptime-host-push!
            (ctfe_support.CompilerCtfeValue.ExprList call-args))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; The `comptime.Expr.Int` half: a data probe plus a value read that the
;; generated entry only issues inside the probe's matching arm. Refs #5602.
;; expr-ptr-cast pops the type value then the pointer expression, the same
;; order expr-make-array uses. The shared helper also accepts captured type
;; syntax from an Expr-valued unquote. Refs #5605, #6215.
(define (compiler-comptime-host-callback-expr-ptr-cast
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-typed-pointer-node-step! 0)))

;; Composite type templates: pop the element/inner type and push the
;; wrapper. Refs #5605.
(define (compiler-comptime-host-callback-type-ptr
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 0 arg-a 0 0)))

(define (compiler-comptime-host-callback-type-box
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 1 0 0 0)))

(define (compiler-comptime-host-callback-type-dyn-array
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 2 0 0 0)))

(define (compiler-comptime-host-callback-type-array
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 3 arg-a 0 0)))

(define (compiler-comptime-host-callback-type-slice
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 5 0 0 0)))

(define (compiler-comptime-host-callback-type-ref
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-type-wrap-step! 4 arg-a arg-b _arg-c)))

;; type-tuple: consume `a` type values in source order and push their tuple
;; type. Validate the complete suffix before changing the session stack so a
;; malformed callback remains atomic.
(define (compiler-comptime-host-callback-type-tuple
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (let
      [valid : bool
        (and (>= arg-a 0) (<= arg-a compiler-comptime-host-stack-len))]
      [index : i64 0]
      [start : i64 (- compiler-comptime-host-stack-len arg-a)]
      (begin
        (while (and valid (< index arg-a))
          (begin
            (match (compiler-comptime-host-array-element-shared-view
              compiler-comptime-host-stack
              (+ start index))
              [(ctfe_support.CompilerCtfeValue.Type _) unit]
              [_ (set! valid false)])
            (set! index (+ index 1))))
        (let
          [result : i64
            (if (not valid)
              tlci.tlci-host-callback-status-bad-request
              (let
                [pools : ast.AstNodePoolContext
                  (compiler-comptime-host-session-pools)]
                [items : ast.AstTypeList
                  (ast.ast-type-list-with-capacity arg-a)]
                [item-index : i64 0]
                (begin
                  (while (< item-index arg-a)
                    (begin
                      (match (compiler-comptime-host-array-element-shared-view
                        compiler-comptime-host-stack
                        (+ start item-index))
                        [(ctfe_support.CompilerCtfeValue.Type ty)
                          (ast.ast-type-list-push
                            (&mut items)
                            (ast.ast-node-pool-context-type-push pools ty))]
                        [_ unit])
                      (set! item-index (+ item-index 1))))
                  (set! compiler-comptime-host-stack-len start)
                  (compiler-comptime-host-push!
                    (ctfe_support.CompilerCtfeValue.Type
                      (ast.AstType.Tuple (box items)))))))]
          (begin
            (when
              (not (= result tlci.tlci-host-callback-status-ok))
              (set! compiler-comptime-host-session-status result))
            result))))))

;; Literal text out of a string-literal Expr operand, mirroring
;; `ctfe-source-string-value`: the pushed value carries the intern id the
;; text entered CTFE with, not a fresh one. Refs #5626.
(define (compiler-comptime-host-callback-operand-expr-string-value
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
          (compiler-comptime-host-push!
            (ctfe_support.ctfe-source-string-value-for-source-names
              (compiler-comptime-host-session-source-names-value)
              string-id))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Pop a computed Expr and push its string-literal text, preserving the
;; source intern identity and interpreted diagnostic. Refs #6552.
(define (compiler-comptime-host-expr-string-value-step!
  [value : ctfe_support.CompilerCtfeValue]) : i64
  (let
    [node : i64 (compiler-comptime-host-value-node value)]
    [pools : ast.AstNodePoolContext (compiler-comptime-host-value-pools value)]
    (if (< node 0)
      (compiler-comptime-host-diagnostic!
        "expr-string-value expects a string literal Expr")
      (match (compiler-comptime-host-unspanned-expr
        pools
        (ast.ast-node-pool-context-expr-get pools node))
        [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
          (compiler-comptime-host-replace!
            1
            (ctfe_support.ctfe-source-string-value-for-source-names
              (compiler-comptime-host-session-source-names-value)
              string-id))]
        [_
          (compiler-comptime-host-diagnostic!
            "expr-string-value expects a string literal Expr")]))))

(define (compiler-comptime-host-callback-expr-string-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-expr-string-value-step!
        (compiler-comptime-host-stack-value 1)))))

;; The `comptime.expr-string?` guard, answering the same 1/0-as-data the
;; interpreted inspector answers for an Expr operand. Refs #5701.
(define (compiler-comptime-host-callback-operand-expr-string?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Literal (ast.AstLiteral.String _)) 1]
        [_ 0]))))

(define (compiler-comptime-host-callback-operand-expr-int?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Literal (ast.AstLiteral.Int _ _)) 1]
        [_ 0]))))

(define (compiler-comptime-host-callback-operand-expr-int-value
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      0
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Literal (ast.AstLiteral.Int value text))
          (ast.ast-int-literal-value-or-payload value text)]
        [_ 0]))))

;; Local-slot twins of the operand-only ExprList callbacks: a destructured
;; payload lives in a session local, and the fold bodies index it there.
;; Refs #5602.
(define (compiler-comptime-host-callback-local-expr-list-length
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      -3
      (let
        [value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-locals
            arg-a)]
        (match (compiler-comptime-host-value-expr-list value)
          [(CompilerCtfeMaybeExprList.Some items)
            (ctfe_support.ctfe-expr-list-length items)]
          [(CompilerCtfeMaybeExprList.None) -3])))))

(define (compiler-comptime-host-callback-local-expr-list-nth
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      tlci.tlci-host-callback-status-bad-request
      (let
        [value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-locals
            arg-a)]
        (match (compiler-comptime-host-value-expr-list value)
          [(CompilerCtfeMaybeExprList.Some items)
            (if (or
              (< arg-b 0)
              (>= arg-b (ctfe_support.ctfe-expr-list-length items)))
              tlci.tlci-host-callback-status-bad-request
              (let
                [node : i64 (ctfe_support.ctfe-expr-list-nth items arg-b)]
                (match value
                  [(ctfe_support.CompilerCtfeValue.CapturedExprList _ pools)
                    (compiler-comptime-host-push!
                      (ctfe_support.CompilerCtfeValue.CapturedExpr
                        node
                        (ctfe_support.ctfe-untyped-expr-type)
                        pools))]
                  [_
                    (compiler-comptime-host-push!
                      (ctfe_support.CompilerCtfeValue.Expr
                        node
                        (ctfe_support.ctfe-untyped-expr-type)))])))]
          [(CompilerCtfeMaybeExprList.None)
            tlci.tlci-host-callback-status-bad-request])))))

;; Local-slot twins of the operand Expr shape probes. They inspect the
;; let-bound Expr without consuming or duplicating its stack value and answer
;; 1/0 as data; malformed slots and non-Expr values use the shared negative
;; sentinel. Refs #5656.
(define (compiler-comptime-host-callback-local-expr-string?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some
          (ast.AstExpr.Literal (ast.AstLiteral.String _)))
        1]
      [(CompilerCtfeMaybeExpr.Some _) 0]
      [(CompilerCtfeMaybeExpr.None) -3])))

;; Local Expr.Int destructuring mirrors the operand callbacks while retaining
;; the computed expression in its session slot. The value accessor is a data
;; callback and is only issued after the shape probe succeeds. Refs #6644.
(define (compiler-comptime-host-callback-local-expr-int?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some
          (ast.AstExpr.Literal (ast.AstLiteral.Int _ _)))
        1]
      [(CompilerCtfeMaybeExpr.Some _) 0]
      [(CompilerCtfeMaybeExpr.None) -3])))

(define (compiler-comptime-host-callback-local-expr-int-value
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some
          (ast.AstExpr.Literal (ast.AstLiteral.Int value text)))
        (ast.ast-int-literal-value-or-payload value text)]
      [_ 0])))

(define (compiler-comptime-host-callback-local-expr-var?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some (ast.AstExpr.Var _)) 1]
      [(CompilerCtfeMaybeExpr.Some _) 0]
      [(CompilerCtfeMaybeExpr.None) -3])))

;; Destructure an Expr.Var stored in a session local without losing its
;; interned syntax identity. The result is the same Name value returned by the
;; operand-side accessor.
(define (compiler-comptime-host-callback-local-expr-var-name
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some (ast.AstExpr.Var name-id))
        (compiler-comptime-host-push!
          (ctfe_support.ctfe-name-value-for-source-names
            (compiler-comptime-host-session-source-names-value)
            name-id))]
      [_ tlci.tlci-host-callback-status-bad-request])))

(define (compiler-comptime-host-callback-local-expr-begin?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-expr arg-a)
      [(CompilerCtfeMaybeExpr.Some (ast.AstExpr.Begin _)) 1]
      [(CompilerCtfeMaybeExpr.Some _) 0]
      [(CompilerCtfeMaybeExpr.None) -3])))

;; Project the ExprList payload from a local Expr.Begin. Captured expressions
;; keep their originating pool context so the returned list's node ids remain
;; valid across the native expansion boundary.
(define (compiler-comptime-host-callback-local-expr-begin-items
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      tlci.tlci-host-callback-status-bad-request
      (let
        [value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-locals
            arg-a)]
        [node : i64 (compiler-comptime-host-value-node value)]
        [pools : ast.AstNodePoolContext
          (compiler-comptime-host-value-pools value)]
        (if (< node 0)
          tlci.tlci-host-callback-status-bad-request
          (match (compiler-comptime-host-unspanned-expr
            pools
            (ast.ast-node-pool-context-expr-get pools node))
            [(ast.AstExpr.Begin items)
              (match value
                [(ctfe_support.CompilerCtfeValue.CapturedExpr _ _ pools)
                  (compiler-comptime-host-push!
                    (ctfe_support.CompilerCtfeValue.CapturedExprList
                      items
                      pools))]
                [_
                  (compiler-comptime-host-push!
                    (ctfe_support.CompilerCtfeValue.ExprList items))])]
            [_ tlci.tlci-host-callback-status-bad-request]))))))

;; Read a Bool held in a session local as a data callback result. Like the
;; other local probes, malformed or wrong-typed slots use the negative
;; bad-request sentinel and leave the stored value untouched.
(define (compiler-comptime-host-callback-local-bool-value
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-locals-cap)
      (not
        (compiler-comptime-host-array-element-shared-view
          compiler-comptime-host-locals-live
          arg-a)))
      -3
      (match (compiler-comptime-host-array-element-shared-view
        compiler-comptime-host-locals
        arg-a)
        [(ctfe_support.CompilerCtfeValue.Bool value)
          (if value
            1
            0)]
        [_ -3]))))

;; Push a comptime Bool value selected by immediate `a`.
(define (compiler-comptime-host-callback-value-bool
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (> arg-a 1))
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-push!
        (ctfe_support.CompilerCtfeValue.Bool (= arg-a 1))))))

;; value-i64: push a comptime i64 from the immediate, so a literal or a
;; data-local index can feed int->string. Refs #5700.
(define (compiler-comptime-host-callback-value-i64
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push! (ctfe_support.CompilerCtfeValue.I64 arg-a))))

;; value-unit: push the interpreted comptime unit value. This is distinct from
;; expr-unit-literal, which constructs syntax rather than the value produced by
;; evaluating a source-level `unit`. Refs #5606.
(define (compiler-comptime-host-callback-value-unit
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push! (ctfe_support.CompilerCtfeValue.Unit))))

;; Both values are already on the stack (then below else); keep exactly the
;; selected value. The producer restricts this eager form to local/operand Vars.
(define (compiler-comptime-host-callback-value-select
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [selected : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-array-element-shared-view
            compiler-comptime-host-stack
            (if (= arg-a 0)
              (- compiler-comptime-host-stack-len 1)
              (- compiler-comptime-host-stack-len 2)))]
        (compiler-comptime-host-replace! 2 selected)))))

;; int->string: pop a comptime i64 and push its decimal spelling as a
;; comptime String, mirroring the interpreted `comptime.int->string`
;; builtin. Refs #5700.
(define (compiler-comptime-host-callback-int->string
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.I64 value)
          (compiler-comptime-host-replace!
            1
            (ctfe_support.ctfe-generated-string-value
              (string.int->string value)))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; `comptime.Expr.Var` destructuring (refs #5700, #5771). The probe answers as
;; data like the other operand shape probes; the accessor must preserve the
;; interpreted Name variant and original structural id. String consumers
;; accept both Name and String values through ctfe-value-named.
(define (compiler-comptime-host-callback-operand-expr-var?
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      -3
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Var _) 1]
        [_ 0]))))

(define (compiler-comptime-host-callback-operand-expr-var-name
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-operand-expr arg-a)
        [(ast.AstExpr.Var name-id)
          (compiler-comptime-host-push!
            (ctfe_support.ctfe-name-value-for-source-names
              (compiler-comptime-host-session-source-names-value)
              name-id))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Comptime string scanning over a String session local (refs #5701). The
;; two data probes mirror `ctfe-eval-string-length-call` and
;; `ctfe-eval-string-ref-call`: length is total, and an out-of-bounds index
;; is the interpreted diagnostic's native counterpart, a malformed request
;; rather than a silently clamped byte.
(define (compiler-comptime-host-callback-local-string-length
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-string arg-a)
      [(ctfe_support.CtfeMaybeNamed.Some text _) (string.string-length text)]
      [(ctfe_support.CtfeMaybeNamed.None) -3])))

(define (compiler-comptime-host-callback-local-string-ref
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (match (compiler-comptime-host-local-string arg-a)
      [(ctfe_support.CtfeMaybeNamed.Some text _)
        (if (or (< arg-b 0) (>= arg-b (string.string-length text)))
          -3
          (cast (string.string-ref text arg-b) : i64))]
      [(ctfe_support.CtfeMaybeNamed.None) -3])))

;; The `[b, b+c)` byte range as the generated comptime String value
;; `ctfe-eval-comptime-string-slice-call` yields, with the same bounds
;; contract.
(define (compiler-comptime-host-callback-local-string-slice
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (match (compiler-comptime-host-local-string arg-a)
      [(ctfe_support.CtfeMaybeNamed.Some text _)
        (if (or
          (< arg-b 0)
          (< _arg-c 0)
          (> (+ arg-b _arg-c) (string.string-length text)))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-push!
            (ctfe_support.ctfe-generated-string-value
              (string.substring text arg-b _arg-c))))]
      [(ctfe_support.CtfeMaybeNamed.None)
        tlci.tlci-host-callback-status-bad-request])))

;; expr-string-from-value: pop a comptime String and push the string
;; literal expression `ctfe-eval-expr-string-call` builds -- the popped
;; value's own intern id and the `String` expression type, so a template
;; embeds exactly the literal interpretation would.
(define (compiler-comptime-host-callback-expr-string-from-value
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-data-callback
    session
    (let
      [env : ctfe_support.CtfeEnv (compiler-comptime-host-ctfe-env)]
      [result : i64
        (if (< compiler-comptime-host-stack-len 1)
          tlci.tlci-host-callback-status-bad-request
          (match (compiler-comptime-host-stack-value 1)
            [(ctfe_support.CompilerCtfeValue.String _ string-id)
              (compiler-comptime-host-replace!
                1
                (ctfe_support.ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Literal (ast.AstLiteral.String string-id))
                  (ast.AstType.String)))]
            [(ctfe_support.CompilerCtfeValue.Name _ name-id)
              (compiler-comptime-host-replace!
                1
                (ctfe_support.ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Literal (ast.AstLiteral.String name-id))
                  (ast.AstType.String)))]
            [_ tlci.tlci-host-callback-status-bad-request]))]
      (begin
        (when
          (not (= result tlci.tlci-host-callback-status-ok))
          (set! compiler-comptime-host-session-status result))
        result))))

(define (compiler-comptime-host-callback-expr-int-from-data
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-push-expr!
      (ast.ast-node-pool-context-expr-push
        (compiler-comptime-host-session-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int arg-a))))))

;; Dense public builders used by `for`: consume computed syntax values and
;; reconstruct the same single-scope AST nodes as interpreted CTFE.
(define (compiler-comptime-host-callback-expr-resource-scope
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 4)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-value-name-id
        (compiler-comptime-host-stack-value 4))
        [(ctfe_support.CtfeMaybeNameId.Some name-id)
          (let
            [init-node : i64 (compiler-comptime-host-stack-node 3)]
            [cleanup-node : i64 (compiler-comptime-host-stack-node 2)]
            [body-node : i64 (compiler-comptime-host-stack-node 1)]
            (if (or (< init-node 0) (< cleanup-node 0) (< body-node 0))
              tlci.tlci-host-callback-status-bad-request
              (compiler-comptime-host-replace-expr!
                4
                (ast.ast-node-pool-context-expr-push
                  (compiler-comptime-host-session-pools)
                  (ctfe_support.ctfe-with-resource-expr
                    name-id
                    init-node
                    cleanup-node
                    body-node
                    (= arg-a 1))))))]
        [(ctfe_support.CtfeMaybeNameId.None)
          tlci.tlci-host-callback-status-bad-request]))))

;; expr-let-scope (`shared?` false) and expr-shared-let-scope over the name,
;; init, and body stack values.
(define (compiler-comptime-host-let-scope! [shared? : bool]) : i64
  (if (< compiler-comptime-host-stack-len 3)
    tlci.tlci-host-callback-status-bad-request
    (let
      [name-value : ctfe_support.CompilerCtfeValue
        (compiler-comptime-host-stack-value 3)]
      [body-node : i64 (compiler-comptime-host-stack-node 1)]
      [init-node : i64 (compiler-comptime-host-stack-node 2)]
      (match (compiler-comptime-host-value-name-id name-value)
        [(ctfe_support.CtfeMaybeNameId.Some name-id)
          (if (or (< init-node 0) (< body-node 0))
            tlci.tlci-host-callback-status-bad-request
            (compiler-comptime-host-replace-expr!
              3
              (if shared?
                (ctfe_support.ctfe-expr-shared-let-scope-node
                  (compiler-comptime-host-session-pools)
                  name-id
                  init-node
                  body-node)
                (ctfe_support.ctfe-expr-let-scope-node
                  (compiler-comptime-host-session-pools)
                  name-id
                  init-node
                  body-node))))]
        [(ctfe_support.CtfeMaybeNameId.None)
          tlci.tlci-host-callback-status-bad-request]))))

(define (compiler-comptime-host-callback-expr-let-scope
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-let-scope! false)))

(define (compiler-comptime-host-callback-expr-shared-let-scope
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (compiler-comptime-host-let-scope! true)))

;; The expression nodes of the top `count` stack values, first-pushed first,
;; or None when any of them carries no expression.
(define (compiler-comptime-host-stack-nodes [count : i64]) : CompilerCtfeMaybeExprList
  (let
    [nodes : ast.AstExprList (ast.ast-expr-list-with-capacity count)]
    [depth : i64 count]
    [valid? : bool true]
    (begin
      (while (> depth 0)
        (let
          [node : i64 (compiler-comptime-host-stack-node depth)]
          (begin
            (when (< node 0) (set! valid? false))
            (ast.ast-expr-list-push (&mut nodes) node)
            (set! depth (- depth 1)))))
      (if valid?
        (CompilerCtfeMaybeExprList.Some nodes)
        (CompilerCtfeMaybeExprList.None)))))

(define (compiler-comptime-host-callback-expr-for-owned
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (let
      [count : i64 (ctfe_support.ctfe-expr-for-owned-arity arg-a)]
      (if (or (< count 0) (< compiler-comptime-host-stack-len count))
        tlci.tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-stack-nodes count)
          [(CompilerCtfeMaybeExprList.Some nodes)
            (compiler-comptime-host-replace-expr!
              count
              (ctfe_support.ctfe-expr-for-owned-node
                (compiler-comptime-host-session-pools)
                arg-a
                nodes))]
          [(CompilerCtfeMaybeExprList.None)
            tlci.tlci-host-callback-status-bad-request])))))

(define (compiler-comptime-host-callback-expr-not
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [node : i64 (compiler-comptime-host-stack-node 1)]
        (if (< node 0)
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            1
            (ast.ast-expr-unary-with-pools
              (compiler-comptime-host-session-pools)
              (ast.AstUnOp.Not)
              node)))))))

(define (compiler-comptime-host-build-expr-set-var!
  [name-id : i64]
  [value-value : ctfe_support.CompilerCtfeValue]
  [pop-count : i64]) : i64
  (let
    [value-node : i64 (compiler-comptime-host-value-node value-value)]
    (if (< value-node 0)
      tlci.tlci-host-callback-status-bad-request
      (compiler-comptime-host-replace-expr!
        pop-count
        (ast.ast-expr-set-id-with-pools
          (compiler-comptime-host-session-pools)
          name-id
          value-node)))))

;; Immediate names serve quasiquote construction; zero immediates select the
;; public builder form with a computed String/Name below the value expression.
(define (compiler-comptime-host-callback-expr-set-var
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (let
        [value-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        (if (and (> arg-a 0) (>= arg-b 0))
          (compiler-comptime-host-build-expr-set-var!
            (compiler-comptime-host-template-source-id
              (ci.intern-source-slice
                (unsafe
                  (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                0
                arg-b))
            value-value
            1)
          (if (< compiler-comptime-host-stack-len 2)
            tlci.tlci-host-callback-status-bad-request
            (match (compiler-comptime-host-value-name-id
              (compiler-comptime-host-stack-value 2))
              [(ctfe_support.CtfeMaybeNameId.Some name-id)
                (compiler-comptime-host-build-expr-set-var!
                  name-id
                  value-value
                  2)]
              [(ctfe_support.CtfeMaybeNameId.None)
                tlci.tlci-host-callback-status-bad-request])))))))

;; expr-while: pop the body then the condition expression and push the
;; while node the parser produces.
(define (compiler-comptime-host-callback-expr-while
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 2)
      tlci.tlci-host-callback-status-bad-request
      (let
        [body-node : i64 (compiler-comptime-host-stack-node 1)]
        [cond-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< body-node 0) (< cond-node 0))
          tlci.tlci-host-callback-status-bad-request
          (compiler-comptime-host-replace-expr!
            2
            (ast.ast-expr-while-with-pools
              (compiler-comptime-host-session-pools)
              cond-node
              body-node)))))))

;; let-binding-typed: pop the type value/syntax then the init expression and
;; push a binding for the name in `a`/`b` (template-source marked) with
;; that type annotation. The producer emits the init template first and
;; the type second, so the type is the topmost stack value. Interpreted type
;; unquote accepts both a Type and an Expr containing type syntax; reuse its
;; conversion so let-bound `(expr-var "Vec")` names behave identically.
(define (compiler-comptime-host-callback-let-binding-typed
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 2))
      tlci.tlci-host-callback-status-bad-request
      (let
        [type-value : ctfe_support.CompilerCtfeValue
          (compiler-comptime-host-stack-value 1)]
        [init-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (< init-node 0)
          tlci.tlci-host-callback-status-bad-request
          (let
            [env : ctfe_support.CtfeEnv
              (ctfe_support.ctfe-env-empty-with-pools
                (compiler-comptime-host-session-pools))]
            (match (ctfe_support.ctfe-pattern-binding-type-value
              type-value
              (ast.AstExpr.Literal (ast.AstLiteral.Unit))
              env
              compiler-comptime-host-session-fuel)
              [(ctfe_support.ResultCtfeQuoteType.Ok ty next-fuel)
                (begin
                  (set! compiler-comptime-host-session-fuel next-fuel)
                  (compiler-comptime-host-replace!
                    2
                    (ctfe_support.CompilerCtfeValue.LetBinding
                      (ast.ast-let-binding-id
                        (compiler-comptime-host-template-source-id
                          (ci.intern-source-slice
                            (unsafe
                              (string-from-bytes
                                (int->ptr arg-a : (Ptr u8))
                                arg-b))
                            0
                            arg-b))
                        (ast.AstMaybeType.Some ty)
                        init-node))))]
              [(ctfe_support.ResultCtfeQuoteType.Err diag)
                (begin
                  (set!
                    (array-ref compiler-comptime-host-diagnostic 0)
                    (__tl-project-field (__tl-box-place diag) message))
                  tlci.tlci-host-callback-status-diagnostic)])))))))

;; type-kind: pop a type value and push its kind string, the same mapping
;; the interpreted reflection uses.
(define (compiler-comptime-host-callback-type-kind
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (< compiler-comptime-host-stack-len 1)
      tlci.tlci-host-callback-status-bad-request
      (match (compiler-comptime-host-stack-value 1)
        [(ctfe_support.CompilerCtfeValue.Type ty)
          (compiler-comptime-host-replace!
            1
            (ctfe_support.ctfe-generated-string-value
              (let
                [host-pools : ast.AstNodePoolContext
                  (compiler-comptime-host-session-pools)]
                [host-reflections : ctfe_support.CtfeReflectInfoList
                  (compiler-comptime-host-session-reflections)]
                (ctfe_support.ctfe-type-kind-with-reflections-and-pools
                  host-pools
                  host-reflections
                  ty))))]
        [_ tlci.tlci-host-callback-status-bad-request]))))

;; Replace a fold's two terminal operands by the folded chain. Like the
;; interpreted fold of captured syntax, a chain whose terminals are both
;; hygiene-inert literals is published as the exact hygiene-free root.
(define (compiler-comptime-host-fold-push!
  [pools : ast.AstNodePoolContext]
  [operand-value : ctfe_support.CompilerCtfeValue]
  [first-terminal : i64]
  [second-terminal : i64]
  [out-node : i64]) : i64
  (begin
    (compiler-comptime-host-drop! 2)
    (if (and
      (ctfe_support.ctfe-hygiene-inert-literal-node? pools first-terminal)
      (ctfe_support.ctfe-hygiene-inert-literal-node? pools second-terminal))
      (ctfe_support.ctfe-result-hygiene-free-note-for-state!
        (compiler-comptime-host-session-macro-state-value)
        out-node)
      unit)
    (compiler-comptime-host-push!
      (compiler-comptime-host-expr-value-for-owner operand-value out-node))))

(define (compiler-comptime-host-callback-expr-list-fold-if
  [session : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< compiler-comptime-host-stack-len 2)
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (let
        [when-false-node : i64 (compiler-comptime-host-stack-node 1)]
        [when-true-node : i64 (compiler-comptime-host-stack-node 2)]
        [continue-on-true : bool (not (= arg-b 0))]
        (if (or (< when-false-node 0) (< when-true-node 0))
          tlci.tlci-host-callback-status-bad-request
          (let
            [operand-value : ctfe_support.CompilerCtfeValue
              (compiler-comptime-host-array-element-shared-view
                compiler-comptime-host-operands
                arg-a)]
            (match (compiler-comptime-host-value-expr-list operand-value)
              [(CompilerCtfeMaybeExprList.Some items)
                (let
                  [pools : ast.AstNodePoolContext
                    (compiler-comptime-host-value-pools operand-value)]
                  [out-node : i64
                    (__tl-project-field
                      (ctfe_support.ctfe-expr-list-fold-if-node
                        pools
                        items
                        when-true-node
                        when-false-node
                        continue-on-true
                        (ctfe_support.ctfe-expr-list-length items))
                      node)]
                  (compiler-comptime-host-fold-push!
                    pools
                    operand-value
                    when-true-node
                    when-false-node
                    out-node))]
              [(CompilerCtfeMaybeExprList.None)
                tlci.tlci-host-callback-status-bad-request])))))))

(define (compiler-comptime-host-callback-expr-clause-list-fold-if
  [session : i64]
  [arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      (< compiler-comptime-host-stack-len 2)
      (< arg-a 0)
      (>= arg-a compiler-comptime-host-operand-count))
      tlci.tlci-host-callback-status-bad-request
      (let
        [else-not-final-node : i64 (compiler-comptime-host-stack-node 1)]
        [missing-node : i64 (compiler-comptime-host-stack-node 2)]
        (if (or (< else-not-final-node 0) (< missing-node 0))
          tlci.tlci-host-callback-status-bad-request
          (let
            [operand-value : ctfe_support.CompilerCtfeValue
              (compiler-comptime-host-array-element-shared-view
                compiler-comptime-host-operands
                arg-a)]
            (match (compiler-comptime-host-value-expr-clause-list operand-value)
              [(CompilerCtfeMaybeExprClauseList.Some items)
                (let
                  [pools : ast.AstNodePoolContext
                    (compiler-comptime-host-value-pools operand-value)]
                  [out-node : i64
                    (__tl-project-field
                      (ctfe_support.ctfe-expr-clause-list-fold-if-node
                        pools
                        items
                        missing-node
                        else-not-final-node
                        (ctfe_support.ctfe-expr-clause-list-length items))
                      node)]
                  (compiler-comptime-host-fold-push!
                    pools
                    operand-value
                    missing-node
                    else-not-final-node
                    out-node))]
              [(CompilerCtfeMaybeExprClauseList.None)
                tlci.tlci-host-callback-status-bad-request])))))))

(define (compiler-comptime-host-callback-commit-result
  [session : i64]
  [_arg-a : i64]
  [_arg-b : i64]
  [_arg-c : i64]) : i64
  (compiler-comptime-host-status-callback
    session
    (if (or
      compiler-comptime-host-result-ready
      (< compiler-comptime-host-stack-len 1))
      tlci.tlci-host-callback-status-bad-request
      (begin
        (set!
          (array-ref compiler-comptime-host-result 0)
          (compiler-comptime-host-stack-value 1))
        (compiler-comptime-host-drop! 1)
        (set! compiler-comptime-host-result-ready true)
        tlci.tlci-host-callback-status-ok))))

;; Extract the raw code pointer from a top-level TypeLisp function value.
;; Generated image calls provide the host context in the hidden-environment
;; register, so no per-callback trampoline is needed.
(define (compiler-comptime-host-function-address
  [callback : (-> i64 i64 i64 i64 i64)]) : i64
  (let
    [descriptor : i64
      (cast
        (unsafe
          (cast callback : u64))
        : i64)]
    (unsafe
      (ptr-read (int->ptr descriptor : (Ptr i64))))))

(define (compiler-comptime-host-abort-function-address
  [callback : (-> i64 i64 i64 i64 i64 i64)]) : i64
  (let
    [descriptor : i64
      (cast
        (unsafe
          (cast callback : u64))
        : i64)]
    (unsafe
      (ptr-read (int->ptr descriptor : (Ptr i64))))))

;; Registry rows append in source order; their storage index is an
;; implementation detail and never enters the image ABI. Spare capacity keeps
;; ordinary callback additions numeric-free; array bounds fail closed if this
;; internal implementation limit is ever reached.
(defstruct CompilerComptimeHostRegistryBuilder
  (names (__tl_dyn-array String))
  (callbacks (__tl_dyn-array i64))
  (len i64))

(define (compiler-comptime-host-registry-new) : CompilerComptimeHostRegistryBuilder
  (CompilerComptimeHostRegistryBuilder
    (__tl_make-array String 256)
    (__tl_make-array i64 256)
    0))

(define (compiler-comptime-host-registry-add!
  [registry : (&mut registry CompilerComptimeHostRegistryBuilder)]
  [name : String]
  [callback : (-> i64 i64 i64 i64 i64)]) : unit
  (let
    [index : i64 registry.len]
    (begin
      (set! (array-ref registry.names index) name)
      (set!
        (array-ref registry.callbacks index)
        (compiler-comptime-host-function-address callback))
      (set! registry.len (+ index 1)))))

;; One `compiler-comptime-host-registry-add!` per host callback table row,
;; binding the row's ABI name to its `compiler-comptime-host-callback-<name>`
;; implementation.
(defmacro (compiler-comptime-host-registry-rows
  [registry : Expr]
  [rows : Expr ...]) : unit
  (let
    [prefix-length : i64
      (string.string-length "compiler-comptime-host-callback-")]
    [index : i64 (expr-list-length rows)]
    [adds : ExprList (expr-list-empty)]
    (begin
      (while (> index 0)
        (begin
          (set! index (- index 1))
          (match (expr-list-nth rows index)
            [(comptime.Expr.Var row)
              (set!
                adds
                (expr-list-cons
                  `(compiler-comptime-host-registry-add!
                    (&mut ,registry)
                    ,(comptime.expr-string
                      (comptime.string-slice
                        row
                        prefix-length
                        (- (string.string-length row) prefix-length)))
                    ,(comptime.expr-var row))
                  adds))]
            [_
              (comptime-error
                "compiler-comptime-host-registry-rows: rows must be bare names")])))
      `(begin
        ,@adds))))

;; Static name-to-address registry used by the built-in image linker, one row
;; per `tlci.tlci-host-callback-table` entry. Registry validation rejects
;; empty/duplicate names and null callbacks before mapping.
(define (compiler-comptime-host-table) : tlci.TlciHostCallbackTable
  (let
    [registry : CompilerComptimeHostRegistryBuilder
      (compiler-comptime-host-registry-new)]
    (begin
      (tlci.tlci-host-callback-table
        compiler-comptime-host-registry-rows
        registry)
      (tlci.TlciHostCallbackTable
        tlci.tlci-host-callback-table-magic
        tlci.tlci-host-abi-version
        tlci.tlci-host-callback-table-size
        0
        0
        0
        0
        (compiler-comptime-host-abort-function-address
          compiler-comptime-host-callback-abort)
        registry.names
        registry.callbacks
        registry.len))))