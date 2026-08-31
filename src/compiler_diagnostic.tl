;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import stdlib.str_cat_runtime as str_cat)
(import token)
(import compiler_ast_types as ast)
(import stdlib.string)
(import stdlib.text_buf)

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
    (begin
      (set! (array-ref diagnostics.slots 0) diag)
      (set! diagnostics.len 1)
      diagnostics)))

(define (compiler-diagnostic-list-box-single [diag : (Box CompilerDiagnostic)]) : (Box
    CompilerDiagnosticList)
  (box (compiler-diagnostic-list-single (deref diag))))

(define (compiler-diagnostic-list-count [diagnostics : CompilerDiagnosticList]) : i64
  diagnostics.len)

(define (compiler-diagnostic-list-get
  [diagnostics : CompilerDiagnosticList]
  [index : i64]) : CompilerDiagnostic
  (array-ref diagnostics.slots index))

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
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

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
    (begin
      (compiler-diagnostic-list-copy-range!
        (&mut new-slots)
        (& diagnostics.slots)
        count)
      (set! diagnostics.slots new-slots))))

(define (compiler-diagnostic-list-push!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [diag : CompilerDiagnostic]) : unit
  (begin
    (if (< diagnostics.len (array-length diagnostics.slots))
      unit
      (compiler-diagnostic-list-grow! diagnostics))
    (let
      [index : i64 diagnostics.len]
      (begin
        (set! (array-ref diagnostics.slots index) diag)
        (set! diagnostics.len (+ index 1))))))

(define (compiler-diagnostic-list-insert!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [index : i64]
  [diag : CompilerDiagnostic]) : unit
  (let
    [count : i64 diagnostics.len]
    (begin
      (if (< count (array-length diagnostics.slots))
        unit
        (compiler-diagnostic-list-grow! diagnostics))
      (let
        [cursor : i64 count]
        (begin
          (while (> cursor index)
            (begin
              (set!
                (array-ref diagnostics.slots cursor)
                (array-ref diagnostics.slots (- cursor 1)))
              (set! cursor (- cursor 1))))
          (set! (array-ref diagnostics.slots index) diag)
          (set! diagnostics.len (+ count 1)))))))

(define (compiler-diagnostic-list-first [diagnostics : CompilerDiagnosticList]) : CompilerDiagnostic
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
;; Why these are derived from the message rather than set where the error is
;; raised: a typecheck error travels as `ResultTcType.Err <String>`, so at the
;; raise site there is no diagnostic to attach a code to, and the kind is only
;; recoverable from the canonical message text. The classification therefore
;; happens at the single point where a typecheck error becomes a diagnostic
;; (`tc-canonical-diagnostic`). The cost of that is real: rewording a mapped
;; message silently drops it back to `E0200`, which is why every row in
;; `compiler-diagnostic-code-for-typecheck-message` is pinned by a self-test.
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

;; Machine-readable inventory for the public diagnostic surface. Keep this in
;; the module that assigns codes rather than in the `explain` frontend: tests
;; can then prove that every published code has exactly one registry row and a
;; detailed explanation. `owner` identifies the subsystem responsible for
;; keeping the classification and explanation current.
(define (compiler-diagnostic-code-registry-count) : i64
  20)

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
    [else ""]))

(define (compiler-diagnostic-code-registry-category [index : i64]) : String
  (cond
    [(= index 0) "parse"]
    [(and (> index 0) (< index (compiler-diagnostic-code-registry-count)))
      "typecheck"]
    [else ""]))

(define (compiler-diagnostic-code-registry-owner [index : i64]) : String
  (cond
    [(= index 0) "parser"]
    [(and (> index 0) (< index (compiler-diagnostic-code-registry-count)))
      "typechecker"]
    [else ""]))

;; Ordered, first match wins. `arity mismatch` is tested before `type mismatch`
;; so a call-arity error is not absorbed by the broader mismatch rule if the two
;; phrasings ever overlap.
(define (compiler-diagnostic-code-for-typecheck-message [message : String]) : String
  (cond
    [(string.contains (& message) "arity mismatch")
      (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(and
        (string.contains (& message) "expected ")
        (string.contains (& message) " arguments"))
      (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(string.contains (& message) "unbound name")
      (compiler-diagnostic-code-typecheck-unbound-name)]
    [(string.contains (& message) "unknown type")
      (compiler-diagnostic-code-typecheck-unbound-name)]
    [(string.contains (& message) "type not found")
      (compiler-diagnostic-code-typecheck-unbound-name)]
    ;; Both spellings are live in the typechecker: `match missing arm for ...`
    ;; is what the exhaustiveness check emits per missing variant, while
    ;; `non-exhaustive match` is used by the scalar/wildcard path. They are one
    ;; kind to a user, so they share a code.
    [(string.contains (& message) "match missing arm")
      (compiler-diagnostic-code-typecheck-non-exhaustive-match)]
    [(string.contains (& message) "non-exhaustive match")
      (compiler-diagnostic-code-typecheck-non-exhaustive-match)]
    [(string.contains (& message) "unknown struct field")
      (compiler-diagnostic-code-typecheck-unknown-struct-field)]
    [(string.contains (& message) "requires unsafe context")
      (compiler-diagnostic-code-typecheck-unsafe-context)]
    [(or
        (string.contains (& message) "cannot cross thread boundaries")
        (string.contains (& message) "thread_i64.spawn")
        (string.contains (& message) "cannot send value of type"))
      (compiler-diagnostic-code-typecheck-thread-safety)]
    [(or
        (string.contains (& message) "SPMD")
        (string.contains (& message) "spmd-")
        (string.contains (& message) "foreach")
        (string.contains (& message) "varying arguments"))
      (compiler-diagnostic-code-typecheck-spmd)]
    [(or
        (string.contains (& message) "pattern only supports")
        (string.contains (& message) "pattern requires")
        (string.contains (& message) "match requires")
        (string.contains (& message) "unreachable match arm"))
      (compiler-diagnostic-code-typecheck-pattern)]
    [(or
        (string.contains (& message) "expression is not a storage place")
        (string.contains (& message) "target must be a storage place")
        (string.contains
          (& message)
          "receiver must be a fixed-array storage place")
        (string.contains (& message) "requires owned fixed-array storage")
        (string.contains (& message) "numeric field segments")
        (string.contains
          (& message)
          "comptime replace! requires a mutable local"))
      (compiler-diagnostic-code-typecheck-place)]
    [(or
        (string.contains (& message) "break requires enclosing")
        (string.contains (& message) "continue requires enclosing"))
      (compiler-diagnostic-code-typecheck-control-flow)]
    [(or
        (string.contains (& message) "non-negative compile-time integer")
        (string.contains (& message) "compile-time only"))
      (compiler-diagnostic-code-typecheck-comptime-constraint)]
    ;; Cleanup resources have ownership semantics even when the concrete
    ;; failure is an attempted escape, so keep them out of the region family.
    [(string.contains (& message) "cleanup")
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    ;; Escape classification precedes borrow classification because some
    ;; aggregate escape diagnostics mention a borrow in their suggested fix.
    [(string.contains (& message) "cannot escape")
      (compiler-diagnostic-code-typecheck-region-escape)]
    [(string.contains (& message) "would escape")
      (compiler-diagnostic-code-typecheck-region-escape)]
    [(string.contains (& message) "escape lexical scope")
      (compiler-diagnostic-code-typecheck-region-escape)]
    ;; Lifetime failures frequently append their cause to a generic `type
    ;; mismatch` prefix. Test them first so the actionable lifetime code wins.
    [(string.contains (& message) "lifetime mismatch")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "does not outlive")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "reference lifetime")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "lifetime is only allowed")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "lifetime must be tied")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "elided reference")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "not outlive")
      (compiler-diagnostic-code-typecheck-lifetime-mismatch)]
    [(string.contains (& message) "borrow requires")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "borrow borrowed place")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "borrow mutably borrowed place")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "read mutably borrowed place")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "assign to borrowed place")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "move borrowed place")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "borrowed byte-slice referent")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "borrowed string-slice referent")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "mutable borrow")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "requires mutable")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "requires a mutable borrowed")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "borrowed box pattern")
      (compiler-diagnostic-code-typecheck-borrow-violation)]
    [(string.contains (& message) "direct arena owner")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "arena owner")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "ordinary arena")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "owner proof")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "atomic arena")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "arena must be Arena")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "inside the arena it")
      (compiler-diagnostic-code-typecheck-arena-ownership)]
    [(string.contains (& message) "owner-consuming")
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(string.contains (& message) "owner value")
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(string.contains (& message) "ownership would be erased")
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(string.contains (& message) "capability would be erased")
      (compiler-diagnostic-code-typecheck-resource-ownership)]
    [(string.contains (& message) "use of moved value")
      (compiler-diagnostic-code-typecheck-move-violation)]
    [(string.contains (& message) "cannot move out of global")
      (compiler-diagnostic-code-typecheck-move-violation)]
    [(string.contains (& message) "cannot move non-Copy")
      (compiler-diagnostic-code-typecheck-move-violation)]
    [(string.contains (& message) "noncopy move")
      (compiler-diagnostic-code-typecheck-move-violation)]
    [(string.contains (& message) "expects exactly one")
      (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(string.contains (& message) "expects a type argument")
      (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(string.contains (& message) "type mismatch")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "branches must match")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(and
        (string.contains (& message) "expected ")
        (string.contains (& message) "found "))
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "does not fit expected type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "expects matching integer")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "requires numeric types")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "cast requires scalar numeric")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "requires Box or reference type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "requires fixed array type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "requires Box scrutinee")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "source must be")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "must have type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "type is not supported")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "unsupported type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "bare Slice type")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "type value")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "does not match struct")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "non-finite f")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "extern/native Slice references")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "result type is not clone-supported")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(and
        (string.contains (& message) "field projection")
        (string.contains (& message) "requires struct, got"))
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [else (compiler-diagnostic-code-typecheck)]))

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

(define (compiler-diagnostic-new
  [message : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [category : CompilerDiagnosticMaybeString]
  [primary : CompilerDiagnosticSpan]
  [help : CompilerDiagnosticMaybeString]
  [secondary : CompilerDiagnosticLabelList]
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnostic
  (CompilerDiagnostic
    message
    level
    code
    category
    primary
    help
    secondary
    notes
    (CompilerDiagnosticFixSeq (__tl_make-array CompilerDiagnosticFix 0) 0)))

(define (compiler-diagnostic-copy-maybe-string
  [value : CompilerDiagnosticMaybeString]) : CompilerDiagnosticMaybeString
  (match value
    [CompilerDiagnosticNoString CompilerDiagnosticNoString]
    [(CompilerDiagnosticSomeString text)
      (CompilerDiagnosticSomeString (string.copy (& text)))]))

(define (compiler-diagnostic-copy-maybe-string-ref
  [value : (& value CompilerDiagnosticMaybeString)]) : CompilerDiagnosticMaybeString
  (match value
    [CompilerDiagnosticNoString CompilerDiagnosticNoString]
    [(CompilerDiagnosticSomeString text)
      (CompilerDiagnosticSomeString (string.copy (& text)))]))

(define (compiler-diagnostic-copy-span [span : CompilerDiagnosticSpan]) : CompilerDiagnosticSpan
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
    (begin
      (set! (array-ref dst 0) label)
      (while (< index count)
        (begin
          (set! (array-ref dst (+ index 1)) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticLabelList dst (+ count 1)))))

(define (compiler-diagnostic-copy-label-list
  [labels : CompilerDiagnosticLabelList]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [src : (__tl_dyn-array CompilerDiagnosticLabel) labels.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [label : CompilerDiagnosticLabel
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data src) index)))]
          (begin
            (set!
              (array-ref dst index)
              (CompilerDiagnosticLabel
                (compiler-diagnostic-copy-span label.span)
                (compiler-diagnostic-copy-maybe-string label.label)))
            (set! index (+ index 1)))))
      (CompilerDiagnosticLabelList dst count))))

(define (compiler-diagnostic-copy-label-list-ref
  [labels : (& labels CompilerDiagnosticLabelList)]) : CompilerDiagnosticLabelList
  (let
    [count : i64 labels.len]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (__tl_make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [label : CompilerDiagnosticLabel
            (compiler-diagnostic-label-list-get labels index)]
          (begin
            (set!
              (array-ref dst index)
              (CompilerDiagnosticLabel
                (compiler-diagnostic-copy-span-ref (& label.span))
                (compiler-diagnostic-copy-maybe-string-ref (& label.label))))
            (set! index (+ index 1)))))
      (CompilerDiagnosticLabelList dst count))))

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
    (begin
      (set! (array-ref dst 0) note)
      (while (< index count)
        (begin
          (set! (array-ref dst (+ index 1)) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticNoteList dst (+ count 1)))))

(define (compiler-diagnostic-copy-note-list
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnosticNoteList
  (let
    [count : i64 notes.len]
    [src : (__tl_dyn-array String) notes.slots]
    [dst : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref dst index) (string.copy (& (array-ref src index))))
          (set! index (+ index 1))))
      (CompilerDiagnosticNoteList dst count))))

(define (compiler-diagnostic-copy-note-list-ref
  [notes : (& notes CompilerDiagnosticNoteList)]) : CompilerDiagnosticNoteList
  (let
    [count : i64 notes.len]
    [dst : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [note : String (compiler-diagnostic-note-list-get notes index)]
          (begin
            (set! (array-ref dst index) (string.copy (& note)))
            (set! index (+ index 1)))))
      (CompilerDiagnosticNoteList dst count))))

(define (compiler-diagnostic-copy-text-edit [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit
    (compiler-diagnostic-copy-span edit.span)
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
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref dst index)
            (compiler-diagnostic-copy-text-edit
              (unsafe
                (ptr-read (ptr-offset (__tl_array-data src) index)))))
          (set! index (+ index 1))))
      (CompilerDiagnosticTextEditSeq dst count))))

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
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref dst index)
            (compiler-diagnostic-copy-fix
              (unsafe
                (ptr-read (ptr-offset (__tl_array-data src) index)))))
          (set! index (+ index 1))))
      (CompilerDiagnosticFixSeq dst count))))

(define (compiler-diagnostic-copy-fix-list-ref
  [fixes : (& fixes CompilerDiagnosticFixSeq)]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [fix : CompilerDiagnosticFix
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data fixes.slots) index)))]
          (begin
            (set! (array-ref dst index) (compiler-diagnostic-copy-fix fix))
            (set! index (+ index 1)))))
      (CompilerDiagnosticFixSeq dst count))))

(define (compiler-diagnostic-copy [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (CompilerDiagnostic
    (string.copy (& diag.message))
    diag.level
    (compiler-diagnostic-copy-maybe-string diag.code)
    (compiler-diagnostic-copy-maybe-string diag.category)
    (compiler-diagnostic-copy-span diag.primary)
    (compiler-diagnostic-copy-maybe-string diag.help)
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
  [span : CompilerDiagnosticSpan]) : bool
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

;; Scans the suffix after `start`, matching the old cons walk over the tail.
(define (compiler-diagnostic-edit-overlaps-rest?
  [diagnostic-path : String]
  [edit : CompilerDiagnosticTextEdit]
  [slots : (& slots (__tl_dyn-array CompilerDiagnosticTextEdit))]
  [count : i64]
  [start : i64]) : bool
  (let
    [cursor : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (< cursor count))
        (begin
          (if (compiler-diagnostic-edit-overlaps?
            (compiler-diagnostic-place-shared-view diagnostic-path)
            (compiler-diagnostic-place-shared-view edit)
            (compiler-diagnostic-copy-text-edit-ref
              (& (array-ref slots cursor))))
            (set! found true)
            unit)
          (set! cursor (+ cursor 1))))
      found)))

(define (compiler-diagnostic-edit-list-valid?
  [diagnostic-path : String]
  [edits : CompilerDiagnosticTextEditSeq]) : bool
  (let
    [count : i64 edits.len]
    [slots : (__tl_dyn-array CompilerDiagnosticTextEdit) edits.slots]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [edit : CompilerDiagnosticTextEdit
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data slots) index)))]
          (begin
            (if (and
              (compiler-diagnostic-span-valid-for-edit?
                (compiler-diagnostic-place-shared-view edit.span))
              (not
                (compiler-diagnostic-edit-overlaps-rest?
                  (compiler-diagnostic-place-shared-view diagnostic-path)
                  edit
                  (& slots)
                  count
                  (+ index 1))))
              unit
              (set! ok false))
            (set! index (+ index 1)))))
      ok)))

(define (compiler-diagnostic-fix-valid?
  [diagnostic-path : String]
  [fix : CompilerDiagnosticFix]) : bool
  (let
    [edits : CompilerDiagnosticTextEditSeq fix.edits]
    (and
      (> (string.string-length fix.title) 0)
      (> edits.len 0)
      (compiler-diagnostic-edit-list-valid? diagnostic-path edits))))

(define (compiler-diagnostic-repath-text-edit
  [edit : CompilerDiagnosticTextEdit]
  [path : (& path str)]) : CompilerDiagnosticTextEdit
  (let
    [span : CompilerDiagnosticSpan edit.span]
    [edit-path : String (compiler-diagnostic-span-path span)]
    (CompilerDiagnosticTextEdit
      (if (string.eq edit-path "")
        (CompilerDiagnosticSpan
          (string.copy path)
          (compiler-diagnostic-span-start-line span)
          (compiler-diagnostic-span-start-col span)
          (compiler-diagnostic-span-end-line span)
          (compiler-diagnostic-span-end-col span))
        span)
      edit.replacement)))

(define (compiler-diagnostic-repath-text-edit-list
  [edits : CompilerDiagnosticTextEditSeq]
  [path : (& path str)]) : CompilerDiagnosticTextEditSeq
  (let
    [count : i64 edits.len]
    [src : (__tl_dyn-array CompilerDiagnosticTextEdit) edits.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (__tl_make-array CompilerDiagnosticTextEdit count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref dst index)
            (compiler-diagnostic-repath-text-edit
              (unsafe
                (ptr-read (ptr-offset (__tl_array-data src) index)))
              path))
          (set! index (+ index 1))))
      (CompilerDiagnosticTextEditSeq dst count))))

(define (compiler-diagnostic-repath-fix-list
  [fixes : CompilerDiagnosticFixSeq]
  [path : (& path str)]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 fixes.len]
    [src : (__tl_dyn-array CompilerDiagnosticFix) fixes.slots]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (__tl_make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [fix : CompilerDiagnosticFix
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data src) index)))]
          (begin
            (set!
              (array-ref dst index)
              (CompilerDiagnosticFix
                fix.title
                fix.applicability
                (compiler-diagnostic-repath-text-edit-list fix.edits path)))
            (set! index (+ index 1)))))
      (CompilerDiagnosticFixSeq dst count))))

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
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (CompilerDiagnosticSpan
      (string.copy (& path))
      (compiler-diagnostic-line diag)
      (compiler-diagnostic-col diag)
      (compiler-diagnostic-end-line diag)
      (compiler-diagnostic-end-col diag))
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-repath-fix-list (compiler-diagnostic-fixes diag) path)))

(define (compiler-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (and
    (not (string.eq path ""))
    (string.eq (compiler-diagnostic-path diag) ""))
    (compiler-diagnostic-with-path diag path)
    diag))

(define (compiler-diagnostic-with-level
  [diag : CompilerDiagnostic]
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
  [diag : CompilerDiagnostic]
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
  [diag : CompilerDiagnostic]
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
  [diag : CompilerDiagnostic]
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
  [diag : CompilerDiagnostic]
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
  [left : CompilerDiagnosticMaybeString]
  [right : CompilerDiagnosticMaybeString]) : bool
  (match left
    [CompilerDiagnosticNoString
      (match right
        [CompilerDiagnosticNoString true]
        [(CompilerDiagnosticSomeString _) false])]
    [(CompilerDiagnosticSomeString left-text)
      (match right
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
  [diag : CompilerDiagnostic]
  [span : CompilerDiagnosticSpan]
  [label : CompilerDiagnosticMaybeString]) : bool
  (let
    [labels : CompilerDiagnosticLabelList
      (compiler-diagnostic-secondary-spans diag)]
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (let
          [entry : CompilerDiagnosticLabel
            (compiler-diagnostic-label-list-get labels index)]
          [entry-span : CompilerDiagnosticSpan entry.span]
          (begin
            (if (and
              (compiler-diagnostic-span-eq? (& entry-span) (& span))
              (compiler-diagnostic-maybe-string-eq?
                entry.label
                (compiler-diagnostic-place-shared-view label)))
              (set! found true)
              unit)
            (set! index (+ index 1)))))
      found)))

(define (compiler-diagnostic-with-secondary-if-new
  [diag : CompilerDiagnostic]
  [span : CompilerDiagnosticSpan]
  [label : CompilerDiagnosticMaybeString]) : CompilerDiagnostic
  (if (compiler-diagnostic-secondary-present?
    (compiler-diagnostic-place-shared-view diag)
    (compiler-diagnostic-place-shared-view span)
    (compiler-diagnostic-place-shared-view label))
    diag
    (compiler-diagnostic-with-secondary diag span label)))

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
  [diag : CompilerDiagnostic]
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
  [diag : CompilerDiagnostic]
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
    (begin
      (set! (array-ref slots 0) edit)
      (CompilerDiagnosticTextEditSeq slots 1))))

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
    (begin
      (set! (array-ref dst 0) fix)
      (while (< index count)
        (begin
          (set! (array-ref dst (+ index 1)) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticFixSeq dst (+ count 1)))))

;; Fix attachment is the validation boundary: generated/unknown 0:0 spans,
;; reversed spans, empty edit sets, and overlapping half-open edits are not
;; admitted to the diagnostic. Empty paths inherit the primary source path.
(define (compiler-diagnostic-with-fix
  [diag : CompilerDiagnostic]
  [fix : CompilerDiagnosticFix]) : CompilerDiagnostic
  (if (compiler-diagnostic-fix-valid?
    (compiler-diagnostic-path diag)
    (compiler-diagnostic-place-shared-view fix))
    (CompilerDiagnostic
      (compiler-diagnostic-message diag)
      (compiler-diagnostic-level diag)
      (compiler-diagnostic-code diag)
      (compiler-diagnostic-category diag)
      (compiler-diagnostic-primary-span diag)
      (compiler-diagnostic-help diag)
      (compiler-diagnostic-secondary-spans diag)
      (compiler-diagnostic-notes diag)
      (compiler-diagnostic-fix-prepend fix (compiler-diagnostic-fixes diag)))
    diag))

(define (compiler-diagnostic-render-notes [notes : CompilerDiagnosticNoteList]) : String
  (let
    [count : i64 (compiler-diagnostic-note-list-count notes)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (begin
      (while (< index count)
        (begin
          (text_buf.append! out "\nnote: ")
          (text_buf.append! out (compiler-diagnostic-note-list-get notes index))
          (set! index (+ index 1))))
      (text_buf.render out))))

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
  [labels : CompilerDiagnosticLabelList]) : String
  (let
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (begin
      (while (< index count)
        (begin
          (text_buf.append!
            out
            (compiler-diagnostic-render-flat-secondary
              (compiler-diagnostic-place-shared-view primary-path)
              (compiler-diagnostic-label-list-get labels index)))
          (set! index (+ index 1))))
      (text_buf.render out))))

(define (compiler-diagnostic-render [diag : CompilerDiagnostic]) : String
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
      (compiler-diagnostic-secondary-spans diag))
    (compiler-diagnostic-render-notes (compiler-diagnostic-notes diag))))

(define (compiler-diagnostic-level-render [level : CompilerDiagnosticLevel]) : String
  (match level
    [(CompilerDiagnosticError) "error"]
    [(CompilerDiagnosticWarning) "warning"]
    [(CompilerDiagnosticNote) "note"]))

(define (compiler-diagnostic-repeat [chunk : String] [count : i64]) : String
  (let
    [idx : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (begin
      (while (< idx count)
        (begin
          (text_buf.append! out (string.copy chunk))
          (set! idx (+ idx 1))))
      (text_buf.render out))))

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

(define (compiler-diagnostic-span-width [span : CompilerDiagnosticSpan]) : i64
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

(define (compiler-diagnostic-source-line
  [source : (& source str)]
  [target-line : i64]) : CompilerDiagnosticMaybeString
  (if (< target-line 1)
    CompilerDiagnosticNoString
    (let
      [idx : i64 0]
      [n : i64 (string.string-length source)]
      [line : i64 1]
      [start : i64 0]
      [done : bool false]
      [out : String ""]
      (begin
        (while (if (< idx n)
          (not done)
          false)
          (begin
            (if (= line target-line)
              (if (= (string.string-ref source idx) '\n')
                (begin
                  (set! out (string.substring source start (- idx start)))
                  (set! done true))
                unit)
              unit)
            (if (and (not done) (= (string.string-ref source idx) '\n'))
              (begin
                (set! line (+ line 1))
                (set! start (+ idx 1)))
              unit)
            (set! idx (+ idx 1))))
        (if done
          (CompilerDiagnosticSomeString out)
          (if (= line target-line)
            (CompilerDiagnosticSomeString
              (string.substring source start (- n start)))
            CompilerDiagnosticNoString))))))

(define (compiler-diagnostic-render-header
  [diag : CompilerDiagnostic]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]) : String
  (let
    [level-text : String (compiler-diagnostic-level-render level)]
    (match code
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
  [span : CompilerDiagnosticSpan]) : String
  (compiler-diagnostic-render-span-location-with-fallback "" span))

(define (compiler-diagnostic-render-location [diag : CompilerDiagnostic]) : String
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-primary-span diag)]
    (compiler-diagnostic-render-span-location span)))

(define (compiler-diagnostic-render-label-suffix
  [label : CompilerDiagnosticMaybeString]) : String
  (match label
    [(CompilerDiagnosticSomeString text) (str_cat.str-cat " " text)]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source-snippet
  [span : CompilerDiagnosticSpan]
  [source : (& source str)]
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
  [label : CompilerDiagnosticMaybeString]) : String
  (match label
    [(CompilerDiagnosticSomeString text)
      (str_cat.str-cat "   = label: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-secondary-span
  [primary-path : String]
  [source : String]
  [entry : CompilerDiagnosticLabel]) : String
  (let
    [span : CompilerDiagnosticSpan entry.span]
    [label : CompilerDiagnosticMaybeString entry.label]
    [path : String (compiler-diagnostic-span-path span)]
    [same-path : bool
      (if (string.eq path "")
        true
        (string.eq path primary-path))]
    [label-suffix : String
      (compiler-diagnostic-render-label-suffix
        (compiler-diagnostic-place-shared-view label))]
    [label-only : String
      (compiler-diagnostic-render-secondary-label-only label)]
    [snippet : String
      (compiler-diagnostic-render-source-snippet
        (compiler-diagnostic-place-shared-view span)
        (& source)
        (& label-suffix))]
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
  [primary-path : String]
  [source : String]
  [labels : CompilerDiagnosticLabelList]) : String
  (let
    [count : i64 (compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (begin
      (while (< index count)
        (begin
          (text_buf.append!
            out
            (compiler-diagnostic-render-secondary-span
              (compiler-diagnostic-place-shared-view primary-path)
              (compiler-diagnostic-place-shared-view source)
              (compiler-diagnostic-label-list-get labels index)))
          (set! index (+ index 1))))
      (text_buf.render out))))

(define (compiler-diagnostic-render-help [help : CompilerDiagnosticMaybeString]) : String
  (match help
    [(CompilerDiagnosticSomeString text)
      (str_cat.str-cat "   = help: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source-notes
  [notes : CompilerDiagnosticNoteList]) : String
  (let
    [count : i64 (compiler-diagnostic-note-list-count notes)]
    [index : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (begin
      (while (< index count)
        (begin
          (text_buf.append! out "   = note: ")
          (text_buf.append! out (compiler-diagnostic-note-list-get notes index))
          (text_buf.append! out "\n")
          (set! index (+ index 1))))
      (text_buf.render out))))

(define (compiler-diagnostic-render-source-with-metadata
  [diag : CompilerDiagnostic]
  [source : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [help : CompilerDiagnosticMaybeString]) : String
  (let
    [primary-span : CompilerDiagnosticSpan
      (compiler-diagnostic-primary-span diag)]
    [empty-label : String ""]
    (str_cat.str-cat
      (compiler-diagnostic-render-header
        (compiler-diagnostic-place-shared-view diag)
        level
        code)
      (compiler-diagnostic-render-location
        (compiler-diagnostic-place-shared-view diag))
      "   |\n"
      (compiler-diagnostic-render-source-snippet
        primary-span
        (& source)
        (& empty-label))
      (compiler-diagnostic-render-secondary-spans
        (compiler-diagnostic-path diag)
        (compiler-diagnostic-place-shared-view source)
        (compiler-diagnostic-secondary-spans diag))
      (compiler-diagnostic-render-help help)
      (compiler-diagnostic-render-source-notes (compiler-diagnostic-notes diag)))))

(define (compiler-diagnostic-render-source
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (compiler-diagnostic-render-source-with-metadata
    (compiler-diagnostic-place-shared-view diag)
    source
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-help diag)))