;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import stdlib.str_cat_runtime as str_cat)
(import token)
(import compiler_ast_types as ast)
(import stdlib.string)
(import stdlib.text_buf)

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

(defstruct CompilerDiagnosticList
  (slots (__tl_dyn-array CompilerDiagnostic))
  (len i64))

(define (compiler-diagnostic-list-with-capacity [capacity : i64]) : CompilerDiagnosticList
  (CompilerDiagnosticList (make-array CompilerDiagnostic capacity) 0))

(define (compiler-diagnostic-list-empty) : CompilerDiagnosticList
  (compiler-diagnostic-list-with-capacity 0))

(define (compiler-diagnostic-list-single [diag : CompilerDiagnostic]) : CompilerDiagnosticList
  (let
    [diagnostics : CompilerDiagnosticList
      (compiler-diagnostic-list-with-capacity 1)]
    (begin
      (array-set! (struct-get diagnostics slots) 0 diag)
      (set! (struct-get diagnostics len) 1)
      diagnostics)))

(define (compiler-diagnostic-list-box-single [diag : (Box CompilerDiagnostic)]) : (Box
    CompilerDiagnosticList)
  (box (compiler-diagnostic-list-single (box-get diag))))

(define (compiler-diagnostic-list-count [diagnostics : CompilerDiagnosticList]) : i64
  (struct-get diagnostics len))

(define (compiler-diagnostic-list-get
  [diagnostics : CompilerDiagnosticList]
  [index : i64]) : CompilerDiagnostic
  (array-ref (struct-get diagnostics slots) index))

(define (compiler-diagnostic-list-ref
  [diagnostics : (& diagnostics CompilerDiagnosticList)]
  [index : i64]) : (& diagnostics CompilerDiagnostic)
  (& (array-ref (struct-get diagnostics slots) index)))

(define (compiler-diagnostic-list-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerDiagnostic))]
  [src : (& src (__tl_dyn-array CompilerDiagnostic))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-diagnostic-list-grow!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]) : unit
  (let
    [count : i64 (struct-get diagnostics len)]
    [old-capacity : i64 (array-length (struct-get diagnostics slots))]
    [new-capacity : i64
      (if (< old-capacity 1)
        4
        (* old-capacity 2))]
    [new-slots : (__tl_dyn-array CompilerDiagnostic)
      (make-array CompilerDiagnostic new-capacity)]
    (begin
      (compiler-diagnostic-list-copy-range!
        (&mut new-slots)
        (& (struct-get diagnostics slots))
        count)
      (set! (struct-get diagnostics slots) new-slots))))

(define (compiler-diagnostic-list-push!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [diag : CompilerDiagnostic]) : unit
  (begin
    (if (<
      (struct-get diagnostics len)
      (array-length (struct-get diagnostics slots)))
      unit
      (compiler-diagnostic-list-grow! diagnostics))
    (let
      [index : i64 (struct-get diagnostics len)]
      (begin
        (array-set! (struct-get diagnostics slots) index diag)
        (set! (struct-get diagnostics len) (+ index 1))))))

(define (compiler-diagnostic-list-insert!
  [diagnostics : (&mut diagnostics CompilerDiagnosticList)]
  [index : i64]
  [diag : CompilerDiagnostic]) : unit
  (let
    [count : i64 (struct-get diagnostics len)]
    (begin
      (if (< count (array-length (struct-get diagnostics slots)))
        unit
        (compiler-diagnostic-list-grow! diagnostics))
      (let
        [cursor : i64 count]
        (begin
          (while (> cursor index)
            (begin
              (array-set!
                (struct-get diagnostics slots)
                cursor
                (array-ref (struct-get diagnostics slots) (- cursor 1)))
              (set! cursor (- cursor 1))))
          (array-set! (struct-get diagnostics slots) index diag)
          (set! (struct-get diagnostics len) (+ count 1)))))))

(define (compiler-diagnostic-list-first [diagnostics : CompilerDiagnosticList]) : CompilerDiagnostic
  (if (> (struct-get diagnostics len) 0)
    (array-ref (struct-get diagnostics slots) 0)
    (compiler-diagnostic-at-start "" "compiler: internal empty diagnostic list")))

(define (compiler-diagnostic-span-path [span : (& span CompilerDiagnosticSpan)]) : String
  (string.copy (& (struct-get span path))))

(define (compiler-diagnostic-span-start-line
  [span : (& span CompilerDiagnosticSpan)]) : i64
  (struct-get span start-line))

(define (compiler-diagnostic-span-start-col
  [span : (& span CompilerDiagnosticSpan)]) : i64
  (struct-get span start-col))

(define (compiler-diagnostic-span-end-line
  [span : (& span CompilerDiagnosticSpan)]) : i64
  (struct-get span end-line))

(define (compiler-diagnostic-span-end-col
  [span : (& span CompilerDiagnosticSpan)]) : i64
  (struct-get span end-col))

(define (compiler-diagnostic-path [diag : CompilerDiagnostic]) : String
  (let
    [primary : CompilerDiagnosticSpan (struct-get diag primary)]
    (compiler-diagnostic-span-path (& primary))))

(define (compiler-diagnostic-line [diag : CompilerDiagnostic]) : i64
  (let
    [primary : CompilerDiagnosticSpan (struct-get diag primary)]
    (compiler-diagnostic-span-start-line (& primary))))

(define (compiler-diagnostic-col [diag : CompilerDiagnostic]) : i64
  (let
    [primary : CompilerDiagnosticSpan (struct-get diag primary)]
    (compiler-diagnostic-span-start-col (& primary))))

(define (compiler-diagnostic-message [diag : CompilerDiagnostic]) : String
  (struct-get diag message))

(define (compiler-diagnostic-end-line [diag : CompilerDiagnostic]) : i64
  (let
    [primary : CompilerDiagnosticSpan (struct-get diag primary)]
    (compiler-diagnostic-span-end-line (& primary))))

(define (compiler-diagnostic-end-col [diag : CompilerDiagnostic]) : i64
  (let
    [primary : CompilerDiagnosticSpan (struct-get diag primary)]
    (compiler-diagnostic-span-end-col (& primary))))

(define (compiler-diagnostic-level [diag : CompilerDiagnostic]) : CompilerDiagnosticLevel
  (struct-get diag level))

(define (compiler-diagnostic-code [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag code))

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

;; Ordered, first match wins. `arity mismatch` is tested before `type mismatch`
;; so a call-arity error is not absorbed by the broader mismatch rule if the two
;; phrasings ever overlap.
(define (compiler-diagnostic-code-for-typecheck-message [message : String]) : String
  (cond
    [(string.contains (& message) "arity mismatch")
      (compiler-diagnostic-code-typecheck-arity-mismatch)]
    [(string.contains (& message) "type mismatch")
      (compiler-diagnostic-code-typecheck-type-mismatch)]
    [(string.contains (& message) "unbound name")
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
    [(string.contains (& message) "cannot escape")
      (compiler-diagnostic-code-typecheck-region-escape)]
    [else (compiler-diagnostic-code-typecheck)]))

(define (compiler-diagnostic-code-or-empty [diag : CompilerDiagnostic]) : String
  (match (compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code) code]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-category [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag category))

(define (compiler-diagnostic-help [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag help))

(define (compiler-diagnostic-secondary-spans [diag : CompilerDiagnostic]) : CompilerDiagnosticLabelList
  (struct-get diag secondary))

(define (compiler-diagnostic-notes [diag : CompilerDiagnostic]) : CompilerDiagnosticNoteList
  (struct-get diag notes))

(define (compiler-diagnostic-fixes [diag : CompilerDiagnostic]) : CompilerDiagnosticFixSeq
  (struct-get diag fixes))

(define (compiler-diagnostic-primary-span [diag : CompilerDiagnostic]) : CompilerDiagnosticSpan
  (struct-get diag primary))

(define (compiler-diagnostic-text-edit-span [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticSpan
  (struct-get edit span))

(define (compiler-diagnostic-text-edit-replacement
  [edit : CompilerDiagnosticTextEdit]) : String
  (struct-get edit replacement))

(define (compiler-diagnostic-fix-title [fix : CompilerDiagnosticFix]) : String
  (struct-get fix title))

(define (compiler-diagnostic-fix-applicability [fix : CompilerDiagnosticFix]) : CompilerDiagnosticApplicability
  (struct-get fix applicability))

(define (compiler-diagnostic-fix-edits [fix : CompilerDiagnosticFix]) : CompilerDiagnosticTextEditSeq
  (struct-get fix edits))

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
    (CompilerDiagnosticFixSeq (make-array CompilerDiagnosticFix 0) 0)))

(define (compiler-diagnostic-copy-maybe-string
  [value : CompilerDiagnosticMaybeString]) : CompilerDiagnosticMaybeString
  (match value
    [CompilerDiagnosticNoString CompilerDiagnosticNoString]
    [(CompilerDiagnosticSomeString text)
      (CompilerDiagnosticSomeString (string.copy (& text)))]))

(define (compiler-diagnostic-copy-span [span : CompilerDiagnosticSpan]) : CompilerDiagnosticSpan
  (CompilerDiagnosticSpan
    (string.copy (& (struct-get span path)))
    (struct-get span start-line)
    (struct-get span start-col)
    (struct-get span end-line)
    (struct-get span end-col)))

(define (compiler-diagnostic-label-list-empty) : CompilerDiagnosticLabelList
  (CompilerDiagnosticLabelList (make-array CompilerDiagnosticLabel 0) 0))

(define (compiler-diagnostic-label-list-count
  [labels : CompilerDiagnosticLabelList]) : i64
  (struct-get labels len))

(define (compiler-diagnostic-label-list-get
  [labels : CompilerDiagnosticLabelList]
  [index : i64]) : CompilerDiagnosticLabel
  (array-ref (struct-get labels slots) index))

;; Label attachment is a persistent update. A right-sized replacement keeps the
;; source diagnostic isolated while retaining the established newest-first order.
(define (compiler-diagnostic-label-list-prepend
  [label : CompilerDiagnosticLabel]
  [labels : CompilerDiagnosticLabelList]) : CompilerDiagnosticLabelList
  (let
    [count : i64 (struct-get labels len)]
    [src : (__tl_dyn-array CompilerDiagnosticLabel) (struct-get labels slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (make-array CompilerDiagnosticLabel (+ count 1))]
    [index : i64 0]
    (begin
      (array-set! dst 0 label)
      (while (< index count)
        (begin
          (array-set! dst (+ index 1) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticLabelList dst (+ count 1)))))

(define (compiler-diagnostic-copy-label-list
  [labels : CompilerDiagnosticLabelList]) : CompilerDiagnosticLabelList
  (let
    [count : i64 (struct-get labels len)]
    [src : (__tl_dyn-array CompilerDiagnosticLabel) (struct-get labels slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticLabel)
      (make-array CompilerDiagnosticLabel count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [label : CompilerDiagnosticLabel (array-ref src index)]
          (begin
            (array-set!
              dst
              index
              (CompilerDiagnosticLabel
                (compiler-diagnostic-copy-span (struct-get label span))
                (compiler-diagnostic-copy-maybe-string (struct-get label label))))
            (set! index (+ index 1)))))
      (CompilerDiagnosticLabelList dst count))))

(define (compiler-diagnostic-note-list-empty) : CompilerDiagnosticNoteList
  (CompilerDiagnosticNoteList (make-array String 0) 0))

(define (compiler-diagnostic-note-list-count
  [notes : CompilerDiagnosticNoteList]) : i64
  (struct-get notes len))

(define (compiler-diagnostic-note-list-get
  [notes : CompilerDiagnosticNoteList]
  [index : i64]) : String
  (array-ref (struct-get notes slots) index))

;; Notes have the same persistent newest-first attachment contract as labels.
(define (compiler-diagnostic-note-list-prepend
  [note : String]
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnosticNoteList
  (let
    [count : i64 (struct-get notes len)]
    [src : (__tl_dyn-array String) (struct-get notes slots)]
    [dst : (__tl_dyn-array String) (make-array String (+ count 1))]
    [index : i64 0]
    (begin
      (array-set! dst 0 note)
      (while (< index count)
        (begin
          (array-set! dst (+ index 1) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticNoteList dst (+ count 1)))))

(define (compiler-diagnostic-copy-note-list
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnosticNoteList
  (let
    [count : i64 (struct-get notes len)]
    [src : (__tl_dyn-array String) (struct-get notes slots)]
    [dst : (__tl_dyn-array String) (make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! dst index (string.copy (& (array-ref src index))))
          (set! index (+ index 1))))
      (CompilerDiagnosticNoteList dst count))))

(define (compiler-diagnostic-copy-text-edit [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticTextEdit
  (CompilerDiagnosticTextEdit
    (compiler-diagnostic-copy-span (struct-get edit span))
    (string.copy (& (struct-get edit replacement)))))

(define (compiler-diagnostic-copy-text-edit-list
  [edits : CompilerDiagnosticTextEditSeq]) : CompilerDiagnosticTextEditSeq
  (let
    [count : i64 (struct-get edits len)]
    [src : (__tl_dyn-array CompilerDiagnosticTextEdit) (struct-get edits slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (make-array CompilerDiagnosticTextEdit count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            dst
            index
            (compiler-diagnostic-copy-text-edit (array-ref src index)))
          (set! index (+ index 1))))
      (CompilerDiagnosticTextEditSeq dst count))))

(define (compiler-diagnostic-copy-fix [fix : CompilerDiagnosticFix]) : CompilerDiagnosticFix
  (CompilerDiagnosticFix
    (string.copy (& (struct-get fix title)))
    (struct-get fix applicability)
    (compiler-diagnostic-copy-text-edit-list (struct-get fix edits))))

(define (compiler-diagnostic-copy-fix-list [fixes : CompilerDiagnosticFixSeq]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 (struct-get fixes len)]
    [src : (__tl_dyn-array CompilerDiagnosticFix) (struct-get fixes slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            dst
            index
            (compiler-diagnostic-copy-fix (array-ref src index)))
          (set! index (+ index 1))))
      (CompilerDiagnosticFixSeq dst count))))

(define (compiler-diagnostic-copy [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (CompilerDiagnostic
    (string.copy (& (struct-get diag message)))
    (struct-get diag level)
    (compiler-diagnostic-copy-maybe-string (struct-get diag code))
    (compiler-diagnostic-copy-maybe-string (struct-get diag category))
    (compiler-diagnostic-copy-span (struct-get diag primary))
    (compiler-diagnostic-copy-maybe-string (struct-get diag help))
    (compiler-diagnostic-copy-label-list (struct-get diag secondary))
    (compiler-diagnostic-copy-note-list (struct-get diag notes))
    (compiler-diagnostic-copy-fix-list (struct-get diag fixes))))

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

(define (compiler-diagnostic-span-empty? [span : CompilerDiagnosticSpan]) : bool
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
    [span : CompilerDiagnosticSpan (struct-get edit span)]
    [path : String (compiler-diagnostic-span-path span)]
    (if (string.eq path "")
      diagnostic-path
      path)))

(define (compiler-diagnostic-edit-overlaps?
  [diagnostic-path : String]
  [left : CompilerDiagnosticTextEdit]
  [right : CompilerDiagnosticTextEdit]) : bool
  (let
    [left-span : CompilerDiagnosticSpan (struct-get left span)]
    [right-span : CompilerDiagnosticSpan (struct-get right span)]
    [same-path : bool
      (string.eq
        (compiler-diagnostic-edit-effective-path diagnostic-path left)
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
  [slots : (__tl_dyn-array CompilerDiagnosticTextEdit)]
  [count : i64]
  [start : i64]) : bool
  (let
    [cursor : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (< cursor count))
        (begin
          (if (compiler-diagnostic-edit-overlaps?
            diagnostic-path
            edit
            (array-ref slots cursor))
            (set! found true)
            unit)
          (set! cursor (+ cursor 1))))
      found)))

(define (compiler-diagnostic-edit-list-valid?
  [diagnostic-path : String]
  [edits : CompilerDiagnosticTextEditSeq]) : bool
  (let
    [count : i64 (struct-get edits len)]
    [slots : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (struct-get edits slots)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [edit : CompilerDiagnosticTextEdit (array-ref slots index)]
          (begin
            (if (and
              (compiler-diagnostic-span-valid-for-edit? (struct-get edit span))
              (not
                (compiler-diagnostic-edit-overlaps-rest?
                  diagnostic-path
                  edit
                  slots
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
    [edits : CompilerDiagnosticTextEditSeq (struct-get fix edits)]
    (and
      (> (string.string-length (struct-get fix title)) 0)
      (> (struct-get edits len) 0)
      (compiler-diagnostic-edit-list-valid? diagnostic-path edits))))

(define (compiler-diagnostic-repath-text-edit
  [edit : CompilerDiagnosticTextEdit]
  [path : String]) : CompilerDiagnosticTextEdit
  (let
    [span : CompilerDiagnosticSpan (struct-get edit span)]
    [edit-path : String (compiler-diagnostic-span-path span)]
    (CompilerDiagnosticTextEdit
      (if (string.eq edit-path "")
        (CompilerDiagnosticSpan
          path
          (compiler-diagnostic-span-start-line span)
          (compiler-diagnostic-span-start-col span)
          (compiler-diagnostic-span-end-line span)
          (compiler-diagnostic-span-end-col span))
        span)
      (struct-get edit replacement))))

(define (compiler-diagnostic-repath-text-edit-list
  [edits : CompilerDiagnosticTextEditSeq]
  [path : String]) : CompilerDiagnosticTextEditSeq
  (let
    [count : i64 (struct-get edits len)]
    [src : (__tl_dyn-array CompilerDiagnosticTextEdit) (struct-get edits slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (make-array CompilerDiagnosticTextEdit count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            dst
            index
            (compiler-diagnostic-repath-text-edit (array-ref src index) path))
          (set! index (+ index 1))))
      (CompilerDiagnosticTextEditSeq dst count))))

(define (compiler-diagnostic-repath-fix-list
  [fixes : CompilerDiagnosticFixSeq]
  [path : String]) : CompilerDiagnosticFixSeq
  (let
    [count : i64 (struct-get fixes len)]
    [src : (__tl_dyn-array CompilerDiagnosticFix) (struct-get fixes slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (make-array CompilerDiagnosticFix count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [fix : CompilerDiagnosticFix (array-ref src index)]
          (begin
            (array-set!
              dst
              index
              (CompilerDiagnosticFix
                (struct-get fix title)
                (struct-get fix applicability)
                (compiler-diagnostic-repath-text-edit-list
                  (struct-get fix edits)
                  path)))
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
    (token.source-error-span err)
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
      path
      (compiler-diagnostic-line diag)
      (compiler-diagnostic-col diag)
      (compiler-diagnostic-end-line diag)
      (compiler-diagnostic-end-col diag))
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)
    (compiler-diagnostic-repath-fix-list (compiler-diagnostic-fixes diag) path)))

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
    (string.eq (struct-get left path) (struct-get right path))
    (= (struct-get left start-line) (struct-get right start-line))
    (= (struct-get left start-col) (struct-get right start-col))
    (= (struct-get left end-line) (struct-get right end-line))
    (= (struct-get left end-col) (struct-get right end-col))))

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
          [entry-span : CompilerDiagnosticSpan (struct-get entry span)]
          (begin
            (if (and
              (compiler-diagnostic-span-eq? (& entry-span) (& span))
              (compiler-diagnostic-maybe-string-eq?
                (struct-get entry label)
                label))
              (set! found true)
              unit)
            (set! index (+ index 1)))))
      found)))

(define (compiler-diagnostic-with-secondary-if-new
  [diag : CompilerDiagnostic]
  [span : CompilerDiagnosticSpan]
  [label : CompilerDiagnosticMaybeString]) : CompilerDiagnostic
  (if (compiler-diagnostic-secondary-present? diag span label)
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
      (make-array CompilerDiagnosticTextEdit 1)]
    (begin
      (array-set! slots 0 edit)
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
    [count : i64 (struct-get fixes len)]
    [src : (__tl_dyn-array CompilerDiagnosticFix) (struct-get fixes slots)]
    [dst : (__tl_dyn-array CompilerDiagnosticFix)
      (make-array CompilerDiagnosticFix (+ count 1))]
    [index : i64 0]
    (begin
      (array-set! dst 0 fix)
      (while (< index count)
        (begin
          (array-set! dst (+ index 1) (array-ref src index))
          (set! index (+ index 1))))
      (CompilerDiagnosticFixSeq dst (+ count 1)))))

;; Fix attachment is the validation boundary: generated/unknown 0:0 spans,
;; reversed spans, empty edit sets, and overlapping half-open edits are not
;; admitted to the diagnostic. Empty paths inherit the primary source path.
(define (compiler-diagnostic-with-fix
  [diag : CompilerDiagnostic]
  [fix : CompilerDiagnosticFix]) : CompilerDiagnostic
  (if (compiler-diagnostic-fix-valid? (compiler-diagnostic-path diag) fix)
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
    [span : CompilerDiagnosticSpan (struct-get entry span)]
    [path : String (compiler-diagnostic-span-path (& span))]
    [label : String
      (match (struct-get entry label)
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
              primary-path
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
    [span : CompilerDiagnosticSpan (struct-get entry span)]
    [label : CompilerDiagnosticMaybeString (struct-get entry label)]
    [path : String (compiler-diagnostic-span-path span)]
    [same-path : bool
      (if (string.eq path "")
        true
        (string.eq path primary-path))]
    [label-suffix : String (compiler-diagnostic-render-label-suffix label)]
    [label-only : String
      (compiler-diagnostic-render-secondary-label-only label)]
    [snippet : String
      (compiler-diagnostic-render-source-snippet
        span
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
              primary-path
              source
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
      (compiler-diagnostic-render-header diag level code)
      (compiler-diagnostic-render-location diag)
      "   |\n"
      (compiler-diagnostic-render-source-snippet
        primary-span
        (& source)
        (& empty-label))
      (compiler-diagnostic-render-secondary-spans
        (compiler-diagnostic-path diag)
        source
        (compiler-diagnostic-secondary-spans diag))
      (compiler-diagnostic-render-help help)
      (compiler-diagnostic-render-source-notes (compiler-diagnostic-notes diag)))))

(define (compiler-diagnostic-render-source
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (compiler-diagnostic-render-source-with-metadata
    diag
    source
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-help diag)))