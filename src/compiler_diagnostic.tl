;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.arena)
(import token)
(import compiler_ast_types as ast)
(import stdlib.string)
(import stdlib.text_buf)
(import compiler_owned_view as owned_view)

(defmacro (compiler-diagnostic-place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defenum CompilerDiagnosticLevel
  (CompilerDiagnosticError)
  (CompilerDiagnosticWarning)
  (CompilerDiagnosticNote))

(defenum CompilerDiagnosticMaybeString
  (CompilerDiagnosticNoString)
  (CompilerDiagnosticSomeString String))

(defstruct CompilerDiagnosticSpan
  (path String)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct CompilerDiagnosticLabel
  (span CompilerDiagnosticSpan)
  (label CompilerDiagnosticMaybeString))

(defstruct CompilerDiagnosticLabelList
  (slots (__tl_dyn-array CompilerDiagnosticLabel))
  (len i64))

(defstruct CompilerDiagnosticNoteList
  (slots (__tl_dyn-array String))
  (len i64))

(defenum CompilerDiagnosticApplicability
  (CompilerDiagnosticMachineApplicable)
  (CompilerDiagnosticMaybeIncorrect)
  (CompilerDiagnosticHasPlaceholders)
  (CompilerDiagnosticUnspecified))

(defstruct CompilerDiagnosticTextEdit
  ;; An empty path inherits the diagnostic's primary path. Source positions are
  ;; 1-based UTF-8 byte line/columns, matching lexer and LSP coordinates.
  (span CompilerDiagnosticSpan)
  (replacement String))

(defstruct CompilerDiagnosticTextEditSeq
  (slots (__tl_dyn-array CompilerDiagnosticTextEdit))
  (len i64))

(defstruct CompilerDiagnosticFix
  (title String)
  (applicability CompilerDiagnosticApplicability)
  (edits CompilerDiagnosticTextEditSeq))

(defstruct CompilerDiagnosticFixSeq
  (slots (__tl_dyn-array CompilerDiagnosticFix))
  (len i64))

(defstruct CompilerDiagnostic
  (message String)
  (level CompilerDiagnosticLevel)
  (code CompilerDiagnosticMaybeString)
  (category CompilerDiagnosticMaybeString)
  (primary CompilerDiagnosticSpan)
  (help CompilerDiagnosticMaybeString)
  (secondary CompilerDiagnosticLabelList)
  (notes CompilerDiagnosticNoteList)
  (fixes CompilerDiagnosticFixSeq))

(define (compiler-diagnostic-box-shared-view [value : (Box CompilerDiagnostic)]) : CompilerDiagnostic
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr CompilerDiagnostic))))))

(defstruct CompilerDiagnosticList
  (slots (__tl_dyn-array CompilerDiagnostic))
  (len i64))

;; Successful compiler work may discover diagnostics that do not invalidate
;; its artifact. Keep those values separate from fatal result payloads and tag
;; their producing phase so transport tests and later policy layers never have
;; to infer provenance from message text.
(defenum CompilerAdvisoryPhase
  (Semantic)
  (Lowering)
  (Optimization)
  (RegisterAllocation)
  (Backend))

(defstruct CompilerAdvisory
  (phase CompilerAdvisoryPhase)
  (diagnostic CompilerDiagnostic))

(defstruct CompilerAdvisoryList
  (slots (__tl_dyn-array CompilerAdvisory))
  (len i64))

;; The stable cell lives with its compiler job. Advisory payloads live in a
;; separate, lazily created arena: producers may append while frontend/lower
;; scratch arenas are current, and a job reset can release every retained
;; string/span in one operation without growing the driver's lifetime arena.
(defstruct CompilerAdvisorySinkData
  (payload-arena i64)
  (advisories CompilerAdvisoryList)
  (generation i64))

(defstruct CompilerAdvisorySink
  (address i64))

(define (compiler-advisory-list-with-capacity [capacity : i64]) : CompilerAdvisoryList
  (CompilerAdvisoryList (__tl_make-array CompilerAdvisory capacity) 0))

(define (compiler-advisory-list-empty) : CompilerAdvisoryList
  (compiler-advisory-list-with-capacity 0))

(define (compiler-advisory-list-count
  [advisories : (& advisories CompilerAdvisoryList)]) : i64
  advisories.len)

(define (compiler-advisory-list-get
  [advisories : (& advisories CompilerAdvisoryList)]
  [index : i64]) : CompilerAdvisory
  (compiler-advisory-copy-ref (& (array-ref advisories.slots index))))

(define (compiler-advisory-phase [advisory : (& advisory CompilerAdvisory)]) : CompilerAdvisoryPhase
  (match advisory.phase
    [(Semantic) (Semantic)]
    [(Lowering) (Lowering)]
    [(Optimization) (Optimization)]
    [(RegisterAllocation) (RegisterAllocation)]
    [(Backend) (Backend)]))

(define (compiler-advisory-diagnostic
  [advisory : (& advisory CompilerAdvisory)]) : CompilerDiagnostic
  (compiler-diagnostic-copy-ref (& advisory.diagnostic)))

(define (compiler-advisory-copy-ref [advisory : (& advisory CompilerAdvisory)]) : CompilerAdvisory
  (CompilerAdvisory
    (compiler-advisory-phase advisory)
    (compiler-diagnostic-copy-ref (& advisory.diagnostic))))

(define (compiler-advisory-sink-new) : CompilerAdvisorySink
  (let
    [cell : (__tl_dyn-array CompilerAdvisorySinkData)
      (__tl_make-array CompilerAdvisorySinkData 1)]
    (set!
      (array-ref cell 0)
      (CompilerAdvisorySinkData 0 (compiler-advisory-list-empty) 0))
    (CompilerAdvisorySink
      (cast
        (unsafe
          (ptr->int
            (ptr-cast (__tl_array-data cell) : (Ptr CompilerAdvisorySinkData))))
        : i64))))

(define (compiler-advisory-sink-view [sink : CompilerAdvisorySink]) : (Ptr
    CompilerAdvisorySinkData)
  (unsafe
    (int->ptr (cast sink.address : u64) : (Ptr CompilerAdvisorySinkData))))

(define (compiler-advisory-sink-data-set!
  [sink : CompilerAdvisorySink]
  [data : CompilerAdvisorySinkData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr (cast sink.address : u64) : (MutPtr CompilerAdvisorySinkData))
      data)))

(define (compiler-advisory-sink-snapshot [sink : CompilerAdvisorySink]) : CompilerAdvisoryList
  (unsafe
    (deref (compiler-advisory-sink-view sink)).advisories))

(define (compiler-advisory-sink-reset! [sink : CompilerAdvisorySink]) : unit
  (let
    [data : (Ptr CompilerAdvisorySinkData) (compiler-advisory-sink-view sink)]
    (unsafe
      (if (= (deref data).payload-arena 0)
        unit
        (arena.tl_arena_destroy (deref data).payload-arena))
      (compiler-advisory-sink-data-set!
        sink
        (CompilerAdvisorySinkData
          0
          (compiler-advisory-list-empty)
          (+ (deref data).generation 1))))))

(define (compiler-diagnostic-list-box-shared-view
  [value : (Box CompilerDiagnosticList)]) : CompilerDiagnosticList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr CompilerDiagnosticList))))))

(define (compiler-diagnostic-list-with-capacity [capacity : i64]) : CompilerDiagnosticList
  (CompilerDiagnosticList (__tl_make-array CompilerDiagnostic capacity) 0))

(define (compiler-diagnostic-list-empty) : CompilerDiagnosticList
  (compiler-diagnostic-list-with-capacity 0))

(define (compiler-diagnostic-list-single [diag : CompilerDiagnostic]) : CompilerDiagnosticList
  (let
    [diagnostics : CompilerDiagnosticList
      (compiler-diagnostic-list-with-capacity 1)]
    (set! (array-ref diagnostics.slots 0) diag)
    (set! diagnostics.len 1)
    diagnostics))

(define (compiler-diagnostic-list-box-single [diag : (Box CompilerDiagnostic)]) : (Box
    CompilerDiagnosticList)
  (box (compiler-diagnostic-list-single (deref diag))))

(define (compiler-diagnostic-list-count
  [diagnostics : (& diagnostics CompilerDiagnosticList)]) : i64
  diagnostics.len)

(define (compiler-diagnostic-list-get
  [diagnostics : (& diagnostics CompilerDiagnosticList)]
  [index : i64]) : CompilerDiagnostic
  (let
    [diagnostics : CompilerDiagnosticList
      (owned_view.compiler-owned-reference-shared-view diagnostics)]
    (array-ref diagnostics.slots index)))

(define (compiler-diagnostic-list-ref
  [diagnostics : (& diagnostics CompilerDiagnosticList)]
  [index : i64]) : (& diagnostics CompilerDiagnostic)
  (& (array-ref diagnostics.slots index)))

(define (compiler-diagnostic-list-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerDiagnostic))]
  [src : (& src (__tl_dyn-array CompilerDiagnostic))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (set! (array-ref dst index) (array-ref src index))
      (set! index (+ index 1)))))

(define (compiler-diagnostic-list-grow!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]) : unit
  (let
    [count : i64 diagnostics.len]
    [old-capacity : i64 (array-length diagnostics.slots)]
    [new-capacity : i64
      (if (< old-capacity 1)
        4
        (* old-capacity 2))]
    [new-slots : (__tl_dyn-array CompilerDiagnostic)
      (__tl_make-array CompilerDiagnostic new-capacity)]
    (compiler-diagnostic-list-copy-range!
      (&mut new-slots)
      (& diagnostics.slots)
      count)
    (set! diagnostics.slots new-slots)))

(define (compiler-diagnostic-list-push!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [diag : CompilerDiagnostic]) : unit
  (if (< diagnostics.len (array-length diagnostics.slots))
    unit
    (compiler-diagnostic-list-grow! diagnostics))
  (let
    [index : i64 diagnostics.len]
    (set! (array-ref diagnostics.slots index) diag)
    (set! diagnostics.len (+ index 1))))

(define (compiler-diagnostic-list-insert!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [index : i64]
  [diag : CompilerDiagnostic]) : unit
  (let
    [count : i64 diagnostics.len]
    (if (< count (array-length diagnostics.slots))
      unit
      (compiler-diagnostic-list-grow! diagnostics))
    (let
      [cursor : i64 count]
      (while (> cursor index)
        (set!
          (array-ref diagnostics.slots cursor)
          (array-ref diagnostics.slots (- cursor 1)))
        (set! cursor (- cursor 1)))
      (set! (array-ref diagnostics.slots index) diag)
      (set! diagnostics.len (+ count 1)))))

(define (compiler-diagnostic-list-first
  [diagnostics : (& diagnostics CompilerDiagnosticList)]) : CompilerDiagnostic
  (if (> diagnostics.len 0)
    (compiler-diagnostic-copy-ref (& (array-ref diagnostics.slots 0)))
    (compiler-diagnostic-at-start "" "compiler: internal empty diagnostic list")))

(define (compiler-diagnostic-span-path [span : (& span CompilerDiagnosticSpan)]) : String
  (string.copy (& span.path)))

(define (compiler-diagnostic-span-start-line
  [span : (& span CompilerDiagnosticSpan)]) : i64
  span.start-line)

(define (compiler-diagnostic-span-start-col
  [span : (& span CompilerDiagnosticSpan)]) : i64
  span.start-col)

(define (compiler-diagnostic-span-end-line
  [span : (& span CompilerDiagnosticSpan)]) : i64
  span.end-line)

(define (compiler-diagnostic-span-end-col
  [span : (& span CompilerDiagnosticSpan)]) : i64
  span.end-col)

(define (compiler-diagnostic-path [diag : (& diag CompilerDiagnostic)]) : String
  (compiler-diagnostic-span-path (& diag.primary)))

(define (compiler-diagnostic-line [diag : (& diag CompilerDiagnostic)]) : i64
  (compiler-diagnostic-span-start-line (& diag.primary)))

(define (compiler-diagnostic-col [diag : (& diag CompilerDiagnostic)]) : i64
  (compiler-diagnostic-span-start-col (& diag.primary)))

(define (compiler-diagnostic-message [diag : (& diag CompilerDiagnostic)]) : String
  (string.copy (& diag.message)))

(define (compiler-diagnostic-message-ref [diag : (& diag CompilerDiagnostic)]) : (&
    diag
    str)
  (& diag.message))

(define (compiler-diagnostic-end-line [diag : (& diag CompilerDiagnostic)]) : i64
  (compiler-diagnostic-span-end-line (& diag.primary)))

(define (compiler-diagnostic-end-col [diag : (& diag CompilerDiagnostic)]) : i64
  (compiler-diagnostic-span-end-col (& diag.primary)))

(define (compiler-diagnostic-level [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticLevel
  (match diag.level
    [(CompilerDiagnosticError) CompilerDiagnosticError]
    [(CompilerDiagnosticWarning) CompilerDiagnosticWarning]
    [(CompilerDiagnosticNote) CompilerDiagnosticNote]))

(define (compiler-diagnostic-code [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticMaybeString
  (compiler-diagnostic-copy-maybe-string-ref (& diag.code)))

(define (compiler-diagnostic-code-parse) : String
  "E0100")

(define (compiler-diagnostic-code-typecheck) : String
  "E0200")

;; Per-kind typecheck codes (refs #5668). `E0200` stays as the code for a
;; typecheck error whose kind has not been classified yet, so nothing that
;; already renders loses a code.
;;
;; These are append-only. Once a code is published a user's bug report quoting
;; it has to keep meaning the same thing, so a number is never renumbered and a
;; retired number is never reused -- add the next free one instead.
;;
;; A typecheck error travels as `ResultTcType.Err <String>`, so its raise site
;; tags the message with a `CompilerTypecheckKind` (see
;; `compiler-diagnostic-typecheck-tagged`) and the code follows that kind, never
;; the wording. A message without a kind gets `E0200`.
(define (compiler-diagnostic-code-typecheck-unbound-name) : String
  "E0201")

(define (compiler-diagnostic-code-typecheck-arity-mismatch) : String
  "E0202")

(define (compiler-diagnostic-code-typecheck-non-exhaustive-match) : String
  "E0203")

(define (compiler-diagnostic-code-typecheck-unknown-struct-field) : String
  "E0204")

(define (compiler-diagnostic-code-typecheck-region-escape) : String
  "E0205")

(define (compiler-diagnostic-code-typecheck-type-mismatch) : String
  "E0206")

(define (compiler-diagnostic-code-typecheck-borrow-violation) : String
  "E0207")

(define (compiler-diagnostic-code-typecheck-move-violation) : String
  "E0208")

(define (compiler-diagnostic-code-typecheck-unsafe-context) : String
  "E0209")

(define (compiler-diagnostic-code-typecheck-lifetime-mismatch) : String
  "E0210")

(define (compiler-diagnostic-code-typecheck-resource-ownership) : String
  "E0211")

(define (compiler-diagnostic-code-typecheck-arena-ownership) : String
  "E0212")

(define (compiler-diagnostic-code-typecheck-pattern) : String
  "E0213")

(define (compiler-diagnostic-code-typecheck-spmd) : String
  "E0214")

(define (compiler-diagnostic-code-typecheck-place) : String
  "E0215")

(define (compiler-diagnostic-code-typecheck-control-flow) : String
  "E0216")

(define (compiler-diagnostic-code-typecheck-thread-safety) : String
  "E0217")

(define (compiler-diagnostic-code-typecheck-comptime-constraint) : String
  "E0218")

(define (compiler-diagnostic-code-typecheck-unsafe-callable-effect) : String
  "E0219")

(define (compiler-diagnostic-code-typecheck-foreign-global-write) : String
  "E0220")

(define (compiler-diagnostic-code-typecheck-opaque-representation) : String
  "E0221")

;; One kind per published typecheck code, append-only like the codes.
;; `Unclassified` is `E0200`: an internal or not yet named kind.
(defenum CompilerTypecheckKind
  (Unclassified)
  (UnboundName)
  (ArityMismatch)
  (NonExhaustiveMatch)
  (UnknownStructField)
  (RegionEscape)
  (TypeMismatch)
  (BorrowViolation)
  (MoveViolation)
  (UnsafeContext)
  (LifetimeMismatch)
  (ResourceOwnership)
  (ArenaOwnership)
  (Pattern)
  (Spmd)
  (Place)
  (ControlFlow)
  (ThreadSafety)
  (ComptimeConstraint)
  (UnsafeCallableEffect)
  (ForeignGlobalWrite)
  (OpaqueRepresentation))

(define (compiler-diagnostic-code-for-typecheck-kind
  [kind : CompilerTypecheckKind]) : String
  (match kind
    [(Unclassified) (compiler-diagnostic-code-typecheck)]
    [(UnboundName) (compiler-diagnostic-code-typecheck-unbound-name)]
    [(ArityMismatch) (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(NonExhaustiveMatch)
      (compiler-diagnostic-code-typecheck-non-exhaustive-match)]
    [(UnknownStructField)
      (compiler-diagnostic-code-typecheck-unknown-struct-field)]
    [(RegionEscape) (compiler-diagnostic-code-typecheck-region-escape)]
    [(TypeMismatch) (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(BorrowViolation) (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(MoveViolation) (compiler-diagnostic-code-typecheck-move-violation)]
    [(UnsafeContext) (compiler-diagnostic-code-typecheck-unsafe-context)]
    [(LifetimeMismatch) (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(ResourceOwnership)
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(ArenaOwnership) (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(Pattern) (compiler-diagnostic-code-typecheck-pattern)]
    [(Spmd) (compiler-diagnostic-code-typecheck-spmd)]
    [(Place) (compiler-diagnostic-code-typecheck-place)]
    [(ControlFlow) (compiler-diagnostic-code-typecheck-control-flow)]
    [(ThreadSafety) (compiler-diagnostic-code-typecheck-thread-safety)]
    [(ComptimeConstraint)
      (compiler-diagnostic-code-typecheck-comptime-constraint)]
    [(UnsafeCallableEffect)
      (compiler-diagnostic-code-typecheck-unsafe-callable-effect)]
    [(ForeignGlobalWrite)
      (compiler-diagnostic-code-typecheck-foreign-global-write)]
    [(OpaqueRepresentation)
      (compiler-diagnostic-code-typecheck-opaque-representation)]))

;; The kind tag sits in front of the message text: `__tl_tc_kind:<code>:`.
;; It holds no `|`, so it survives inside the typechecker's `|`-delimited
;; located, rich and macro-framed transports, which all keep the message text
;; at the front of their message field. `compiler-diagnostic-new` removes it
;; and records its code, so a tag never reaches rendered text.
(define (compiler-diagnostic-typecheck-tag-prefix) : String
  "__tl_tc_kind:")

;; Prefix, five-character code, `:`.
(define (compiler-diagnostic-typecheck-tag-length) : i64
  19)

;; `message` tagged with `kind`.
;; The tag for `kind`, as a literal: tagging a message is then one
;; concatenation, and a raise site that builds its message with `str-cat`
;; passes the tag as the first piece of that same concatenation.
(define (compiler-diagnostic-typecheck-tag [kind : CompilerTypecheckKind]) : String
  (match kind
    [(Unclassified) "__tl_tc_kind:E0200:"]
    [(UnboundName) "__tl_tc_kind:E0201:"]
    [(ArityMismatch) "__tl_tc_kind:E0202:"]
    [(NonExhaustiveMatch) "__tl_tc_kind:E0203:"]
    [(UnknownStructField) "__tl_tc_kind:E0204:"]
    [(RegionEscape) "__tl_tc_kind:E0205:"]
    [(TypeMismatch) "__tl_tc_kind:E0206:"]
    [(BorrowViolation) "__tl_tc_kind:E0207:"]
    [(MoveViolation) "__tl_tc_kind:E0208:"]
    [(UnsafeContext) "__tl_tc_kind:E0209:"]
    [(LifetimeMismatch) "__tl_tc_kind:E0210:"]
    [(ResourceOwnership) "__tl_tc_kind:E0211:"]
    [(ArenaOwnership) "__tl_tc_kind:E0212:"]
    [(Pattern) "__tl_tc_kind:E0213:"]
    [(Spmd) "__tl_tc_kind:E0214:"]
    [(Place) "__tl_tc_kind:E0215:"]
    [(ControlFlow) "__tl_tc_kind:E0216:"]
    [(ThreadSafety) "__tl_tc_kind:E0217:"]
    [(ComptimeConstraint) "__tl_tc_kind:E0218:"]
    [(UnsafeCallableEffect) "__tl_tc_kind:E0219:"]
    [(ForeignGlobalWrite) "__tl_tc_kind:E0220:"]
    [(OpaqueRepresentation) "__tl_tc_kind:E0221:"]))

;; `message` tagged with `kind`.
(define (compiler-diagnostic-typecheck-tagged
  [kind : CompilerTypecheckKind]
  [message : String]) : String
  (str_cat.str-cat (compiler-diagnostic-typecheck-tag kind) message))

;; Tests run on every diagnostic built, so they read the message in place.
(define (compiler-diagnostic-typecheck-tagged? [message : (& message str)]) : bool
  (and
    (>=
      (string.string-length message)
      (compiler-diagnostic-typecheck-tag-length))
    (string.is-string-prefix-at
      message
      (compiler-diagnostic-typecheck-tag-prefix)
      0)
    (=
      (cast
        (string.string-ref
          message
          (- (compiler-diagnostic-typecheck-tag-length) 1))
        : i64)
      58)))

;; The code a tagged message carries: the registry's own code string when the
;; tag names a typecheck code (registry row = code number + 1), else a copy of
;; the five tag characters.
(define (compiler-diagnostic-typecheck-tag-code [message : (& message str)]) : String
  (let
    [start : i64
      (string.string-length (compiler-diagnostic-typecheck-tag-prefix))]
    [tens : i64 (- (cast (string.string-ref message (+ start 3)) : i64) 48)]
    [ones : i64 (- (cast (string.string-ref message (+ start 4)) : i64) 48)]
    [code : String
      (if (and (>= tens 0) (<= tens 2) (>= ones 0) (<= ones 9))
        (compiler-diagnostic-code-registry-code (+ (+ (* tens 10) ones) 1))
        "")]
    (if (and
      (= (string.string-length code) 5)
      (string.is-string-prefix-at message code start))
      code
      (string.substring message start 5))))

;; The message of `diag` as typecheck error text, tagged with its code when
;; that is a typecheck code, so the kind survives a trip back through a
;; `ResultTcType.Err` string.
(define (compiler-diagnostic-typecheck-error-text
  [diag : (& diag CompilerDiagnostic)]) : String
  (match (compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code)
      (if (and
        (= (string.string-length (& code)) 5)
        (string.eq (string.substring (& code) 0 3) "E02"))
        (str_cat.str-cat
          (compiler-diagnostic-typecheck-tag-prefix)
          code
          ":"
          (compiler-diagnostic-message diag))
        (compiler-diagnostic-message diag))]
    [CompilerDiagnosticNoString (compiler-diagnostic-message diag)]))

;; A message without its kind tag. Anything that shows or compares raw
;; typecheck error text uses this.
(define (compiler-diagnostic-untagged-message [message : String]) : String
  (if (compiler-diagnostic-typecheck-tagged? (& message))
    (string.substring
      (& message)
      (compiler-diagnostic-typecheck-tag-length)
      (-
        (string.string-length (& message))
        (compiler-diagnostic-typecheck-tag-length)))
    message))

;; Machine-readable inventory for the public diagnostic surface. Keep this in
;; the module that assigns codes rather than in the `explain` frontend: tests
;; can then prove that every published code has exactly one registry row and a
;; detailed explanation. `owner` identifies the subsystem responsible for
;; keeping the classification and explanation current.
(define (compiler-diagnostic-code-registry-count) : i64
  23)

(define (compiler-diagnostic-code-registry-code [index : i64]) : String
  (cond
    [(= index 0) (compiler-diagnostic-code-parse)]
    [(= index 1) (compiler-diagnostic-code-typecheck)]
    [(= index 2) (compiler-diagnostic-code-typecheck-unbound-name)]
    [(= index 3) (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(= index 4) (compiler-diagnostic-code-typecheck-non-exhaustive-match)]
    [(= index 5) (compiler-diagnostic-code-typecheck-unknown-struct-field)]
    [(= index 6) (compiler-diagnostic-code-typecheck-region-escape)]
    [(= index 7) (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(= index 8) (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(= index 9) (compiler-diagnostic-code-typecheck-move-violation)]
    [(= index 10) (compiler-diagnostic-code-typecheck-unsafe-context)]
    [(= index 11) (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(= index 12) (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(= index 13) (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(= index 14) (compiler-diagnostic-code-typecheck-pattern)]
    [(= index 15) (compiler-diagnostic-code-typecheck-spmd)]
    [(= index 16) (compiler-diagnostic-code-typecheck-place)]
    [(= index 17) (compiler-diagnostic-code-typecheck-control-flow)]
    [(= index 18) (compiler-diagnostic-code-typecheck-thread-safety)]
    [(= index 19) (compiler-diagnostic-code-typecheck-comptime-constraint)]
    [(= index 20) (compiler-diagnostic-code-typecheck-unsafe-callable-effect)]
    [(= index 21) (compiler-diagnostic-code-typecheck-foreign-global-write)]
    [(= index 22) (compiler-diagnostic-code-typecheck-opaque-representation)]
    [else ""]))

(define (compiler-diagnostic-code-registry-title [index : i64]) : String
  (cond
    [(= index 0) "parse error"]
    [(= index 1) "unclassified typecheck error"]
    [(= index 2) "unbound name"]
    [(= index 3) "arity mismatch"]
    [(= index 4) "non-exhaustive match"]
    [(= index 5) "unknown struct field"]
    [(= index 6) "region escape"]
    [(= index 7) "type mismatch"]
    [(= index 8) "borrow violation"]
    [(= index 9) "move violation"]
    [(= index 10) "unsafe context required"]
    [(= index 11) "lifetime mismatch"]
    [(= index 12) "resource ownership violation"]
    [(= index 13) "arena ownership violation"]
    [(= index 14) "invalid pattern"]
    [(= index 15) "SPMD restriction"]
    [(= index 16) "invalid storage place"]
    [(= index 17) "control-flow misuse"]
    [(= index 18) "thread-safety violation"]
    [(= index 19) "compile-time constraint"]
    [(= index 20) "unsafe callable effect erasure"]
    [(= index 21) "global written outside its module"]
    [(= index 22) "opaque representation used outside its module family"]
    [else ""]))

(define (compiler-diagnostic-code-or-empty [diag : (& diag CompilerDiagnostic)]) : String
  (match (compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code) code]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-category [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticMaybeString
  (compiler-diagnostic-copy-maybe-string-ref (& diag.category)))

(define (compiler-diagnostic-help [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticMaybeString
  (compiler-diagnostic-copy-maybe-string-ref (& diag.help)))

(define (compiler-diagnostic-secondary-spans
  [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticLabelList
  (compiler-diagnostic-copy-label-list-ref (& diag.secondary)))

(define (compiler-diagnostic-notes [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticNoteList
  (compiler-diagnostic-copy-note-list-ref (& diag.notes)))

(define (compiler-diagnostic-fixes [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticFixSeq
  (compiler-diagnostic-copy-fix-list-ref (& diag.fixes)))

(define (compiler-diagnostic-primary-span [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnosticSpan
  (compiler-diagnostic-copy-span-ref (& diag.primary)))

(define (compiler-diagnostic-text-edit-span [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticSpan
  edit.span)

(define (compiler-diagnostic-text-edit-replacement
  [edit : CompilerDiagnosticTextEdit]) : String
  edit.replacement)

(define (compiler-diagnostic-fix-title [fix : CompilerDiagnosticFix]) : String
  fix.title)

(define (compiler-diagnostic-fix-applicability [fix : CompilerDiagnosticFix]) : CompilerDiagnosticApplicability
  fix.applicability)

(define (compiler-diagnostic-fix-edits [fix : CompilerDiagnosticFix]) : CompilerDiagnosticTextEditSeq
  fix.edits)

;; A kind tag on `message` becomes the code unless `code` is given, and is
;; removed from the text.
(define (compiler-diagnostic-new
  [message : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [category : CompilerDiagnosticMaybeString]
  [primary : CompilerDiagnosticSpan]
  [help : CompilerDiagnosticMaybeString]
  [secondary : CompilerDiagnosticLabelList]
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnostic
  ;; One tag test per diagnostic: a leading kind tag becomes the code (unless
  ;; `code` is given) and is removed from the text.
  (let
    [tagged : bool (compiler-diagnostic-typecheck-tagged? (& message))]
    [resolved : CompilerDiagnosticMaybeString
      (match code
        [CompilerDiagnosticNoString
          (if tagged
            (CompilerDiagnosticSomeString
              (compiler-diagnostic-typecheck-tag-code (& message)))
            CompilerDiagnosticNoString)]
        [(CompilerDiagnosticSomeString text)
          (CompilerDiagnosticSomeString text)])]
    (CompilerDiagnostic
      (if tagged
        (string.substring
          (& message)
          (compiler-diagnostic-typecheck-tag-length)
          (-
            (string.string-length (& message))
            (compiler-diagnostic-typecheck-tag-length)))
        message)
      level
      resolved
      category
      primary
      help
      secondary
      notes
      (CompilerDiagnosticFixSeq (__tl_make-array CompilerDiagnosticFix 0) 0))))

(define (compiler-diagnostic-copy-maybe-string
  [value : (& CompilerDiagnosticMaybeString)]) : CompilerDiagnosticMaybeString
  (match (owned_view.compiler-owned-reference-shared-view value)
    [CompilerDiagnosticNoString CompilerDiagnosticNoString]
    [(CompilerDiagnosticSomeString text)
      (CompilerDiagnosticSomeString (string.copy (& text)))]))

(define (compiler-diagnostic-copy-maybe-string-ref
  [value : (& value CompilerDiagnosticMaybeString)]) : CompilerDiagnosticMaybeString
  (match value
    [CompilerDiagnosticNoString CompilerDiagnosticNoString]
    [(CompilerDiagnosticSomeString text)
      (CompilerDiagnosticSomeString (string.copy (& text)))]))

(define (compiler-diagnostic-copy-span [span : (& CompilerDiagnosticSpan)]) : CompilerDiagnosticSpan
  (CompilerDiagnosticSpan
    (string.copy (& span.path))
    span.start-line
    span.start-col
    span.end-line
    span.end-col))

(define (compiler-diagnostic-copy-span-ref
  [span : (& span CompilerDiagnosticSpan)]) : CompilerDiagnosticSpan
  (CompilerDiagnosticSpan
    (string.copy (& span.path))
    span.start-line
    span.start-col
    span.end-line
    span.end-col))

(define (compiler-diagnostic-label-list-empty) : CompilerDiagnosticLabelList
  (CompilerDiagnosticLabelList (__tl_make-array CompilerDiagnosticLabel 0) 0))

(define (compiler-diagnostic-label-list-count
  [labels : (& labels CompilerDiagnosticLabelList)]) : i64
  labels.len)

(define (compiler-diagnostic-label-list-get
  [labels : (& labels CompilerDiagnosticLabelList)]
  [index : i64]) : CompilerDiagnosticLabel
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data labels.slots) index))))

;; Label attachment is a persistent update. A right-sized replacement keeps the
;; source diagnostic isolated while retaining the established newest-first order.
(define (compiler-diagnostic-label-list-prepend
  [label : CompilerDiagnosticLabel]
  [labels : CompilerDiagnosticLabelList]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [src : (__tl_dyn-array CompilerDiagnosticLabel) labels.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel (+ count 1))]
    [index : i64 0]
    (set! (array-ref dst 0) label)
    (while (< index count)
      (set! (array-ref dst (+ index 1)) (array-ref src index))
      (set! index (+ index 1)))
    (CompilerDiagnosticLabelList dst (+ count 1))))

(define (compiler-diagnostic-copy-label-list
  [labels : CompilerDiagnosticLabelList]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [src : (__tl_dyn-array CompilerDiagnosticLabel) labels.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (while (< index count)
      (let
        [label : CompilerDiagnosticLabel
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data src) index)))]
        (set!
          (array-ref dst index)
          (CompilerDiagnosticLabel
            (compiler-diagnostic-copy-span (& label.span))
            (compiler-diagnostic-copy-maybe-string (& label.label))))
        (set! index (+ index 1))))
    (CompilerDiagnosticLabelList dst count)))

(define (compiler-diagnostic-copy-label-list-ref
  [labels : (& labels CompilerDiagnosticLabelList)]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (while (< index count)
      (let
        [label : CompilerDiagnosticLabel
          (compiler-diagnostic-label-list-get labels index)]
        (set!
          (array-ref dst index)
          (CompilerDiagnosticLabel
            (compiler-diagnostic-copy-span-ref (& label.span))
            (compiler-diagnostic-copy-maybe-string-ref (& label.label))))
        (set! index (+ index 1))))
    (CompilerDiagnosticLabelList dst count)))

(define (compiler-diagnostic-note-list-empty) : CompilerDiagnosticNoteList
  (CompilerDiagnosticNoteList (__tl_make-array String 0) 0))

(define (compiler-diagnostic-note-list-count
  [notes : (& notes CompilerDiagnosticNoteList)]) : i64
  notes.len)

(define (compiler-diagnostic-note-list-get
  [notes : (& notes CompilerDiagnosticNoteList)]
  [index : i64]) : String
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data notes.slots) index))))

;; Notes have the same persistent newest-first attachment contract as labels.
(define (compiler-diagnostic-note-list-prepend
  [note : String]
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnosticNoteList
  (let
    [count : i64 notes.len]
    [src : (__tl_dyn-array String) notes.slots]
    [dst : (__tl_dyn-array String) (__tl_make-array String (+ count 1))]
    [index : i64 0]
    (set! (array-ref dst 0) note)
    (while (< index count)
      (set! (array-ref dst (+ index 1)) (array-ref src index))
      (set! index (+ index 1)))
    (CompilerDiagnosticNoteList dst (+ count 1))))

(define (compiler-diagnostic-copy-note-list
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnosticNoteList
  (let
    [count : i64 notes.len]
    [src : (__tl_dyn-array String) notes.slots]
    [dst : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref dst index) (string.copy (& (array-ref src index))))
      (set! index (+ index 1)))
    (CompilerDiagnosticNoteList dst count)))

(define (compiler-diagnostic-copy-note-list-ref
  [notes : (& notes CompilerDiagnosticNoteList)]) : CompilerDiagnosticNoteList
  (let
    [count : i64 notes.len]
    [dst : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (while (< index count)
      (let
        [note : String (compiler-diagnostic-note-list-get notes index)]
        (set! (array-ref dst index) (string.copy (& note)))
        (set! index (+ index 1))))
    (CompilerDiagnosticNoteList dst count)))

(define (compiler-diagnostic-copy-text-edit
  [edit : (& CompilerDiagnosticTextEdit)]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit
    (compiler-diagnostic-copy-span (& edit.span))
    (string.copy (& edit.replacement))))

(define (compiler-diagnostic-copy-text-edit-ref
  [edit : (& edit CompilerDiagnosticTextEdit)]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit
    (compiler-diagnostic-copy-span-ref (& edit.span))
    (string.copy (& edit.replacement))))

(define (compiler-diagnostic-copy-text-edit-list
  [edits : CompilerDiagnosticTextEditSeq]) : CompilerDiagnosticTextEditSeq
  (let
    [count : i64 edits.len]
    [src : (__tl_dyn-array CompilerDiagnosticTextEdit) edits.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (__tl_make-array CompilerDiagnosticTextEdit count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref dst index)
        (compiler-diagnostic-copy-text-edit
          (&
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data src) index))))))
      (set! index (+ index 1)))
    (CompilerDiagnosticTextEditSeq dst count)))

(define (compiler-diagnostic-copy-fix [fix : CompilerDiagnosticFix]) : CompilerDiagnosticFix
  (CompilerDiagnosticFix
    (string.copy (& fix.title))
    fix.applicability
    (compiler-diagnostic-copy-text-edit-list fix.edits)))

(define (compiler-diagnostic-copy-fix-list [fixes : CompilerDiagnosticFixSeq]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [src : (__tl_dyn-array CompilerDiagnosticFix) fixes.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref dst index)
        (compiler-diagnostic-copy-fix
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data src) index)))))
      (set! index (+ index 1)))
    (CompilerDiagnosticFixSeq dst count)))

(define (compiler-diagnostic-copy-fix-list-ref
  [fixes : (& fixes CompilerDiagnosticFixSeq)]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (while (< index count)
      (let
        [fix : CompilerDiagnosticFix
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data fixes.slots) index)))]
        (set! (array-ref dst index) (compiler-diagnostic-copy-fix fix))
        (set! index (+ index 1))))
    (CompilerDiagnosticFixSeq dst count)))

(define (compiler-diagnostic-copy [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (CompilerDiagnostic
    (string.copy (& diag.message))
    diag.level
    (compiler-diagnostic-copy-maybe-string (& diag.code))
    (compiler-diagnostic-copy-maybe-string (& diag.category))
    (compiler-diagnostic-copy-span (& diag.primary))
    (compiler-diagnostic-copy-maybe-string (& diag.help))
    (compiler-diagnostic-copy-label-list diag.secondary)
    (compiler-diagnostic-copy-note-list diag.notes)
    (compiler-diagnostic-copy-fix-list diag.fixes)))

(define (compiler-diagnostic-copy-ref [diag : (& diag CompilerDiagnostic)]) : CompilerDiagnostic
  (CompilerDiagnostic
    (string.copy (& diag.message))
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-copy-maybe-string-ref (& diag.code))
    (compiler-diagnostic-copy-maybe-string-ref (& diag.category))
    (compiler-diagnostic-copy-span-ref (& diag.primary))
    (compiler-diagnostic-copy-maybe-string-ref (& diag.help))
    (compiler-diagnostic-copy-label-list-ref (& diag.secondary))
    (compiler-diagnostic-copy-note-list-ref (& diag.notes))
    (compiler-diagnostic-copy-fix-list-ref (& diag.fixes))))

(define (compiler-diagnostic-position-before-or-equal?
  [left-line : i64]
  [left-col : i64]
  [right-line : i64]
  [right-col : i64]) : bool
  (or
    (< left-line right-line)
    (and (= left-line right-line) (<= left-col right-col))))

(define (compiler-diagnostic-span-valid-for-edit?
  [span : (& CompilerDiagnosticSpan)]) : bool
  (and
    (> (compiler-diagnostic-span-start-line span) 0)
    (> (compiler-diagnostic-span-start-col span) 0)
    (> (compiler-diagnostic-span-end-line span) 0)
    (> (compiler-diagnostic-span-end-col span) 0)
    (compiler-diagnostic-position-before-or-equal?
      (compiler-diagnostic-span-start-line span)
      (compiler-diagnostic-span-start-col span)
      (compiler-diagnostic-span-end-line span)
      (compiler-diagnostic-span-end-col span))))

(define (compiler-diagnostic-span-empty?
  [span : (& span CompilerDiagnosticSpan)]) : bool
  (and
    (=
      (compiler-diagnostic-span-start-line span)
      (compiler-diagnostic-span-end-line span))
    (=
      (compiler-diagnostic-span-start-col span)
      (compiler-diagnostic-span-end-col span))))

(define (compiler-diagnostic-edit-effective-path
  [diagnostic-path : String]
  [edit : CompilerDiagnosticTextEdit]) : String
  (let
    [span : CompilerDiagnosticSpan edit.span]
    [path : String (compiler-diagnostic-span-path span)]
    (if (string.eq path "")
      diagnostic-path
      path)))

(define (compiler-diagnostic-edit-overlaps?
  [diagnostic-path : String]
  [left : CompilerDiagnosticTextEdit]
  [right : CompilerDiagnosticTextEdit]) : bool
  (let
    [left-span : CompilerDiagnosticSpan
      (compiler-diagnostic-place-shared-view left.span)]
    [right-span : CompilerDiagnosticSpan
      (compiler-diagnostic-place-shared-view right.span)]
    [same-path : bool
      (string.eq
        (compiler-diagnostic-edit-effective-path
          (compiler-diagnostic-place-shared-view diagnostic-path)
          left)
        (compiler-diagnostic-edit-effective-path diagnostic-path right))]
    [left-before-right : bool
      (compiler-diagnostic-position-before-or-equal?
        (compiler-diagnostic-span-end-line left-span)
        (compiler-diagnostic-span-end-col left-span)
        (compiler-diagnostic-span-start-line right-span)
        (compiler-diagnostic-span-start-col right-span))]
    [right-before-left : bool
      (compiler-diagnostic-position-before-or-equal?
        (compiler-diagnostic-span-end-line right-span)
        (compiler-diagnostic-span-end-col right-span)
        (compiler-diagnostic-span-start-line left-span)
        (compiler-diagnostic-span-start-col left-span))]
    [same-empty-position : bool
      (and
        (compiler-diagnostic-span-empty? left-span)
        (compiler-diagnostic-span-empty? right-span)
        (=
          (compiler-diagnostic-span-start-line left-span)
          (compiler-diagnostic-span-start-line right-span))
        (=
          (compiler-diagnostic-span-start-col left-span)
          (compiler-diagnostic-span-start-col right-span)))]
    (and
      same-path
      (or same-empty-position (not (or left-before-right right-before-left))))))

;; Scans the suffix after `start`.
(define (compiler-diagnostic-edit-overlaps-rest?
  [diagnostic-path : String]
  [edit : (& CompilerDiagnosticTextEdit)]
  [slots : (& slots (__tl_dyn-array CompilerDiagnosticTextEdit))]
  [count : i64]
  [start : i64]) : bool
  (let
    [cursor : i64 start]
    [found : bool false]
    (while (and (not found) (< cursor count))
      (if (compiler-diagnostic-edit-overlaps?
        (compiler-diagnostic-place-shared-view diagnostic-path)
        (owned_view.compiler-owned-reference-shared-view edit)
        (compiler-diagnostic-copy-text-edit-ref (& (array-ref slots cursor))))
        (set! found true)
        unit)
      (set! cursor (+ cursor 1)))
    found))

(define (compiler-diagnostic-edit-list-valid?
  [diagnostic-path : String]
  [edits : CompilerDiagnosticTextEditSeq]) : bool
  (let
    [count : i64 edits.len]
    [slots : (__tl_dyn-array CompilerDiagnosticTextEdit) edits.slots]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (let
        [edit : CompilerDiagnosticTextEdit
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data slots) index)))]
        (if (and
          (compiler-diagnostic-span-valid-for-edit? (& edit.span))
          (not
            (compiler-diagnostic-edit-overlaps-rest?
              (compiler-diagnostic-place-shared-view diagnostic-path)
              (& edit)
              (& slots)
              count
              (+ index 1))))
          unit
          (set! ok false))
        (set! index (+ index 1))))
    ok))

(define (compiler-diagnostic-fix-valid?
  [diagnostic-path : String]
  [fix : CompilerDiagnosticFix]) : bool
  (let
    [edits : CompilerDiagnosticTextEditSeq fix.edits]
    (and
      (> (string.string-length fix.title) 0)
      (> edits.len 0)
      (compiler-diagnostic-edit-list-valid? diagnostic-path edits))))

;; Where SPAN lies in a text, named TEXT-PATH or left pathless, that is made of
;; a head of HEAD-LINES lines followed by a tail. A span starting in the head
;; takes HEAD-PATH, and a later span takes TAIL-PATH with its lines counted from
;; the tail's first line. A span in any other file is left alone. With no head
;; lines this only renames the text.
(define (compiler-diagnostic-span-split-at-line
  [span : CompilerDiagnosticSpan]
  [text-path : (& text-path str)]
  [head-lines : i64]
  [head-path : (& head-path str)]
  [tail-path : (& tail-path str)]) : CompilerDiagnosticSpan
  (let
    [start-line : i64 (compiler-diagnostic-span-start-line span)]
    [path : String (compiler-diagnostic-span-path span)]
    (cond
      [(not (or (string.eq path "") (string.eq path text-path))) span]
      [(> start-line head-lines)
        (CompilerDiagnosticSpan
          (string.copy tail-path)
          (- start-line head-lines)
          (compiler-diagnostic-span-start-col span)
          (- (compiler-diagnostic-span-end-line span) head-lines)
          (compiler-diagnostic-span-end-col span))]
      [else
        (CompilerDiagnosticSpan
          (string.copy head-path)
          start-line
          (compiler-diagnostic-span-start-col span)
          (compiler-diagnostic-span-end-line span)
          (compiler-diagnostic-span-end-col span))])))

(define (compiler-diagnostic-split-text-edit
  [edit : CompilerDiagnosticTextEdit]
  [text-path : (& text-path str)]
  [head-lines : i64]
  [head-path : (& head-path str)]
  [tail-path : (& tail-path str)]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit
    (compiler-diagnostic-span-split-at-line
      edit.span
      text-path
      head-lines
      head-path
      tail-path)
    edit.replacement))

(define (compiler-diagnostic-split-text-edit-list
  [edits : CompilerDiagnosticTextEditSeq]
  [text-path : (& text-path str)]
  [head-lines : i64]
  [head-path : (& head-path str)]
  [tail-path : (& tail-path str)]) : CompilerDiagnosticTextEditSeq
  (let
    [count : i64 edits.len]
    [src : (__tl_dyn-array CompilerDiagnosticTextEdit) edits.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (__tl_make-array CompilerDiagnosticTextEdit count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref dst index)
        (compiler-diagnostic-split-text-edit
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data src) index)))
          text-path
          head-lines
          head-path
          tail-path))
      (set! index (+ index 1)))
    (CompilerDiagnosticTextEditSeq dst count)))

(define (compiler-diagnostic-split-fix-list
  [fixes : CompilerDiagnosticFixSeq]
  [text-path : (& text-path str)]
  [head-lines : i64]
  [head-path : (& head-path str)]
  [tail-path : (& tail-path str)]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [src : (__tl_dyn-array CompilerDiagnosticFix) fixes.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (while (< index count)
      (let
        [fix : CompilerDiagnosticFix
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data src) index)))]
        (set!
          (array-ref dst index)
          (CompilerDiagnosticFix
            fix.title
            fix.applicability
            (compiler-diagnostic-split-text-edit-list
              fix.edits
              text-path
              head-lines
              head-path
              tail-path)))
        (set! index (+ index 1))))
    (CompilerDiagnosticFixSeq dst count)))

(define (compiler-diagnostic-simple
  [path : String]
  [line : i64]
  [col : i64]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan path line col line col)
    CompilerDiagnosticNoString
    (compiler-diagnostic-label-list-empty)
    (compiler-diagnostic-note-list-empty)))

(define (compiler-diagnostic-from-span
  [path : String]
  [span : token.SourceSpan]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan
      path
      (token.span-start-line span)
      (token.span-start-col span)
      (token.span-end-line span)
      (token.span-end-col span))
    CompilerDiagnosticNoString
    (compiler-diagnostic-label-list-empty)
    (compiler-diagnostic-note-list-empty)))

(define (compiler-diagnostic-from-ast-span
  [path : String]
  [span : ast.AstSourceSpan]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan
      path
      (ast.ast-source-span-start-line span)
      (ast.ast-source-span-start-col span)
      (ast.ast-source-span-end-line span)
      (ast.ast-source-span-end-col span))
    CompilerDiagnosticNoString
    (compiler-diagnostic-label-list-empty)
    (compiler-diagnostic-note-list-empty)))

(define (compiler-diagnostic-from-source-error
  [path : String]
  [err : token.SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (token.source-error-span (compiler-diagnostic-place-shared-view err))
    (token.source-error-message err)))

(define (compiler-diagnostic-at-start [path : String] [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-simple path 1 1 message))

(define (compiler-diagnostic-with-path
  [diag : (& CompilerDiagnostic)]
  [path : (& str)]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (CompilerDiagnosticSpan
      (string.copy path)
      (compiler-diagnostic-line diag)
      (compiler-diagnostic-col diag)
      (compiler-diagnostic-end-line diag)
      (compiler-diagnostic-end-col diag))
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-split-fix-list
      (compiler-diagnostic-fixes diag)
      ""
      0
      path
      path)))

(define (compiler-diagnostic-split-label-list
  [labels : (& CompilerDiagnosticLabelList)]
  [text-path : (& text-path str)]
  [head-lines : i64]
  [head-path : (& head-path str)]
  [tail-path : (& tail-path str)]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (while (< index count)
      (let
        [entry : CompilerDiagnosticLabel
          (compiler-diagnostic-label-list-get labels index)]
        (set!
          (array-ref dst index)
          (CompilerDiagnosticLabel
            (compiler-diagnostic-span-split-at-line
              entry.span
              text-path
              head-lines
              head-path
              tail-path)
            entry.label))
        (set! index (+ index 1))))
    (CompilerDiagnosticLabelList dst count)))

;; A diagnostic located in a text made of a head of HEAD-LINES lines followed
;; by a tail, relocated span by span with
;; `compiler-diagnostic-span-split-at-line`: the primary span, the secondary
;; spans and the fix edits.
(define (compiler-diagnostic-split-at-line
  [diag : (& CompilerDiagnostic)]
  [text-path : (& str)]
  [head-lines : i64]
  [head-path : (& str)]
  [tail-path : (& str)]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-span-split-at-line
      (compiler-diagnostic-primary-span diag)
      text-path
      head-lines
      head-path
      tail-path)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-split-label-list
      (& (compiler-diagnostic-secondary-spans diag))
      text-path
      head-lines
      head-path
      tail-path)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-split-fix-list
      (compiler-diagnostic-fixes diag)
      text-path
      head-lines
      head-path
      tail-path)))

(define (compiler-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (and
    (not (string.eq path ""))
    (string.eq (compiler-diagnostic-path diag) ""))
    (compiler-diagnostic-with-path (& diag) (& path))
    diag))

(define (compiler-diagnostic-with-level
  [diag : (& CompilerDiagnostic)]
  [level : CompilerDiagnosticLevel]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    level
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-with-code
  [diag : (& CompilerDiagnostic)]
  [code : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (CompilerDiagnosticSomeString code)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-with-category
  [diag : (& CompilerDiagnostic)]
  [category : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (CompilerDiagnosticSomeString category)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-with-help
  [diag : (& CompilerDiagnostic)]
  [help : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (CompilerDiagnosticSomeString help)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-with-secondary
  [diag : (& CompilerDiagnostic)]
  [span : CompilerDiagnosticSpan]
  [label : CompilerDiagnosticMaybeString]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-label-list-prepend
      (CompilerDiagnosticLabel span label)
      (compiler-diagnostic-secondary-spans diag))
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-maybe-string-eq?
  [left : (& CompilerDiagnosticMaybeString)]
  [right : (& CompilerDiagnosticMaybeString)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view left)
    [CompilerDiagnosticNoString
      (match right
        [CompilerDiagnosticNoString true]
        [(CompilerDiagnosticSomeString _) false])]
    [(CompilerDiagnosticSomeString left-text)
      (match (owned_view.compiler-owned-reference-shared-view right)
        [(CompilerDiagnosticSomeString right-text)
          (string.eq left-text right-text)]
        [CompilerDiagnosticNoString false])]))

(define (compiler-diagnostic-span-eq?
  [left : (& left CompilerDiagnosticSpan)]
  [right : (& right CompilerDiagnosticSpan)]) : bool
  (and
    (string.eq left.path right.path)
    (= left.start-line right.start-line)
    (= left.start-col right.start-col)
    (= left.end-line right.end-line)
    (= left.end-col right.end-col)))

(define (compiler-diagnostic-secondary-present?
  [diag : (& diag CompilerDiagnostic)]
  [span : (& span CompilerDiagnosticSpan)]
  [label : (& CompilerDiagnosticMaybeString)]) : bool
  (let
    [labels : CompilerDiagnosticLabelList
      (compiler-diagnostic-secondary-spans diag)]
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (let
        [entry : CompilerDiagnosticLabel
          (compiler-diagnostic-label-list-get labels index)]
        [entry-span : CompilerDiagnosticSpan entry.span]
        (if (and
          (compiler-diagnostic-span-eq? (& entry-span) (& span))
          (compiler-diagnostic-maybe-string-eq? (& entry.label) label))
          (set! found true)
          unit)
        (set! index (+ index 1))))
    found))

(define (compiler-diagnostic-with-secondary-if-new
  [diag : CompilerDiagnostic]
  [span : (& CompilerDiagnosticSpan)]
  [label : (& CompilerDiagnosticMaybeString)]) : CompilerDiagnostic
  (if (compiler-diagnostic-secondary-present? diag span label)
    diag
    (compiler-diagnostic-with-secondary
      (& diag)
      (owned_view.compiler-owned-reference-shared-view span)
      (owned_view.compiler-owned-reference-shared-view label))))

(define (compiler-diagnostic-with-note
  [diag : CompilerDiagnostic]
  [note : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-note-list-prepend
      note
      (compiler-diagnostic-notes diag))
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-with-primary-span
  [diag : (& CompilerDiagnostic)]
  [span : CompilerDiagnosticSpan]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    span
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

;; Reuse a diagnostic's location (path/line/col) with a new message. Used by the
;;
;; backend to stamp an error message onto a function's source span.
(define (compiler-diagnostic-with-message
  [diag : (& CompilerDiagnostic)]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    message
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-fixes diag)))

(define (compiler-diagnostic-text-edit-new
  [span : CompilerDiagnosticSpan]
  [replacement : String]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit span replacement))

(define (compiler-diagnostic-text-edit-single
  [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticTextEditSeq
  (let
    [slots : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (__tl_make-array CompilerDiagnosticTextEdit 1)]
    (set! (array-ref slots 0) edit)
    (CompilerDiagnosticTextEditSeq slots 1)))

(define (compiler-diagnostic-fix-new
  [title : String]
  [applicability : CompilerDiagnosticApplicability]
  [edits : CompilerDiagnosticTextEditSeq]) : CompilerDiagnosticFix
  (CompilerDiagnosticFix title applicability edits))

;; Copies into a right-sized array rather than appending in place: `with-fix` is
;; a persistent update, so the source diagnostic must keep its own fix list.
(define (compiler-diagnostic-fix-prepend
  [fix : CompilerDiagnosticFix]
  [fixes : CompilerDiagnosticFixSeq]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [src : (__tl_dyn-array CompilerDiagnosticFix) fixes.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix (+ count 1))]
    [index : i64 0]
    (set! (array-ref dst 0) fix)
    (while (< index count)
      (set! (array-ref dst (+ index 1)) (array-ref src index))
      (set! index (+ index 1)))
    (CompilerDiagnosticFixSeq dst (+ count 1))))

;; Fix attachment is the validation boundary: generated/unknown 0:0 spans,
;; reversed spans, empty edit sets, and overlapping half-open edits are not
;; admitted to the diagnostic. Empty paths inherit the primary source path.
(define (compiler-diagnostic-with-fix
  [diag : CompilerDiagnostic]
  [fix : (& CompilerDiagnosticFix)]) : CompilerDiagnostic
  (if (compiler-diagnostic-fix-valid?
    (compiler-diagnostic-path diag)
    (owned_view.compiler-owned-reference-shared-view fix))
    (CompilerDiagnostic
      (compiler-diagnostic-message diag)
      (compiler-diagnostic-level diag)
      (compiler-diagnostic-code diag)
      (compiler-diagnostic-category diag)
      (compiler-diagnostic-primary-span diag)
      (compiler-diagnostic-help diag)
      (compiler-diagnostic-secondary-spans diag)
      (compiler-diagnostic-notes diag)
      (compiler-diagnostic-fix-prepend
        (owned_view.compiler-owned-reference-shared-view fix)
        (compiler-diagnostic-fixes diag)))
    diag))

(define (compiler-diagnostic-render-notes
  [notes : (& CompilerDiagnosticNoteList)]) : String
  (let
    [count : i64 (compiler-diagnostic-note-list-count notes)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< index count)
      (text_buf.append! out "\nnote: ")
      (text_buf.append! out (compiler-diagnostic-note-list-get notes index))
      (set! index (+ index 1)))
    (text_buf.render out)))

(define (compiler-diagnostic-render-flat-secondary
  [primary-path : String]
  [entry : CompilerDiagnosticLabel]) : String
  (let
    [span : CompilerDiagnosticSpan entry.span]
    [path : String (compiler-diagnostic-span-path (& span))]
    [label : String
      (match entry.label
        [(CompilerDiagnosticSomeString text) text]
        [(CompilerDiagnosticNoString) "related location"])]
    (str_cat.str-cat
      "\nrelated: "
      (if (string.eq path "")
        primary-path
        path)
      ":"
      (string.int->string (compiler-diagnostic-span-start-line (& span)))
      ":"
      (string.int->string (compiler-diagnostic-span-start-col (& span)))
      ": "
      label)))

(define (compiler-diagnostic-render-flat-secondaries
  [primary-path : String]
  [labels : (& CompilerDiagnosticLabelList)]) : String
  (let
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< index count)
      (text_buf.append!
        out
        (compiler-diagnostic-render-flat-secondary
          (compiler-diagnostic-place-shared-view primary-path)
          (compiler-diagnostic-label-list-get labels index)))
      (set! index (+ index 1)))
    (text_buf.render out)))

(define (compiler-diagnostic-render [diag : (& diag CompilerDiagnostic)]) : String
  (str_cat.str-cat
    (compiler-diagnostic-path diag)
    ":"
    (string.int->string (compiler-diagnostic-line diag))
    ":"
    (string.int->string (compiler-diagnostic-col diag))
    ": "
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-render-flat-secondaries
      (compiler-diagnostic-path diag)
      (& (compiler-diagnostic-secondary-spans diag)))
    (compiler-diagnostic-render-notes (& (compiler-diagnostic-notes diag)))))

(define (compiler-diagnostic-level-render [level : CompilerDiagnosticLevel]) : String
  (match level
    [(CompilerDiagnosticError) "error"]
    [(CompilerDiagnosticWarning) "warning"]
    [(CompilerDiagnosticNote) "note"]))

(define (compiler-diagnostic-repeat [chunk : (& str)] [count : i64]) : String
  (let
    [idx : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< idx count)
      (text_buf.append! out (string.copy chunk))
      (set! idx (+ idx 1)))
    (text_buf.render out)))

(define (compiler-diagnostic-line-gutter [line : i64]) : String
  (let
    [line-text : String (string.int->string line)]
    (if (< line 10)
      (str_cat.str-cat " " line-text)
      line-text)))

(define (compiler-diagnostic-blank-gutter [line : i64]) : String
  (compiler-diagnostic-repeat
    " "
    (string.string-length (compiler-diagnostic-line-gutter line))))

(define (compiler-diagnostic-column-padding [col : i64]) : i64
  (if (> col 1)
    (- col 1)
    0))

(define (compiler-diagnostic-span-width
  [span : (& span CompilerDiagnosticSpan)]) : i64
  (if (=
    (compiler-diagnostic-span-start-line span)
    (compiler-diagnostic-span-end-line span))
    (let
      [raw-width : i64
        (-
          (compiler-diagnostic-span-end-col span)
          (compiler-diagnostic-span-start-col span))]
      (if (> raw-width 0)
        raw-width
        1))
    1))

;; A diagnostic's source text with the byte offset at which each of its lines
;; starts, found in one pass. Rendering any number of snippets against it then
;; costs that pass plus a substring per snippet, where scanning from byte 0 for
;; every snippet made k diagnostics cost k passes over the file (#7895).
;;
;; Lines are the text between `\n` bytes, numbered from 1; a CR before the
;; newline stays part of its line. There is always one more line than there are
;; newlines, so the empty text has one empty line and a text ending in `\n` has
;; an empty last line.
(defstruct CompilerDiagnosticSource
  (text String)
  (line-starts (__tl_dyn-array i64))
  (lines i64))

(define (compiler-diagnostic-source-index [text : String]) : CompilerDiagnosticSource
  (let
    [n : i64 (string.string-length text)]
    [newlines : i64 0]
    [idx : i64 0]
    [_count : unit
      (while (< idx n)
        (if (= (string.string-ref text idx) '\n')
          (set! newlines (+ newlines 1))
          unit)
        (set! idx (+ idx 1)))]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ newlines 1))]
    [line : i64 1]
    (set! (array-ref starts 0) 0)
    (set! idx 0)
    (while (< idx n)
      (when
        (= (string.string-ref text idx) '\n')
        (set! (array-ref starts line) (+ idx 1))
        (set! line (+ line 1)))
      (set! idx (+ idx 1)))
    (CompilerDiagnosticSource text starts (+ newlines 1))))

(define (compiler-diagnostic-source-line
  [source : (& source CompilerDiagnosticSource)]
  [target-line : i64]) : CompilerDiagnosticMaybeString
  (if (or (< target-line 1) (> target-line source.lines))
    CompilerDiagnosticNoString
    (let
      [start : i64 (array-ref source.line-starts (- target-line 1))]
      [end : i64
        (if (< target-line source.lines)
          (- (array-ref source.line-starts target-line) 1)
          (string.string-length source.text))]
      (CompilerDiagnosticSomeString
        (string.substring source.text start (- end start))))))

(define (compiler-diagnostic-render-header
  [diag : (& diag CompilerDiagnostic)]
  [level : CompilerDiagnosticLevel]
  [code : (& CompilerDiagnosticMaybeString)]) : String
  (let
    [level-text : String (compiler-diagnostic-level-render level)]
    (match (owned_view.compiler-owned-reference-shared-view code)
      [(CompilerDiagnosticSomeString code-text)
        (str_cat.str-cat
          level-text
          "["
          code-text
          "]: "
          (compiler-diagnostic-message diag)
          "\n")]
      [CompilerDiagnosticNoString
        (str_cat.str-cat
          level-text
          ": "
          (str_cat.str-cat (compiler-diagnostic-message diag) "\n"))])))

(define (compiler-diagnostic-render-span-location-with-fallback
  [fallback-path : String]
  [span : CompilerDiagnosticSpan]) : String
  (let
    [path : String (compiler-diagnostic-span-path span)]
    [display-path : String
      (if (string.eq path "")
        fallback-path
        path)]
    (str_cat.str-cat
      "  --> "
      display-path
      ":"
      (string.int->string (compiler-diagnostic-span-start-line span))
      ":"
      (string.int->string (compiler-diagnostic-span-start-col span))
      "\n")))

(define (compiler-diagnostic-render-span-location
  [span : (& CompilerDiagnosticSpan)]) : String
  (compiler-diagnostic-render-span-location-with-fallback
    ""
    (owned_view.compiler-owned-reference-shared-view span)))

(define (compiler-diagnostic-render-location
  [diag : (& diag CompilerDiagnostic)]) : String
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-primary-span diag)]
    (compiler-diagnostic-render-span-location (& span))))

(define (compiler-diagnostic-render-label-suffix
  [label : (& CompilerDiagnosticMaybeString)]) : String
  (match (owned_view.compiler-owned-reference-shared-view label)
    [(CompilerDiagnosticSomeString text) (str_cat.str-cat " " text)]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source-snippet
  [span : (& span CompilerDiagnosticSpan)]
  [source : (& source CompilerDiagnosticSource)]
  [label-suffix : (& label-suffix str)]) : String
  (match (compiler-diagnostic-source-line
    source
    (compiler-diagnostic-span-start-line span))
    [(CompilerDiagnosticSomeString line-text)
      (let
        [line : i64 (compiler-diagnostic-span-start-line span)]
        [gutter : String (compiler-diagnostic-line-gutter line)]
        [blank : String (compiler-diagnostic-blank-gutter line)]
        [padding : String
          (compiler-diagnostic-repeat
            " "
            (compiler-diagnostic-column-padding
              (compiler-diagnostic-span-start-col span)))]
        [underline : String
          (compiler-diagnostic-repeat "^" (compiler-diagnostic-span-width span))]
        (str_cat.str-cat
          (str_cat.str-cat gutter " | " (str_cat.str-cat line-text "\n"))
          (str_cat.str-cat
            blank
            " | "
            padding
            underline
            (string.copy label-suffix)
            "\n")))]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-secondary-label-only
  [label : (& CompilerDiagnosticMaybeString)]) : String
  (match (owned_view.compiler-owned-reference-shared-view label)
    [(CompilerDiagnosticSomeString text)
      (str_cat.str-cat "   = label: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-secondary-span
  [primary-path : (& primary-path str)]
  [source : (& source CompilerDiagnosticSource)]
  [entry : CompilerDiagnosticLabel]) : String
  (let
    [span : CompilerDiagnosticSpan entry.span]
    [label : CompilerDiagnosticMaybeString entry.label]
    [path : String (compiler-diagnostic-span-path span)]
    [same-path : bool
      (if (string.eq path "")
        true
        (string.eq path primary-path))]
    [label-suffix : String (compiler-diagnostic-render-label-suffix (& label))]
    [label-only : String
      (compiler-diagnostic-render-secondary-label-only (& label))]
    [snippet : String
      (compiler-diagnostic-render-source-snippet span source (& label-suffix))]
    (str_cat.str-cat
      (compiler-diagnostic-render-span-location-with-fallback
        (string.copy primary-path)
        span)
      "   |\n"
      (if same-path
        (if (string.eq snippet "")
          (string.copy label-only)
          (string.copy snippet))
        (string.copy label-only))
      ""
      "")))

(define (compiler-diagnostic-render-secondary-spans
  [primary-path : (& str)]
  [source : (& source CompilerDiagnosticSource)]
  [labels : (& CompilerDiagnosticLabelList)]) : String
  (let
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< index count)
      (text_buf.append!
        out
        (compiler-diagnostic-render-secondary-span
          primary-path
          source
          (compiler-diagnostic-label-list-get labels index)))
      (set! index (+ index 1)))
    (text_buf.render out)))

(define (compiler-diagnostic-render-help
  [help : (& CompilerDiagnosticMaybeString)]) : String
  (match (owned_view.compiler-owned-reference-shared-view help)
    [(CompilerDiagnosticSomeString text)
      (str_cat.str-cat "   = help: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source-notes
  [notes : (& CompilerDiagnosticNoteList)]) : String
  (let
    [count : i64 (compiler-diagnostic-note-list-count notes)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< index count)
      (text_buf.append! out "   = note: ")
      (text_buf.append! out (compiler-diagnostic-note-list-get notes index))
      (text_buf.append! out "\n")
      (set! index (+ index 1)))
    (text_buf.render out)))

(define (compiler-diagnostic-render-source-with-metadata
  [diag : (& diag CompilerDiagnostic)]
  [source : (& source CompilerDiagnosticSource)]
  [level : CompilerDiagnosticLevel]
  [code : (& CompilerDiagnosticMaybeString)]
  [help : (& CompilerDiagnosticMaybeString)]) : String
  (let
    [primary-span : CompilerDiagnosticSpan
      (compiler-diagnostic-primary-span diag)]
    [empty-label : String ""]
    (str_cat.str-cat
      (compiler-diagnostic-render-header diag level code)
      (compiler-diagnostic-render-location diag)
      "   |\n"
      (compiler-diagnostic-render-source-snippet
        primary-span
        source
        (& empty-label))
      (compiler-diagnostic-render-secondary-spans
        (& (compiler-diagnostic-path diag))
        source
        (& (compiler-diagnostic-secondary-spans diag)))
      (compiler-diagnostic-render-help help)
      (compiler-diagnostic-render-source-notes
        (& (compiler-diagnostic-notes diag))))))

(define (compiler-diagnostic-render-source
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (let
    [indexed : CompilerDiagnosticSource
      (compiler-diagnostic-source-index source)]
    (compiler-diagnostic-render-indexed-source (& diag) (& indexed))))

;; `compiler-diagnostic-render-source` against a source already indexed, for
;; callers rendering several diagnostics against one text.
(define (compiler-diagnostic-render-indexed-source
  [diag : (& CompilerDiagnostic)]
  [source : (& source CompilerDiagnosticSource)]) : String
  (compiler-diagnostic-render-source-with-metadata
    diag
    source
    (compiler-diagnostic-level diag)
    (& (compiler-diagnostic-code diag))
    (& (compiler-diagnostic-help diag))))