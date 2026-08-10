;; compiler_tlci_native_producer.tl - Generate and map normal-backend
;; transformer programs for tlci native package images (refs #5213, #5596).
;;
;; The producer captures checked defmacro identities, parameters, and bodies,
;; desugars eligible bodies (general quasiquote templates -- nested calls,
;; literals, plain symbols, unquoted operands and computed unquotes, and
;; unquote-splicing -- array intrinsic nodes, literal templates,
;; match-on-type-kind computed bodies, operand-count computed ifs and integer
;; matches, indexed operand access, and the expr-list fold intrinsics) into ordinary
;; TypeLisp entry functions whose comptime primitives are host callback calls,
;; and resolves the compiled entries by the compact function-symbol contract.
;; Bodies outside the supported subset compile to ok-with-no-result shells so
;; the dispatch route keeps its counted interpreted fallback.
(import compiler_ast_types)
(import compiler_diagnostic)
(import compiler_object as cobj)
(import compiler_backend)
(import compiler_tlci_native_image)
(import tlci_core)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.array)
(import stdlib.string)

(defmacro (embedded-native-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(define (embedded-stdlib-tlci-identity [module : String] [name-id : i64]) : String
  (if (= (string.string-length module) 0)
    (ci.intern-str name-id)
    (str_cat.str-cat module "/" (ci.intern-str name-id))))

;; Every collected macro's parsed source is captured so the producer can
;; compile each eligible expression body to a native entry; identities whose
;; bodies fall outside the supported subset stay registration shells with the
;; counted interpreted fallback. Captures are an explicit producer input so
;; package dependency builds cannot observe stale sources from an earlier
;; image in the same process. Refs #5212, #5213, #2754.
(defstruct TlciNativeMacroCapture
  (identity String)
  (params compiler_ast_types.AstMacroParamList)
  (body i64))

;; Compile-time let-local session slots for the body currently compiling
;; (let* scoping; the length is saved and restored around nested bodies).
;; Names are source spellings looked up newest-first so later bindings
;; shadow earlier ones. Refs #5603.
(define embedded-native-locals-cap : i64
  32)
(define embedded-native-local-names : (__tl_dyn-array String)
  (array.make-array String embedded-native-locals-cap))
(define embedded-native-local-len : (__tl_dyn-array i64)
  (make-array 0))

;; Compile-time i64 locals for the body currently compiling: a binder arm of a
;; computed integer match binds the scrutinee's generated i64 variable, so a
;; later `(comptime.expr-int n)` reads the count as data instead of a literal.
;; A scalar `let` binding over comptime data joins the same table, which is why
;; the budget is well above the two binder arms #5617 needed: the scanner
;; bodies bind six at once. Refs #5617, #5701.
(define embedded-native-data-locals-cap : i64
  24)
(define embedded-native-data-local-names : (__tl_dyn-array String)
  (array.make-array String embedded-native-data-locals-cap))
(define embedded-native-data-local-texts : (__tl_dyn-array String)
  (array.make-array String embedded-native-data-locals-cap))
(define embedded-native-data-local-len : (__tl_dyn-array i64)
  (make-array 0))

;; Serial number for generated i64 temporaries; unique names keep an arm body's
;; own temporaries from shadowing a scrutinee its default arm still reads.
(define embedded-native-temp-seq : (__tl_dyn-array i64)
  (make-array 0))

(define (embedded-native-locals-reset!) : unit
  (begin
    (array-set! embedded-native-local-len 0 0)
    (array-set! embedded-native-data-local-len 0 0)
    (array-set! embedded-native-temp-seq 0 0)))

(define (embedded-native-temp-name!) : String
  (let
    [seq : i64 (array-ref embedded-native-temp-seq 0)]
    (begin
      (array-set! embedded-native-temp-seq 0 (+ seq 1))
      (str_cat.str-cat "k" (string.int->string seq)))))

;; The generated i64 variable of a compile-time data local, or "" when unbound.
(define (embedded-native-data-local-text [name : String]) : String
  (let
    [index : i64 (- (array-ref embedded-native-data-local-len 0) 1)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (>= index 0))
        (if (string.eq (array-ref embedded-native-data-local-names index) name)
          (set! found index)
          (set! index (- index 1))))
      (if (< found 0)
        ""
        (array-ref
          (embedded-native-global-shared-view embedded-native-data-local-texts)
          found)))))

;; Bind `name` to the generated i64 variable `text`; false when the slot budget
;; is exhausted (the caller then keeps the fallback shell).
(define (embedded-native-data-local-push! [name : String] [text : String]) : bool
  (let
    [slot : i64 (array-ref embedded-native-data-local-len 0)]
    (if (>= slot embedded-native-data-locals-cap)
      false
      (begin
        (array-set! embedded-native-data-local-names slot name)
        (array-set! embedded-native-data-local-texts slot text)
        (array-set! embedded-native-data-local-len 0 (+ slot 1))
        true))))

;; The session-slot index of a let-bound local, or -1 when unbound.
(define (embedded-native-local-index [name : String]) : i64
  (let
    [index : i64 (- (array-ref embedded-native-local-len 0) 1)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (>= index 0))
        (if (string.eq (array-ref embedded-native-local-names index) name)
          (set! found index)
          (set! index (- index 1))))
      found)))

;; Bind `name` into the next session slot; returns the slot, or -1 when the
;; slot budget is exhausted (the caller then keeps the fallback shell).
(define (embedded-native-local-push! [name : String]) : i64
  (let
    [slot : i64 (array-ref embedded-native-local-len 0)]
    (if (>= slot embedded-native-locals-cap)
      -1
      (begin
        (array-set! embedded-native-local-names slot name)
        (array-set! embedded-native-local-len 0 (+ slot 1))
        slot))))

(defstruct TlciNativeMacroCaptures
  (slots (__tl_dyn-array TlciNativeMacroCapture))
  (len i64))

(define (tlci-native-macro-captures-new) : TlciNativeMacroCaptures
  (TlciNativeMacroCaptures (array.make-array TlciNativeMacroCapture 0) 0))

(define (tlci-native-macro-captures-copy-range!
  [dst : (&mut dst (__tl_dyn-array TlciNativeMacroCapture))]
  [src : (& src (__tl_dyn-array TlciNativeMacroCapture))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (tlci-native-macro-captures-copy-range! dst src (+ index 1) count))))

(define (tlci-native-macro-captures-grow!
  [captures : (&mut captures TlciNativeMacroCaptures)]) : unit
  (let
    [old-cap : i64 (array-length (struct-get captures slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array TlciNativeMacroCapture)
      (array.make-array TlciNativeMacroCapture new-cap)]
    (begin
      (tlci-native-macro-captures-copy-range!
        (&mut bigger)
        (& (struct-get captures slots))
        0
        (struct-get captures len))
      (set! (struct-get captures slots) bigger))))

(define (tlci-native-macro-captures-push!
  [captures : (&mut captures TlciNativeMacroCaptures)]
  [capture : TlciNativeMacroCapture]) : unit
  (begin
    (when
      (>= (struct-get captures len) (array-length (struct-get captures slots)))
      (tlci-native-macro-captures-grow! captures))
    (let
      [index : i64 (struct-get captures len)]
      (begin
        (array-set! (struct-get captures slots) index capture)
        (set! (struct-get captures len) (+ index 1))))))

(define (embedded-stdlib-tlci-unwrap-expr [node : i64]) : compiler_ast_types.AstExpr
  (match (compiler_ast_types.ast-node-get node)
    [(compiler_ast_types.AstExpr.Spanned inner _)
      (embedded-stdlib-tlci-unwrap-expr inner)]
    [(compiler_ast_types.AstExpr.MacroExpansion inner _ _)
      (embedded-stdlib-tlci-unwrap-expr inner)]
    [_ (compiler_ast_types.ast-node-get node)]))

(defenum EmbeddedNativeMaybeSourceSpan
  (Some compiler_ast_types.AstSourceSpan)
  (None))

;; Native quasiquote reconstruction normally drops parser wrappers. Retain a
;; call head's template span so a generated call to another macro can report
;; the same expansion frame as the interpreted route.
(define (embedded-native-call-head-source-span [node : i64]) : EmbeddedNativeMaybeSourceSpan
  (match (compiler_ast_types.ast-node-get node)
    [(compiler_ast_types.AstExpr.Spanned _ span)
      (EmbeddedNativeMaybeSourceSpan.Some span)]
    [(compiler_ast_types.AstExpr.MacroExpansion inner _ _)
      (embedded-native-call-head-source-span inner)]
    [_ EmbeddedNativeMaybeSourceSpan.None]))

(define (embedded-stdlib-tlci-param-index
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [name-id : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index (struct-get params len)))
        (begin
          (match (array-ref (struct-get params slots) index)
            [(compiler_ast_types.AstMacroParam.Param pname _ _ _)
              (if (= pname name-id)
                (set! found index)
                unit)])
          (set! index (+ index 1))))
      found)))

(define embedded-stdlib-tlci-native-report-count : (__tl_dyn-array i64)
  (make-array 0))

;; A native entry can still hand single arms back to the interpreter: an arm
;; body outside the supported subset compiles to ok-with-no-result instead of
;; poisoning the whole entry. That is deliberate -- partial nativeness is still
;; a win -- but it makes the native entry count an upper bound on coverage, so
;; the emitted arm carries a marker comment and the producer reports how many
;; such sites and entries the image contains. Refs #5596.
(define embedded-native-interpreted-arm-marker : String
  ";; tlci-interpreted-arm")
(define embedded-native-interpreted-arm-code : String
  "  ;; tlci-interpreted-arm\n  0\n")

;: Entries that compiled natively but still contain at least one interpreted
;: arm site.
;; Why the last body compiled fell back to a registration shell. The producer
;; decides eligibility across a dozen return points and, until now, said only
;; "shell" -- so every remaining #5596 family was investigated by inferring the
;; blocker from an AST histogram, which mis-predicted the residue twice
;; (#5605, #5600). The reason is recorded where the decision is actually made
;; and reported per identity, and it never reaches generated text, so images
;; stay byte-identical. Refs #5596.
(define embedded-native-fallback-reason : (__tl_dyn-array String)
  (make-array ""))

;; Per-identity shell reasons for this image, one `identity<TAB>reason` line
;; each. The build tool prints them on request; nothing here reaches generated
;; text, so the image stays byte-identical either way.
(define embedded-stdlib-tlci-native-report-reasons : (__tl_dyn-array String)
  (make-array ""))

;; Opt-in second-pass diagnostics for fallback shells. The emitting pass above
;; stays first-writer-wins and is the sole authority for generated bytes. When
;; enabled by the build tool, each shell is walked again with neutral recovery
;; values: a rejected child records its blocker but returns an inert placeholder
;; so later siblings are still inspected. No text from this pass reaches the
;; package source or image. Refs #5742.
(define embedded-native-full-blocker-report-enabled : bool
  false)
(define embedded-native-full-blocker-diagnostic-active : bool
  false)
(define embedded-native-full-blocker-cap : i64
  256)
(define embedded-native-full-blockers : (__tl_dyn-array String)
  (array.make-array String embedded-native-full-blocker-cap))
(define embedded-native-full-blocker-len : i64
  0)
(define embedded-native-full-blocker-events : i64
  0)
(define embedded-native-full-walked : (__tl_dyn-array String)
  (array.make-array String embedded-native-full-blocker-cap))
(define embedded-native-full-walked-len : i64
  0)
(define embedded-native-full-blocker-overflow : bool
  false)
(define embedded-native-full-walked-overflow : bool
  false)

;; Full-mode lines are explicit about polarity:
;;   identity<TAB>blocked<TAB>capability
;;   identity<TAB>walked<TAB>capability
;; The default report above remains byte-for-byte unchanged.
(define embedded-stdlib-tlci-native-report-full-reasons : (__tl_dyn-array
    String)
  (make-array ""))

(define (embedded-native-full-blocker-report-set! [enabled : bool]) : unit
  (set! embedded-native-full-blocker-report-enabled enabled))

(define (embedded-native-full-string-set-contains?
  [items : (& items (__tl_dyn-array String))]
  [len : i64]
  [item : String]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index len))
        (if (string.eq (& (array-ref items index)) (& item))
          (set! found true)
          (set! index (+ index 1))))
      found)))

(define (embedded-native-full-string-set-add!
  [items : (&mut items (__tl_dyn-array String))]
  [len : i64]
  [item : String]) : i64
  (if (or
    (>= len embedded-native-full-blocker-cap)
    (embedded-native-full-string-set-contains? (& items) len item))
    len
    (begin
      (array-set! items len (string.copy (& item)))
      (+ len 1))))

(define (embedded-native-full-blocker-reset!) : unit
  (begin
    (set! embedded-native-full-blocker-len 0)
    (set! embedded-native-full-blocker-events 0)
    (set! embedded-native-full-walked-len 0)
    (set! embedded-native-full-blocker-overflow false)
    (set! embedded-native-full-walked-overflow false)))

(define (embedded-native-full-walked-note! [capability : String]) : unit
  (when
    embedded-native-full-blocker-diagnostic-active
    (begin
      (when
        (and
          (>= embedded-native-full-walked-len embedded-native-full-blocker-cap)
          (not
            (embedded-native-full-string-set-contains?
              (& embedded-native-full-walked)
              embedded-native-full-walked-len
              capability)))
        (set! embedded-native-full-walked-overflow true))
      (set!
        embedded-native-full-walked-len
        (embedded-native-full-string-set-add!
          (&mut embedded-native-full-walked)
          embedded-native-full-walked-len
          capability)))))

(define (embedded-native-fallback-reason-reset!) : unit
  (array-set! embedded-native-fallback-reason 0 ""))

;; First writer wins: the outermost walker that gives up would otherwise
;; overwrite the specific inner construct that actually failed.
(define (embedded-native-fallback-reason-note! [reason : String]) : unit
  (if embedded-native-full-blocker-diagnostic-active
    (begin
      (set!
        embedded-native-full-blocker-events
        (+ embedded-native-full-blocker-events 1))
      (when
        (and
          (>= embedded-native-full-blocker-len embedded-native-full-blocker-cap)
          (not
            (embedded-native-full-string-set-contains?
              (& embedded-native-full-blockers)
              embedded-native-full-blocker-len
              reason)))
        (set! embedded-native-full-blocker-overflow true))
      (set!
        embedded-native-full-blocker-len
        (embedded-native-full-string-set-add!
          (&mut embedded-native-full-blockers)
          embedded-native-full-blocker-len
          reason)))
    (let
      [empty : bool
        (=
          (string.string-length
            (& (array-ref embedded-native-fallback-reason 0)))
          0)]
      (when empty (array-set! embedded-native-fallback-reason 0 reason)))))

;; Recovery helpers are used only at explicit give-up leaves. The normal pass
;; retains its load-bearing failure sentinels; diagnostic mode substitutes a
;; neutral value so the parent can keep walking other children.
(define (embedded-native-fallback-opened [reason : String]) : i64
  (begin
    (embedded-native-fallback-reason-note! reason)
    (if embedded-native-full-blocker-diagnostic-active
      0
      -1)))

(define (embedded-native-fallback-code [reason : String]) : String
  (begin
    (embedded-native-fallback-reason-note! reason)
    (if embedded-native-full-blocker-diagnostic-active
      "  0\n"
      "")))

(define (embedded-native-fallback-unreported-since? [blockers-before : i64]) : bool
  (if embedded-native-full-blocker-diagnostic-active
    (= embedded-native-full-blocker-events blockers-before)
    (=
      (string.string-length (& (array-ref embedded-native-fallback-reason 0)))
      0)))

;; The source-level spelling of an expression node, for the reason string.
(define (embedded-native-expr-kind-name [e : compiler_ast_types.AstExpr]) : String
  (match e
    [(compiler_ast_types.AstExpr.Ann _ _) "ann"]
    [(compiler_ast_types.AstExpr.Cast _ _) "cast"]
    [(compiler_ast_types.AstExpr.Try _) "try"]
    [(compiler_ast_types.AstExpr.Tuple _) "tuple"]
    [(compiler_ast_types.AstExpr.TupleRef _ _) "tuple-ref"]
    [(compiler_ast_types.AstExpr.Init _) "init"]
    [(compiler_ast_types.AstExpr.Lambda _) "lambda"]
    [(compiler_ast_types.AstExpr.DynArray _) "dyn-array"]
    [(compiler_ast_types.AstExpr.Array _) "array"]
    [(compiler_ast_types.AstExpr.ArrayTake _ _ _) "array-take"]
    [(compiler_ast_types.AstExpr.FixedArrayTake _ _) "array-take"]
    [(compiler_ast_types.AstExpr.BoxTake _) "box-take"]
    [(compiler_ast_types.AstExpr.BoxSet _ _) "box-set"]
    [(compiler_ast_types.AstExpr.IntToPtr _ _) "int->ptr"]
    [(compiler_ast_types.AstExpr.PtrAddrOf _) "ptr-addr-of"]
    [(compiler_ast_types.AstExpr.PtrNull _) "ptr-null"]
    [(compiler_ast_types.AstExpr.PtrNullCheck _) "ptr-null?"]
    [(compiler_ast_types.AstExpr.PtrCast _ _) "ptr-cast"]
    [(compiler_ast_types.AstExpr.StringRef _ _) "string-ref"]
    [(compiler_ast_types.AstExpr.StringFromBytes _ _) "string-from-bytes"]
    [(compiler_ast_types.AstExpr.Comptime _) "comptime"]
    [(compiler_ast_types.AstExpr.Quote _) "quote"]
    [(compiler_ast_types.AstExpr.Quasiquote _) "quasiquote"]
    [(compiler_ast_types.AstExpr.UnquoteSplicing _) "unquote-splicing"]
    [(compiler_ast_types.AstExpr.Unquote _) "unquote"]
    [(compiler_ast_types.AstExpr.Break) "break"]
    [(compiler_ast_types.AstExpr.Continue) "continue"]
    [(compiler_ast_types.AstExpr.Return _) "return"]
    [(compiler_ast_types.AstExpr.WithRegion _ _) "with-arena"]
    [(compiler_ast_types.AstExpr.WithResource _) "with"]
    [(compiler_ast_types.AstExpr.WithScratch _) "with-scratch"]
    [(compiler_ast_types.AstExpr.WithEscape _ _) "with-escape"]
    [(compiler_ast_types.AstExpr.InArena _ _) "in-arena"]
    [(compiler_ast_types.AstExpr.Foreach _) "foreach"]
    [(compiler_ast_types.AstExpr.SpmdReduce _) "spmd-reduce"]
    [(compiler_ast_types.AstExpr.SpmdScan _) "spmd-scan"]
    [(compiler_ast_types.AstExpr.Unsafe _) "unsafe"]
    [(compiler_ast_types.AstExpr.Literal
        (compiler_ast_types.AstLiteral.Float _))
      "float-literal"]
    [(compiler_ast_types.AstExpr.Literal _) "literal"]
    ;; Kinds the walkers do support are named too: reaching a give-up point on
    ;; one of these means the construct is supported in some positions and not
    ;; in the one that failed, which is the more useful thing to report.
    [(compiler_ast_types.AstExpr.If _ _ _) "if"]
    [(compiler_ast_types.AstExpr.Match _) "match"]
    [(compiler_ast_types.AstExpr.Let _) "let"]
    [(compiler_ast_types.AstExpr.Begin _) "begin"]
    [(compiler_ast_types.AstExpr.Call _ _) "call"]
    [(compiler_ast_types.AstExpr.Var _) "var"]
    [(compiler_ast_types.AstExpr.Set _ _) "set!"]
    [(compiler_ast_types.AstExpr.While _ _) "while"]
    [(compiler_ast_types.AstExpr.Binary _ _ _) "binary"]
    [(compiler_ast_types.AstExpr.Unary _ _) "unary"]
    [(compiler_ast_types.AstExpr.Borrow _ _ _) "borrow"]
    [(compiler_ast_types.AstExpr.StructGet _ _) "struct-get"]
    [(compiler_ast_types.AstExpr.StructSet _ _ _) "struct-set!"]
    [(compiler_ast_types.AstExpr.BracketClause _) "bracket-clause"]
    [(compiler_ast_types.AstExpr.ArrayRef _ _) "array-ref"]
    [(compiler_ast_types.AstExpr.ArraySet _ _ _) "array-set!"]
    [(compiler_ast_types.AstExpr.ArrayPush _ _) "array-push!"]
    [(compiler_ast_types.AstExpr.ArrayData _) "array-data"]
    [(compiler_ast_types.AstExpr.StringData _) "string-data"]
    [(compiler_ast_types.AstExpr.Box _) "box"]
    [(compiler_ast_types.AstExpr.BoxGet _) "box-get"]
    [(compiler_ast_types.AstExpr.PtrRead _) "ptr-read"]
    [(compiler_ast_types.AstExpr.PtrWrite _ _) "ptr-write!"]
    [(compiler_ast_types.AstExpr.PtrOffset _ _) "ptr-offset"]
    [(compiler_ast_types.AstExpr.PtrToInt _) "ptr->int"]
    [(compiler_ast_types.AstExpr.MakeArray _ _) "make-array"]
    [_ "unclassified"]))

(define embedded-stdlib-tlci-native-report-partial-count : (__tl_dyn-array i64)
  (make-array 0))

;: Interpreted arm sites across every native entry in the image.
(define embedded-stdlib-tlci-native-report-interpreted-arms : (__tl_dyn-array
    i64)
  (make-array 0))

;: How many non-overlapping occurrences of `needle` appear in `text`.
(define (embedded-native-count-occurrences [text : String] [needle : String]) : i64
  (let
    [needle-len : i64 (string.string-length needle)]
    [limit : i64 (string.string-length text)]
    [index : i64 0]
    [count : i64 0]
    (begin
      (when
        (> needle-len 0)
        (while (<= (+ index needle-len) limit)
          (if (string.is-string-prefix-at text needle index)
            (begin
              (set! count (+ count 1))
              (set! index (+ index needle-len)))
            (set! index (+ index 1)))))
      count)))

(define (tlci-native-macro-capture-slot
  [captures : (& captures TlciNativeMacroCaptures)]
  [identity : String]) : i64
  (let
    [count : i64 (struct-get captures len)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq
          (struct-get (array-ref (struct-get captures slots) index) identity)
          identity)
          (set! found index)
          (set! index (+ index 1))))
      found)))

;; Instance-proof producer result: callers across import spellings match on
;; this producer-owned enum and receive raw bytes.
(defenum ResultProducerBytes
  (Ok (__tl_dyn-array u8))
  (Err String))

(define embedded-native-ops-cap : i64
  4096)

;; Large native arms use bounded chunks only when necessary; ordinary entries
;; retain their exact legacy nested source shape.
(define embedded-native-op-chunk-cap : i64
  256)

(define (embedded-native-ops-push!
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]
  [line : String]) : unit
  (let
    [slot : i64 (array-ref ops-count 0)]
    (when
      (< slot embedded-native-ops-cap)
      (array-set! ops slot line)
      (array-set! ops-count 0 (+ slot 1)))))

(define (embedded-native-op-call
  [op : String]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : String
  (str_cat.str-cat
    "(comptime-host-"
    op
    " host session "
    arg-a
    " "
    arg-b
    " "
    arg-c
    ")"))

;; Render a neutral callback call as one link in the legacy nested data-probe
;; chain. The data-value paths still close one let/if pair per operation.
(define (embedded-native-op-open-from-call [status-index : i64] [call : String]) : String
  (let
    [sname : String (str_cat.str-cat "q" (string.int->string status-index))]
    (str_cat.str-cat
      "  (let ["
      sname
      " : i64 "
      call
      "] (if (not (= "
      sname
      " 0)) "
      sname
      "\n")))

(define (embedded-native-fuel-open) : String
  "  (let [q99 : i64 (comptime-host-fuel-check host session 0 0 0)] (if (not (= q99 0)) q99\n")

(define (embedded-native-name-arg [name : String]) : String
  (str_cat.str-cat
    "(cast (unsafe (ptr->int (string-data \""
    name
    "\"))) : i64)"))

;; Emit the push for an unquoted name in template/computed position: a macro
;; parameter pushes its operand, while a let-bound local pushes its session
;; slot. Returns 1, or -1 when the name is unbound. Refs #5603.
(define (embedded-native-unquote-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [pname : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [param : i64 (embedded-stdlib-tlci-param-index params pname)]
    (if (>= param 0)
      (begin
        (embedded-native-template-push!
          ops
          ops-count
          (tlci_core.tlci-host-callback-name-shared-view
            tlci_core.tlci-host-callback-name-push-operand)
          (string.int->string param)
          "0"
          "0")
        1)
      (let
        [slot : i64 (embedded-native-local-index (ci.intern-str pname))]
        (if (< slot 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-local-get)
              (string.int->string slot)
              "0"
              "0")
            1))))))

;; Emit neutral callback calls for one eligible body into `ops`; returns the
;; count of emitted operations, or -1 when the body is outside the subset.
;; Quasiquoted bodies go through the general template walker; plain bodies may
;; be a macro parameter (the identity transformer), a `(comptime.expr-var
;; "name")` builder call, or one of the expr-list fold intrinsics.
(define (embedded-native-body-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.Quasiquote quoted)
      (embedded-native-template-ops params quoted ops ops-count)]
    [(compiler_ast_types.AstExpr.Var pname)
      (let
        [param : i64 (embedded-stdlib-tlci-param-index params pname)]
        (if (< param 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-push-operand)
              (string.int->string param)
              "0"
              "0")
            1)))]
    [(compiler_ast_types.AstExpr.Call fold-func fold-args)
      ;; Plain (not quasiquoted) call to the expr-list fold intrinsic: the
      ;; and/or shape. The host op mirrors the interpreted fold exactly, so
      ;; the whole expansion is one dispatch.
      (match (embedded-stdlib-tlci-unwrap-expr fold-func)
        [(compiler_ast_types.AstExpr.Var fold-head)
          (if (and
            (or
              (string.eq
                (ci.intern-str fold-head)
                "comptime.expr-clause-list-fold-if")
              (string.eq (ci.intern-str fold-head) "expr-clause-list-fold-if"))
            (= (compiler_ast_types.ast-expr-list-len (& fold-args)) 3))
            (let
              [clauses-index : i64
                (embedded-native-var-param-index
                  params
                  (compiler_ast_types.ast-expr-list-get (& fold-args) 0 0))]
              [missing-name : String
                (embedded-native-expr-var-name
                  (compiler_ast_types.ast-expr-list-get (& fold-args) 1 0))]
              [else-not-final-name : String
                (embedded-native-expr-var-name
                  (compiler_ast_types.ast-expr-list-get (& fold-args) 2 0))]
              (if (or
                (< clauses-index 0)
                (= (string.string-length missing-name) 0)
                (= (string.string-length else-not-final-name) 0))
                -1
                (begin
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-call
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-var)
                      (embedded-native-name-arg missing-name)
                      (string.int->string (string.string-length missing-name))
                      "0"))
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-call
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-var)
                      (embedded-native-name-arg else-not-final-name)
                      (string.int->string
                        (string.string-length else-not-final-name))
                      "0"))
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-call
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-clause-list-fold-if)
                      (string.int->string clauses-index)
                      "0"
                      "0"))
                  3)))
            (if (and
              (or
                (string.eq
                  (ci.intern-str fold-head)
                  "comptime.expr-list-fold-if")
                (string.eq (ci.intern-str fold-head) "expr-list-fold-if"))
              (= (compiler_ast_types.ast-expr-list-len (& fold-args)) 4))
              (let
                [items-index : i64
                  (embedded-native-var-param-index
                    params
                    (compiler_ast_types.ast-expr-list-get (& fold-args) 0 0))]
                [when-true : i64
                  (embedded-native-expr-bool-flag
                    (compiler_ast_types.ast-expr-list-get (& fold-args) 1 0))]
                [when-false : i64
                  (embedded-native-expr-bool-flag
                    (compiler_ast_types.ast-expr-list-get (& fold-args) 2 0))]
                [continue-flag : i64
                  (embedded-native-bool-literal-flag
                    (compiler_ast_types.ast-expr-list-get (& fold-args) 3 0))]
                (if (or
                  (< items-index 0)
                  (< when-true 0)
                  (< when-false 0)
                  (< continue-flag 0))
                  -1
                  (begin
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-call
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-bool-literal)
                        (string.int->string when-true)
                        "0"
                        "0"))
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-call
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-bool-literal)
                        (string.int->string when-false)
                        "0"
                        "0"))
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-call
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-list-fold-if)
                        (string.int->string items-index)
                        (string.int->string continue-flag)
                        "0"))
                    3)))
              (let
                [var-name : String (embedded-native-expr-var-name body-node)]
                (if (= (string.string-length var-name) 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-var)
                      (embedded-native-name-arg var-name)
                      (string.int->string (string.string-length var-name))
                      "0")
                    1)))))]
        [_ -1])]
    [_ -1]))

;: The literal name of a (comptime.expr-var "name") argument; "" otherwise.
(define (embedded-native-expr-var-name [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call var-func var-args)
      (match (embedded-stdlib-tlci-unwrap-expr var-func)
        [(compiler_ast_types.AstExpr.Var var-head)
          (if (and
            (or
              (string.eq (ci.intern-str var-head) "comptime.expr-var")
              (string.eq (ci.intern-str var-head) "expr-var"))
            (= (compiler_ast_types.ast-expr-list-len (& var-args)) 1))
            (match (embedded-stdlib-tlci-unwrap-expr
              (compiler_ast_types.ast-expr-list-get (& var-args) 0 0))
              [(compiler_ast_types.AstExpr.Literal lit)
                (match lit
                  [(compiler_ast_types.AstLiteral.String text)
                    (ci.intern-str text)]
                  [_ ""])]
              [_ ""])
            "")]
        [_ ""])]
    [_ ""]))

;: 1/0 for a (comptime.expr-bool <literal>) argument; -1 otherwise.
(define (embedded-native-expr-bool-flag [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call bool-func bool-args)
      (match (embedded-stdlib-tlci-unwrap-expr bool-func)
        [(compiler_ast_types.AstExpr.Var bool-head)
          (if (and
            (or
              (string.eq (ci.intern-str bool-head) "comptime.expr-bool")
              (string.eq (ci.intern-str bool-head) "expr-bool"))
            (= (compiler_ast_types.ast-expr-list-len (& bool-args)) 1))
            (embedded-native-bool-literal-flag
              (compiler_ast_types.ast-expr-list-get (& bool-args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

;: 1/0 for a literal bool node; -1 otherwise.
(define (embedded-native-bool-literal-flag [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Literal lit)
      (match lit
        [(compiler_ast_types.AstLiteral.Bool flag)
          (if flag
            1
            0)]
        [_ -1])]
    [_ -1]))

;; Escape `text` for embedding inside a generated source string literal. The
;; generated transformer source is re-lexed by the ordinary lexer, whose
;; string escapes are \\, \", \n, \t, and \r.
(define (embedded-native-escape-string [text : String]) : String
  (let
    [out : String ""]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (begin
      (while (< index length)
        (let
          [c : char (string.string-ref text index)]
          (begin
            (cond
              [(= c '\\') (set! out (str_cat.str-cat out "\\\\"))]
              [(= c '"') (set! out (str_cat.str-cat out "\\\""))]
              [(= c '\n') (set! out (str_cat.str-cat out "\\n"))]
              [(= c '\t') (set! out (str_cat.str-cat out "\\t"))]
              [(= c '\r') (set! out (str_cat.str-cat out "\\r"))]
              [else
                (set! out (str_cat.str-cat out (string.substring text index 1)))])
            (set! index (+ index 1)))))
      out)))

;; Push one neutral host-op call, keeping operation order stable across the
;; whole entry; consumers choose nested-data or flat-status rendering later.
(define (embedded-native-template-push!
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]
  [op : String]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : unit
  (embedded-native-ops-push!
    ops
    ops-count
    (embedded-native-op-call op arg-a arg-b arg-c)))

;; AstBinOp ordinal contract shared with the host callback consumer; the
;; embedded image and its consumer are always the same source-bound binary.
(define (embedded-native-binop-ordinal [op : compiler_ast_types.AstBinOp]) : i64
  (match op
    [(compiler_ast_types.AstBinOp.Add) 0]
    [(compiler_ast_types.AstBinOp.Sub) 1]
    [(compiler_ast_types.AstBinOp.Mul) 2]
    [(compiler_ast_types.AstBinOp.Div) 3]
    [(compiler_ast_types.AstBinOp.Mod) 4]
    [(compiler_ast_types.AstBinOp.Eq) 5]
    [(compiler_ast_types.AstBinOp.Ne) 6]
    [(compiler_ast_types.AstBinOp.Lt) 7]
    [(compiler_ast_types.AstBinOp.Le) 8]
    [(compiler_ast_types.AstBinOp.Gt) 9]
    [(compiler_ast_types.AstBinOp.Ge) 10]
    [(compiler_ast_types.AstBinOp.And) 11]
    [(compiler_ast_types.AstBinOp.Or) 12]
    [(compiler_ast_types.AstBinOp.BitAnd) 13]
    [(compiler_ast_types.AstBinOp.BitOr) 14]
    [(compiler_ast_types.AstBinOp.BitXor) 15]
    [(compiler_ast_types.AstBinOp.Shl) 16]
    [(compiler_ast_types.AstBinOp.Shr) 17]))

(define (embedded-native-unop-ordinal [op : compiler_ast_types.AstUnOp]) : i64
  (match op
    [(compiler_ast_types.AstUnOp.Neg) 0]
    [(compiler_ast_types.AstUnOp.Not) 1]
    [(compiler_ast_types.AstUnOp.BitNot) 2]))

(define (embedded-native-comparison-spelling [ordinal : i64]) : String
  (cond
    [(= ordinal 5) "="]
    [(= ordinal 6) "!="]
    [(= ordinal 7) "<"]
    [(= ordinal 8) "<="]
    [(= ordinal 9) ">"]
    [(= ordinal 10) ">="]
    [else "="]))

;; Emit the op chain for a template node that wraps exactly one subexpression
;; (`return`, `box`, `box-get`): the operand's chain followed by `op`. Returns
;; the opened op-let count or -1 when the operand is outside the supported
;; subset. Refs #5605.
(define (embedded-native-template-binary-node-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [first-node : i64]
  [second-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [first-opened : i64
      (embedded-native-template-ops params first-node ops ops-count)]
    (if (< first-opened 0)
      -1
      (let
        [second-opened : i64
          (embedded-native-template-ops params second-node ops ops-count)]
        (if (< second-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op "0" "0" "0")
            (+ first-opened second-opened 1)))))))

(define (embedded-native-template-unary-node-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [inner-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [inner-opened : i64
      (embedded-native-template-ops params inner-node ops ops-count)]
    (if (< inner-opened 0)
      -1
      (begin
        (embedded-native-template-push! ops ops-count op "0" "0" "0")
        (+ inner-opened 1)))))

;; Emit the op chain that pushes exactly one session-stack value for one
;; quasiquoted template node, mirroring the interpreted quote's reconstruction
;; of calls, if/begin/binary/unary forms, literals, plain symbols, unquoted
;; operands, and the intrinsic array nodes. Returns the number of opened op
;; lets, or -1 when the node is outside the supported template subset (the
;; caller then keeps the counted fallback shell). Refs #5596.
(define (embedded-native-template-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (begin
    (embedded-native-full-walked-note!
      (str_cat.str-cat
        "template-node:"
        (embedded-native-expr-kind-name (embedded-stdlib-tlci-unwrap-expr node))))
    (embedded-native-template-ops-inner params node ops ops-count)))

(define (embedded-native-template-ops-inner
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Unquote inner)
      (match (embedded-stdlib-tlci-unwrap-expr inner)
        [(compiler_ast_types.AstExpr.Var pname)
          (embedded-native-unquote-ops params pname ops ops-count)]
        ;; Any other unquoted operand is a computed comptime expression whose
        ;; value substitutes into the template, matching the interpreted
        ;; quote's unquote step. Refs #5617.
        [_ (embedded-native-computed-expr-ops params inner ops ops-count)])]
    [(compiler_ast_types.AstExpr.Literal lit)
      (match lit
        [(compiler_ast_types.AstLiteral.Bool flag)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-bool-literal)
              (if flag
                "1"
                "0")
              "0"
              "0")
            1)]
        [(compiler_ast_types.AstLiteral.Int value text)
          (if (or
            (= (string.string-length text) 0)
            (string.eq text (string.int->string value)))
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-expr-int-literal)
                (string.int->string value)
                "0"
                "0")
              1)
            -1)]
        [(compiler_ast_types.AstLiteral.String sid)
          (let
            [text : String (ci.intern-str sid)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-expr-string)
                (embedded-native-name-arg (embedded-native-escape-string text))
                (string.int->string (string.string-length text))
                "0")
              1))]
        [(compiler_ast_types.AstLiteral.Char c)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-char-literal)
              (string.int->string (cast c : i64))
              "0"
              "0")
            1)]
        [(compiler_ast_types.AstLiteral.Unit)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-unit-literal)
              "0"
              "0"
              "0")
            1)]
        [(compiler_ast_types.AstLiteral.Float text)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-float-literal)
              (embedded-native-name-arg (embedded-native-escape-string text))
              (string.int->string (string.string-length text))
              "0")
            1)]
        [_ -1])]
    [(compiler_ast_types.AstExpr.Var name-id)
      (let
        [name : String (ci.intern-str name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            (tlci_core.tlci-host-callback-name-shared-view
              tlci_core.tlci-host-callback-name-expr-var)
            (embedded-native-name-arg name)
            (string.int->string (string.string-length name))
            "0")
          1))]
    [(compiler_ast_types.AstExpr.Call func-id args)
      (let
        [source-span : EmbeddedNativeMaybeSourceSpan
          (embedded-native-call-head-source-span func-id)]
        [head-opened : i64
          (match (embedded-stdlib-tlci-unwrap-expr func-id)
            [(compiler_ast_types.AstExpr.Var head-id)
              (let
                [head : String (ci.intern-str head-id)]
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-expr-var)
                    (embedded-native-name-arg head)
                    (string.int->string (string.string-length head))
                    "0")
                  1))]
            ;; An unquoted head (a macro parameter or let-bound local used as
            ;; the call operator) builds like any other template expression.
            [_ (embedded-native-template-ops params func-id ops ops-count)])]
        (if (< head-opened 0)
          -1
          (let
            [arg-opened : i64
              (embedded-native-template-args-ops params (& args) ops ops-count)]
            (if (< arg-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-call)
                  (match source-span
                    [(EmbeddedNativeMaybeSourceSpan.Some span)
                      (string.int->string
                        (compiler_ast_types.ast-source-span-start-line span))]
                    [(EmbeddedNativeMaybeSourceSpan.None) "0"])
                  (match source-span
                    [(EmbeddedNativeMaybeSourceSpan.Some span)
                      (string.int->string
                        (compiler_ast_types.ast-source-span-start-col span))]
                    [(EmbeddedNativeMaybeSourceSpan.None) "0"])
                  (match source-span
                    [(EmbeddedNativeMaybeSourceSpan.Some span)
                      (string.int->string
                        (bit-or
                          (shl
                            (compiler_ast_types.ast-source-span-end-line span)
                            32)
                          (compiler_ast_types.ast-source-span-end-col span)))]
                    [(EmbeddedNativeMaybeSourceSpan.None) "0"]))
                (+ arg-opened 2))))))]
    [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
      (let
        [cond-opened : i64
          (embedded-native-template-ops params cond-node ops ops-count)]
        (if (< cond-opened 0)
          -1
          (let
            [then-opened : i64
              (embedded-native-template-ops params then-node ops ops-count)]
            (if (< then-opened 0)
              -1
              (let
                [else-opened : i64
                  (embedded-native-template-ops params else-node ops ops-count)]
                (if (< else-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-if)
                      "0"
                      "0"
                      "0")
                    (+ cond-opened then-opened else-opened 1))))))))]
    [(compiler_ast_types.AstExpr.Begin exprs)
      (let
        [arg-opened : i64
          (embedded-native-template-args-ops params (& exprs) ops ops-count)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-begin)
              "0"
              "0"
              "0")
            (+ arg-opened 1))))]
    [(compiler_ast_types.AstExpr.Tuple items)
      (let
        [item-opened : i64
          (embedded-native-template-args-ops params (& items) ops ops-count)]
        (if (< item-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-tuple)
              "0"
              "0"
              "0")
            (+ item-opened 1))))]
    [(compiler_ast_types.AstExpr.BracketClause items)
      (let
        [arg-opened : i64
          (embedded-native-template-args-ops params (& items) ops ops-count)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-bracket-clause)
              "0"
              "0"
              "0")
            (+ arg-opened 1))))]
    [(compiler_ast_types.AstExpr.Borrow mutable lifetime-id place)
      (let
        [lifetime : compiler_ast_types.AstBorrowLifetime
          (compiler_ast_types.ast-borrow-lifetime-from-id lifetime-id)]
        [place-opened : i64
          (embedded-native-template-ops params place ops ops-count)]
        (if (< place-opened 0)
          -1
          (match lifetime
            [(compiler_ast_types.AstBorrowLifetime.Inferred)
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-borrow)
                  (if mutable
                    "1"
                    "0")
                  "0"
                  "0")
                (+ place-opened 1))]
            [(compiler_ast_types.AstBorrowLifetime.Named lifetime-id)
              (let
                [lifetime-name : String (ci.intern-str lifetime-id)]
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-expr-borrow)
                    (if mutable
                      "1"
                      "0")
                    (embedded-native-name-arg lifetime-name)
                    (string.int->string (string.string-length lifetime-name)))
                  (+ place-opened 1)))]
            [_ -1])))]
    [(compiler_ast_types.AstExpr.Match match-box)
      (match (box-get match-box)
        [(compiler_ast_types.AstMatch.Match scrutinee arms)
          (let
            [scrut-opened : i64
              (embedded-native-template-ops params scrutinee ops ops-count)]
            (if (< scrut-opened 0)
              -1
              (let
                [arms-opened : i64
                  (embedded-native-template-match-arms-ops
                    params
                    (& arms)
                    ops
                    ops-count)]
                (if (< arms-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-match)
                      "0"
                      "0"
                      "0")
                    (+ scrut-opened arms-opened 1))))))])]
    [(compiler_ast_types.AstExpr.StructGet target field)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [field-name : String (ci.intern-str field)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-expr-struct-get)
                (embedded-native-name-arg field-name)
                (string.int->string (string.string-length field-name))
                "0")
              (+ target-opened 1)))))]
    [(compiler_ast_types.AstExpr.ArraySet target index value)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [index-opened : i64
              (embedded-native-template-ops params index ops ops-count)]
            (if (< index-opened 0)
              -1
              (let
                [value-opened : i64
                  (embedded-native-template-ops params value ops ops-count)]
                (if (< value-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-array-set)
                      "0"
                      "0"
                      "0")
                    (+ target-opened index-opened value-opened 1))))))))]
    [(compiler_ast_types.AstExpr.Let let-box)
      (match (box-get let-box)
        [(compiler_ast_types.AstLet.Let bindings body)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-let-binding-list-empty)
              "0"
              "0"
              "0")
            (let
              [bindings-opened : i64
                (embedded-native-template-let-bindings-ops
                  params
                  (& bindings)
                  0
                  ops
                  ops-count)]
              (if (< bindings-opened 0)
                -1
                (let
                  [body-opened : i64
                    (embedded-native-template-ops params body ops ops-count)]
                  (if (< body-opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-let)
                        "0"
                        "0"
                        "0")
                      (+ bindings-opened body-opened 2)))))))])]
    [(compiler_ast_types.AstExpr.Binary op left-node right-node)
      (let
        [left-opened : i64
          (embedded-native-template-ops params left-node ops ops-count)]
        (if (< left-opened 0)
          -1
          (let
            [right-opened : i64
              (embedded-native-template-ops params right-node ops ops-count)]
            (if (< right-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-binary-op)
                  (string.int->string (embedded-native-binop-ordinal op))
                  "0"
                  "0")
                (+ left-opened right-opened 1))))))]
    [(compiler_ast_types.AstExpr.Unary op inner-node)
      (let
        [inner-opened : i64
          (embedded-native-template-ops params inner-node ops ops-count)]
        (if (< inner-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-unary-op)
              (string.int->string (embedded-native-unop-ordinal op))
              "0"
              "0")
            (+ inner-opened 1))))]
    [(compiler_ast_types.AstExpr.Return inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-return)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.Box inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-box)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.BoxGet inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-box-get)
        ops
        ops-count)]
    ;; Raw-pointer and `unsafe` template nodes, the last shapes the
    ;; `stdlib.text_buf_family` generators need. Refs #5605.
    [(compiler_ast_types.AstExpr.PtrRead inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-ptr-read)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.PtrToInt inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-ptr-to-int)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.StringData inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-string-data)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.PtrWrite ptr-node value-node)
      (embedded-native-template-binary-node-ops
        params
        ptr-node
        value-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-ptr-write)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.PtrOffset ptr-node offset-node)
      (embedded-native-template-binary-node-ops
        params
        ptr-node
        offset-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-ptr-offset)
        ops
        ops-count)]
    ;; `(ptr-cast p : T)`: the pointer expression then the type template, the
    ;; same operand order expr-make-array uses. Refs #5605.
    [(compiler_ast_types.AstExpr.PtrCast ptr-node cast-type-id)
      (let
        [ptr-opened : i64
          (embedded-native-template-ops params ptr-node ops ops-count)]
        (if (< ptr-opened 0)
          -1
          (let
            [type-opened : i64
              (embedded-native-template-type-ops
                params
                (compiler_ast_types.ty-node-get cast-type-id)
                ops
                ops-count)]
            (if (< type-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-ptr-cast)
                  "0"
                  "0"
                  "0")
                (+ ptr-opened type-opened 1))))))]
    [(compiler_ast_types.AstExpr.ArrayData inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-array-data)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.StringFromBytes data-node length-node)
      (embedded-native-template-binary-node-ops
        params
        data-node
        length-node
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-string-from-bytes)
        ops
        ops-count)]
    [(compiler_ast_types.AstExpr.Unsafe body-exprs)
      (let
        [arg-opened : i64
          (embedded-native-template-args-ops
            params
            (& body-exprs)
            ops
            ops-count)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-expr-unsafe)
              "0"
              "0"
              "0")
            (+ arg-opened 1))))]
    ;; `(set! (struct-get target field) value)`. The parser folds the place into
    ;; the node, so the field name travels as an immediate like struct-get's.
    ;; The sentinel field id marks `(set! ,place value)`, whose place shape is
    ;; only known once the unquoted operand is evaluated; that stays a fallback.
    [(compiler_ast_types.AstExpr.StructSet target-node field value-node)
      (if (= field (compiler_ast_types.ast-expr-unquote-set-target-field-id))
        -1
        (let
          [target-opened : i64
            (embedded-native-template-ops params target-node ops ops-count)]
          (if (< target-opened 0)
            -1
            (let
              [value-opened : i64
                (embedded-native-template-ops params value-node ops ops-count)]
              (if (< value-opened 0)
                -1
                (let
                  [field-name : String (ci.intern-str field)]
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-struct-set)
                      (embedded-native-name-arg field-name)
                      (string.int->string (string.string-length field-name))
                      "0")
                    (+ target-opened value-opened 1))))))))]
    ;; `(cast e : T)`: the operand template then the type template, matching
    ;; the interpreted quote's cast reconstruction. Refs #5604.
    [(compiler_ast_types.AstExpr.Cast value-node ty-id)
      (let
        [value-opened : i64
          (embedded-native-template-ops params value-node ops ops-count)]
        (if (< value-opened 0)
          -1
          (let
            [type-opened : i64
              (embedded-native-template-type-ops
                params
                (compiler_ast_types.ty-node-get ty-id)
                ops
                ops-count)]
            (if (< type-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-cast)
                  "0"
                  "0"
                  "0")
                (+ value-opened type-opened 1))))))]
    ;; `(ann e : T)` has the same stack shape as `cast`, but preserves the
    ;; annotation node so integer literals keep their requested scalar type.
    [(compiler_ast_types.AstExpr.Ann value-node ty-id)
      (let
        [value-opened : i64
          (embedded-native-template-ops params value-node ops ops-count)]
        (if (< value-opened 0)
          -1
          (let
            [type-opened : i64
              (embedded-native-template-type-ops
                params
                (compiler_ast_types.ty-node-get ty-id)
                ops
                ops-count)]
            (if (< type-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-ann)
                  "0"
                  "0"
                  "0")
                (+ value-opened type-opened 1))))))]
    ;; Typed `(init : T)`: quote the annotation as a type value, then let the
    ;; host reconstruct the same Init node as interpreted quasiquote. Refs
    ;; #5606.
    [(compiler_ast_types.AstExpr.Init maybe-ty-id)
      (match (compiler_ast_types.ast-maybe-type-from-id maybe-ty-id)
        [(compiler_ast_types.AstMaybeType.Some ty)
          (let
            [type-opened : i64
              (embedded-native-template-type-ops params ty ops ops-count)]
            (if (< type-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-init)
                  "0"
                  "0"
                  "0")
                (+ type-opened 1))))]
        [_ -1])]
    [(compiler_ast_types.AstExpr.Set name-id value-node)
      (let
        [value-opened : i64
          (embedded-native-template-ops params value-node ops ops-count)]
        (if (< value-opened 0)
          -1
          (let
            [name : String (ci.intern-str name-id)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-expr-set-var)
                (embedded-native-name-arg name)
                (string.int->string (string.string-length name))
                "0")
              (+ value-opened 1)))))]
    [(compiler_ast_types.AstExpr.While cond-node body-node)
      (let
        [cond-opened : i64
          (embedded-native-template-ops params cond-node ops ops-count)]
        (if (< cond-opened 0)
          -1
          (let
            [body-opened : i64
              (embedded-native-template-ops params body-node ops ops-count)]
            (if (< body-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-while)
                  "0"
                  "0"
                  "0")
                (+ cond-opened body-opened 1))))))]
    [(compiler_ast_types.AstExpr.ArrayRef target-node index-node)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target-node ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [index-opened : i64
              (embedded-native-template-ops params index-node ops ops-count)]
            (if (< index-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-array-ref)
                  "0"
                  "0"
                  "0")
                (+ target-opened index-opened 1))))))]
    [(compiler_ast_types.AstExpr.ArrayPush target-node value-node)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target-node ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [value-opened : i64
              (embedded-native-template-ops params value-node ops ops-count)]
            (if (< value-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-array-push)
                  "0"
                  "0"
                  "0")
                (+ target-opened value-opened 1))))))]
    [(compiler_ast_types.AstExpr.MakeArray elem-type-id size-node)
      (let
        [type-opened : i64
          (embedded-native-template-type-ops
            params
            (compiler_ast_types.ty-node-get elem-type-id)
            ops
            ops-count)]
        (if (< type-opened 0)
          -1
          (let
            [size-opened : i64
              (embedded-native-template-ops params size-node ops ops-count)]
            (if (< size-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-make-array)
                  "0"
                  "0"
                  "0")
                (+ type-opened size-opened 1))))))]
    [_
      (embedded-native-fallback-opened
        (str_cat.str-cat
          "template-node:"
          (embedded-native-expr-kind-name
            (embedded-stdlib-tlci-unwrap-expr node))))]))

;; Emit ops building one template argument/expression list: expr-list-empty,
;; then per item either list-append of a pushed template value or expr-splice
;; of a variadic operand's whole ExprList, matching the interpreted quote's
;; unquote-splicing step. Returns the opened op-let count or -1 when an item
;; is outside the supported subset.
(define (embedded-native-template-args-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [args : (& args compiler_ast_types.AstExprList)]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [count : i64 (compiler_ast_types.ast-expr-list-len args)]
    [index : i64 0]
    [opened : i64 1]
    [ok : bool true]
    (begin
      (embedded-native-template-push!
        ops
        ops-count
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-expr-list-empty)
        "0"
        "0"
        "0")
      (while (and ok (< index count))
        (let
          [item : i64 (compiler_ast_types.ast-expr-list-get args index 0)]
          (match (embedded-stdlib-tlci-unwrap-expr item)
            [(compiler_ast_types.AstExpr.UnquoteSplicing inner)
              (match (embedded-stdlib-tlci-unwrap-expr inner)
                [(compiler_ast_types.AstExpr.Var pname)
                  (let
                    [param : i64
                      (embedded-stdlib-tlci-param-index params pname)]
                    [slot : i64
                      (if (< param 0)
                        (embedded-native-local-index (ci.intern-str pname))
                        -1)]
                    (if (and (< param 0) (< slot 0))
                      (set! ok false)
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          (if (< param 0)
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-local-get)
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-push-operand))
                          (string.int->string
                            (if (< param 0)
                              slot
                              param))
                          "0"
                          "0")
                        (embedded-native-template-push!
                          ops
                          ops-count
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-expr-splice)
                          "0"
                          "0"
                          "0")
                        (set! opened (+ opened 2))
                        (set! index (+ index 1)))))]
                [_
                  (begin
                    (embedded-native-fallback-reason-note!
                      "template-splice:non-variable")
                    (when
                      (not embedded-native-full-blocker-diagnostic-active)
                      (set! ok false)))])]
            [_
              (let
                [item-opened : i64
                  (embedded-native-template-ops params item ops ops-count)]
                (if (< item-opened 0)
                  (set! ok false)
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-list-append)
                      "0"
                      "0"
                      "0")
                    (set! opened (+ opened item-opened 1))
                    (set! index (+ index 1)))))])))
      (if ok
        opened
        -1))))

;; Emit ops building one template match arm list: match-arm-list-empty, then
;; per arm the pattern, the body template, match-arm, and match-arm-list-cons.
;; Returns the opened op-let count or -1 when any piece is outside the
;; supported subset. Refs #5603.
(define (embedded-native-template-match-arms-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [count : i64 (struct-get arms len)]
    [index : i64 0]
    [opened : i64 1]
    [ok : bool true]
    (begin
      (embedded-native-template-push!
        ops
        ops-count
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-match-arm-list-empty)
        "0"
        "0"
        "0")
      (while (and ok (< index count))
        (match (array-ref (struct-get arms slots) index)
          [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
            (let
              [pat-opened : i64
                (match pattern
                  [(compiler_ast_types.AstPattern.Wildcard)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-pattern-wildcard)
                        "0"
                        "0"
                        "0")
                      1)]
                  [(compiler_ast_types.AstPattern.Binding pat-name-id)
                    (let
                      [pat-name : String (ci.intern-str pat-name-id)]
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-pattern-binding)
                          (embedded-native-name-arg pat-name)
                          (string.int->string (string.string-length pat-name))
                          "0")
                        1))]
                  [(compiler_ast_types.AstPattern.Var pat-name-id pat-maybe-ty)
                    (match pat-maybe-ty
                      [(compiler_ast_types.AstMaybeType.No)
                        (let
                          [pat-name : String (ci.intern-str pat-name-id)]
                          (begin
                            (embedded-native-template-push!
                              ops
                              ops-count
                              (tlci_core.tlci-host-callback-name-shared-view
                                tlci_core.tlci-host-callback-name-pattern-var)
                              (embedded-native-name-arg pat-name)
                              (string.int->string
                                (string.string-length pat-name))
                              "0")
                            1))]
                      [_ -1])]
                  [(compiler_ast_types.AstPattern.Variant
                      pat-name-id
                      pat-args-box)
                    (let
                      [pat-name : String (ci.intern-str pat-name-id)]
                      [pat-args : compiler_ast_types.AstPatternList
                        (box-get pat-args-box)]
                      [pat-arg-opened : i64
                        (embedded-native-pattern-list-ops
                          (& pat-args)
                          0
                          ops
                          ops-count
                          0)]
                      (if (< pat-arg-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-pattern-variant)
                            (embedded-native-name-arg pat-name)
                            (string.int->string (string.string-length pat-name))
                            (string.int->string (struct-get (& pat-args) len)))
                          (+ pat-arg-opened 1))))]
                  [_
                    (embedded-native-fallback-opened
                      "template-match-arm:unsupported-pattern")])]
              (if (< pat-opened 0)
                (set! ok false)
                (let
                  [body-opened : i64
                    (embedded-native-template-ops
                      params
                      body-node
                      ops
                      ops-count)]
                  (if (< body-opened 0)
                    (set! ok false)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-match-arm)
                        "0"
                        "0"
                        "0")
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-match-arm-list-cons)
                        "0"
                        "0"
                        "0")
                      (set! opened (+ opened pat-opened body-opened 2))
                      (set! index (+ index 1)))))))]
          [_ (set! ok false)]))
      (if ok
        opened
        -1))))

;; Emit the ops producing one template pattern. Variant constructor names pass
;; through unmarked; binding and unit-variable names carry the template-source
;; mark, matching the interpreted quote. Returns the opened op-let count or
;; -1 outside the supported subset.
(define (embedded-native-pattern-ops
  [pattern : compiler_ast_types.AstPattern]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (match pattern
    [(compiler_ast_types.AstPattern.Wildcard)
      (begin
        (embedded-native-template-push!
          ops
          ops-count
          (tlci_core.tlci-host-callback-name-shared-view
            tlci_core.tlci-host-callback-name-pattern-wildcard)
          "0"
          "0"
          "0")
        1)]
    [(compiler_ast_types.AstPattern.Binding name-id)
      (let
        [name : String (ci.intern-str name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            (tlci_core.tlci-host-callback-name-shared-view
              tlci_core.tlci-host-callback-name-pattern-binding)
            (embedded-native-name-arg name)
            (string.int->string (string.string-length name))
            "0")
          1))]
    [(compiler_ast_types.AstPattern.Var name-id maybe-ty)
      (match maybe-ty
        [(compiler_ast_types.AstMaybeType.No)
          (let
            [name : String (ci.intern-str name-id)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-pattern-var)
                (embedded-native-name-arg name)
                (string.int->string (string.string-length name))
                "0")
              1))]
        [_ -1])]
    [(compiler_ast_types.AstPattern.Variant name-id args-box)
      (let
        [name : String (ci.intern-str name-id)]
        [args : compiler_ast_types.AstPatternList (box-get args-box)]
        [arg-opened : i64
          (embedded-native-pattern-list-ops (& args) 0 ops ops-count 0)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-pattern-variant)
              (embedded-native-name-arg name)
              (string.int->string (string.string-length name))
              (string.int->string (struct-get (& args) len)))
            (+ arg-opened 1))))]
    [_ (embedded-native-fallback-opened "template-pattern:unsupported")]))

(define (embedded-native-pattern-list-ops
  [args : (& args compiler_ast_types.AstPatternList)]
  [index : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]
  [opened : i64]) : i64
  (if (>= index (struct-get args len))
    opened
    (let
      [item-opened : i64
        (embedded-native-pattern-ops
          (compiler_ast_types.ast-pattern-list-get
            args
            index
            (compiler_ast_types.ast-pattern-fallback))
          ops
          ops-count)]
      (if (< item-opened 0)
        -1
        (embedded-native-pattern-list-ops
          args
          (+ index 1)
          ops
          ops-count
          (+ opened item-opened))))))

;; Scalar AstType ordinal contract shared with the host callback consumer;
;; the embedded image and its consumer are always the same source-bound
;; binary. Refs #5603.
(define (embedded-native-scalar-type-ordinal [ty : compiler_ast_types.AstType]) : i64
  (match ty
    [(compiler_ast_types.AstType.I64) 0]
    [(compiler_ast_types.AstType.I32) 1]
    [(compiler_ast_types.AstType.I16) 2]
    [(compiler_ast_types.AstType.I8) 3]
    [(compiler_ast_types.AstType.U64) 4]
    [(compiler_ast_types.AstType.U32) 5]
    [(compiler_ast_types.AstType.U16) 6]
    [(compiler_ast_types.AstType.U8) 7]
    [(compiler_ast_types.AstType.F64) 8]
    [(compiler_ast_types.AstType.F32) 9]
    [(compiler_ast_types.AstType.Bool) 10]
    [(compiler_ast_types.AstType.Char) 11]
    [(compiler_ast_types.AstType.String) 12]
    [(compiler_ast_types.AstType.Str) 13]
    [(compiler_ast_types.AstType.Bytes) 14]
    [(compiler_ast_types.AstType.Expr) 15]
    [(compiler_ast_types.AstType.ExprList) 16]
    [(compiler_ast_types.AstType.Unit) 17]
    [(compiler_ast_types.AstType.Never) 18]
    [_ -1]))

;; Emit ops building one template let-binding list: empty, then per binding
;; the init template, the (possibly typed) binding, and cons. Plain `Var`
;; type annotations pass through as type-var; unquoted annotations are not
;; supported yet (the caller keeps the fallback shell). Returns the opened
;; op-let count or -1 outside the subset.
;; Emit the type-template ops for one binding annotation: plain `Var` names
;; and scalar types. Other shapes keep the fallback shell. Returns the opened
;; op-let count or -1 outside the subset.
;; The element/inner type template followed by a one-immediate wrapper op.
(define (embedded-native-template-type-wrap-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [elem-id : i64]
  [op : String]
  [immediate : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [elem-opened : i64
      (embedded-native-template-type-ops
        params
        (compiler_ast_types.ty-node-get elem-id)
        ops
        ops-count)]
    (if (< elem-opened 0)
      -1
      (begin
        (embedded-native-template-push! ops ops-count op immediate "0" "0")
        (+ elem-opened 1)))))

;; `(& r T)` / `(&mut r T)`: the inner template, then the wrapper carrying the
;; mutability flag and the lifetime name.
(define (embedded-native-template-type-ref-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [inner-id : i64]
  [region-id : i64]
  [mutable : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [region : String (ci.intern-str region-id)]
    [inner-opened : i64
      (embedded-native-template-type-ops
        params
        (compiler_ast_types.ty-node-get inner-id)
        ops
        ops-count)]
    (if (< inner-opened 0)
      -1
      (begin
        (embedded-native-template-push!
          ops
          ops-count
          (tlci_core.tlci-host-callback-name-shared-view
            tlci_core.tlci-host-callback-name-type-ref)
          (string.int->string mutable)
          (embedded-native-name-arg region)
          (string.int->string (string.string-length region)))
        (+ inner-opened 1)))))

(define (embedded-native-template-type-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [ty : compiler_ast_types.AstType]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (match ty
    ;; Composite annotations: the element/inner type is a *type-pool node id*,
    ;; read back through the global `ty-node-get` (the type-side twin of
    ;; `ast-node-get`), so no pool context has to be threaded here. Each arm
    ;; emits its element template then the wrapper op. Refs #5605.
    [(compiler_ast_types.AstType.Ptr elem-id)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-ptr)
        "0"
        ops
        ops-count)]
    [(compiler_ast_types.AstType.MutPtr elem-id)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-ptr)
        "1"
        ops
        ops-count)]
    [(compiler_ast_types.AstType.Box elem-id)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-box)
        "0"
        ops
        ops-count)]
    [(compiler_ast_types.AstType.DynArray elem-id)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-dyn-array)
        "0"
        ops
        ops-count)]
    [(compiler_ast_types.AstType.Slice elem-id)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-slice)
        "0"
        ops
        ops-count)]
    [(compiler_ast_types.AstType.Array elem-id count)
      (embedded-native-template-type-wrap-ops
        params
        elem-id
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-type-array)
        (string.int->string count)
        ops
        ops-count)]
    [(compiler_ast_types.AstType.Ref region-id inner-id)
      (embedded-native-template-type-ref-ops
        params
        inner-id
        region-id
        0
        ops
        ops-count)]
    [(compiler_ast_types.AstType.MutRef region-id inner-id)
      (embedded-native-template-type-ref-ops
        params
        inner-id
        region-id
        1
        ops
        ops-count)]
    ;; Quasiquoted `,T` in type position is represented by the parser as the
    ;; internal `(unquote T)` VarArgs sentinel. Mirror interpreted quote
    ;; evaluation by pushing either the direct type operand or a computed
    ;; let-bound type value. Refs #5606.
    [(compiler_ast_types.AstType.VarArgs name lifetimes-box)
      (let
        [lifetimes : compiler_ast_types.AstLifetimeList (box-get lifetimes-box)]
        [valid : bool
          (and
            (= name cbi.compiler-builtin-id-fix-unquote)
            (= (compiler_ast_types.ast-lifetime-list-len (& lifetimes)) 1))]
        [operand-name : i64
          (if valid
            (compiler_ast_types.ast-lifetime-list-get
              (& lifetimes)
              0
              (compiler_ast_types.ast-lifetime-fallback))
            -1)]
        [param : i64
          (if valid
            (embedded-stdlib-tlci-param-index params operand-name)
            -1)]
        [slot : i64
          (if (and valid (< param 0))
            (embedded-native-local-index (ci.intern-str operand-name))
            -1)]
        (if (and (< param 0) (< slot 0))
          (embedded-native-fallback-opened "template-type:non-scalar")
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (if (>= param 0)
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-push-operand)
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-local-get))
              (string.int->string
                (if (>= param 0)
                  param
                  slot))
              "0"
              "0")
            1)))]
    [(compiler_ast_types.AstType.Var type-name-id)
      (let
        [type-name : String (ci.intern-str type-name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            (tlci_core.tlci-host-callback-name-shared-view
              tlci_core.tlci-host-callback-name-type-var)
            (embedded-native-name-arg type-name)
            (string.int->string (string.string-length type-name))
            "0")
          1))]
    [_
      (let
        [ordinal : i64 (embedded-native-scalar-type-ordinal ty)]
        (if (< ordinal 0)
          (embedded-native-fallback-opened "template-type:non-scalar")
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-type-scalar)
              (string.int->string ordinal)
              "0"
              "0")
            1)))]))

(define (embedded-native-template-let-bindings-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [bindings : (& bindings compiler_ast_types.AstLetBindingList)]
  [index : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (if (>= index (struct-get bindings len))
    0
    (match (compiler_ast_types.ast-let-binding-list-get
      bindings
      index
      (compiler_ast_types.ast-let-binding-fallback))
      [(compiler_ast_types.AstLetBinding.Binding name-id maybe-ty init)
        (let
          [name : String (ci.intern-str name-id)]
          [init-opened : i64
            (embedded-native-template-ops params init ops ops-count)]
          (if (< init-opened 0)
            -1
            (let
              [binding-opened : i64
                (match maybe-ty
                  [(compiler_ast_types.AstMaybeType.No)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-let-binding)
                        (embedded-native-name-arg name)
                        (string.int->string (string.string-length name))
                        "0")
                      1)]
                  [(compiler_ast_types.AstMaybeType.Some ty)
                    (let
                      [type-opened : i64
                        (embedded-native-template-type-ops
                          params
                          ty
                          ops
                          ops-count)]
                      (if (< type-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-let-binding-typed)
                            (embedded-native-name-arg name)
                            (string.int->string (string.string-length name))
                            "0")
                          (+ type-opened 1))))]
                  [_
                    (embedded-native-fallback-opened
                      "template-let-binding:unsupported")])]
              (if (< binding-opened 0)
                -1
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-let-binding-list-cons)
                    "0"
                    "0"
                    "0")
                  (let
                    [rest-opened : i64
                      (embedded-native-template-let-bindings-ops
                        params
                        bindings
                        (+ index 1)
                        ops
                        ops-count)]
                    (if (< rest-opened 0)
                      -1
                      (+ init-opened binding-opened 1 rest-opened))))))))]
      [_ -1])))

;; Preserve the exact legacy nested source shape for ordinary-sized arms.
(define (embedded-native-arm-block-legacy
  [ops : (__tl_dyn-array String)]
  [ops-count : i64]
  [opened : i64]
  [final : String]) : String
  (let
    [out : String (embedded-native-ops-open-text ops ops-count)]
    (str_cat.str-cat out final (embedded-native-closing-parens (* 2 opened)))))

;; Bound lowering depth only for the rare arms whose callback count exceeds the
;; legacy chain cap. Each chunk remains a balanced nested chain; the outer
;; status block sequences those chunks without constructing one giant AST.
(define (embedded-native-arm-block-chunked
  [ops : (__tl_dyn-array String)]
  [ops-count : i64]
  [final : String]) : String
  (let
    [out : String "  (let [qstatus : i64 0]\n    (begin\n"]
    [start : i64 0]
    [chunk-index : i64 0]
    (begin
      (while (< start ops-count)
        (let
          [remaining : i64 (- ops-count start)]
          [chunk-count : i64
            (if (< remaining embedded-native-op-chunk-cap)
              remaining
              embedded-native-op-chunk-cap)]
          [chunk : String
            (str_cat.str-cat
              (embedded-native-ops-open-text-range ops start chunk-count)
              "0\n"
              (embedded-native-closing-parens (* 2 chunk-count)))]
          (begin
            (set!
              out
              (str_cat.str-cat
                out
                (if (= chunk-index 0)
                  (str_cat.str-cat "      (set! qstatus " chunk ")\n")
                  (str_cat.str-cat
                    "      (if (= qstatus 0)\n"
                    "        (set! qstatus "
                    chunk
                    ")\n"
                    "        unit)\n"))))
            (set! start (+ start chunk-count))
            (set! chunk-index (+ chunk-index 1)))))
      (set!
        out
        (str_cat.str-cat
          out
          "      (if (not (= qstatus 0))\n"
          "        qstatus\n"
          "        "
          final
          "      )))\n"))
      out)))

;; Full source for the native package: the host extern plus one entry function
;; per identity in catalog order. Keep small entries byte-shaped as before and
;; use bounded status chunks only when the old chain would be too deep.
(define (embedded-native-arm-block-with-final
  [ops : (__tl_dyn-array String)]
  [ops-count : i64]
  [opened : i64]
  [final : String]) : String
  (if (<= ops-count embedded-native-op-chunk-cap)
    (embedded-native-arm-block-legacy ops ops-count opened final)
    (embedded-native-arm-block-chunked ops ops-count final)))

(define (embedded-native-arm-block
  [ops : (__tl_dyn-array String)]
  [ops-count : i64]
  [opened : i64]) : String
  (embedded-native-arm-block-with-final
    ops
    ops-count
    opened
    "  (comptime-host-commit-result host session 0 0 0)\n"))

(define (embedded-native-var-param-index
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Var pname)
      (embedded-stdlib-tlci-param-index params pname)]
    [_ -1]))

;; Emit the op chain for one computed (non-template) expression, producing
;; exactly one session value: string literals as comptime String values,
;; string-append, the expr-var builder, type-key/type-kind reflection on a
;; type parameter, a parameter operand, or a let-bound local. Returns the
;; opened op-let count, or -1 outside the subset. Refs #5603.
(define (embedded-native-computed-expr-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (begin
    (embedded-native-full-walked-note!
      (str_cat.str-cat
        "computed-node:"
        (embedded-native-expr-kind-name (embedded-stdlib-tlci-unwrap-expr node))))
    (embedded-native-computed-expr-ops-inner params node ops ops-count)))

(define (embedded-native-computed-expr-ops-inner
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    ;; A quasiquote in computed position produces the same expression value as
    ;; a body-level template; reuse the template walker for its inner syntax.
    ;; This is needed for computed match-arm bodies in enum dispatch. Refs
    ;; #5626.
    [(compiler_ast_types.AstExpr.Quasiquote inner)
      (embedded-native-template-ops params inner ops ops-count)]
    [(compiler_ast_types.AstExpr.Literal lit)
      (match lit
        [(compiler_ast_types.AstLiteral.String sid)
          (let
            [text : String (ci.intern-str sid)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-string-value)
                (embedded-native-name-arg (embedded-native-escape-string text))
                (string.int->string (string.string-length text))
                "0")
              1))]
        [(compiler_ast_types.AstLiteral.Unit)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              (tlci_core.tlci-host-callback-name-shared-view
                tlci_core.tlci-host-callback-name-value-unit)
              "0"
              "0"
              "0")
            1)]
        [_ -1])]
    ;; A computed choice between two already-bound values can stay in the
    ;; linear op protocol by staging both Vars and selecting with the generated
    ;; i64 condition. Restricting both branches to Var keeps eager staging
    ;; observationally equivalent to interpreted `if`. Refs #5606.
    [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
      (let
        [condition : String (embedded-native-data-index-text cond-node)]
        [safe : bool
          (and
            (match (embedded-stdlib-tlci-unwrap-expr then-node)
              [(compiler_ast_types.AstExpr.Var _) true]
              [_ false])
            (match (embedded-stdlib-tlci-unwrap-expr else-node)
              [(compiler_ast_types.AstExpr.Var _) true]
              [_ false]))]
        (if (or (string.eq condition "") (not safe))
          -1
          (let
            [then-opened : i64
              (embedded-native-computed-expr-ops params then-node ops ops-count)]
            (if (< then-opened 0)
              -1
              (let
                [else-opened : i64
                  (embedded-native-computed-expr-ops
                    params
                    else-node
                    ops
                    ops-count)]
                (if (< else-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-value-select)
                      condition
                      "0"
                      "0")
                    (+ then-opened else-opened 1))))))))]
    [(compiler_ast_types.AstExpr.Var pname)
      (embedded-native-unquote-ops params pname ops ops-count)]
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            [argc : i64 (compiler_ast_types.ast-expr-list-len (& args))]
            [_walked : unit
              (embedded-native-full-walked-note!
                (str_cat.str-cat "computed-call:" head))]
            (cond
              [(and
                  (or
                    (string.eq head "comptime.string-append")
                    (string.eq head "string-append"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-string-append)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.syntax-name-fresh")
                    (string.eq head "syntax-name-fresh"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-syntax-name-fresh)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              [(and
                  (or
                    (string.eq head "comptime.expr-begin-unit")
                    (string.eq head "expr-begin-unit"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-begin-unit)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              ;; `(comptime.int->string n)` over a computed i64 value: the host
              ;; op mirrors the interpreted builtin. Refs #5700.
              [(and
                  (or
                    (string.eq head "comptime.int->string")
                    (string.eq head "int->string"))
                  (= argc 1))
                (let
                  [data-text : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  (if (not (string.eq data-text ""))
                    ;; A literal or compile-time data local: stage it as a
                    ;; comptime i64 first, since only stack values reach 113.
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-value-i64)
                        data-text
                        "0"
                        "0")
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-int->string)
                        "0"
                        "0"
                        "0")
                      ;; Two ops were pushed; the caller closes one op-let per
                      ;; counted op, so returning 1 here leaves the generated
                      ;; arm one paren short of balanced.
                      2)
                    (let
                      [opened : i64
                        (embedded-native-computed-expr-ops
                          params
                          (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                          ops
                          ops-count)]
                      (if (< opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-int->string)
                            "0"
                            "0"
                            "0")
                          (+ opened 1))))))]
              [(and
                  (or
                    (string.eq head "comptime.expr-var")
                    (string.eq head "expr-var"))
                  (= argc 1))
                (let
                  [lit-name : String (embedded-native-expr-var-name node)]
                  (if (> (string.string-length lit-name) 0)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-var)
                        (embedded-native-name-arg lit-name)
                        (string.int->string (string.string-length lit-name))
                        "0")
                      1)
                    (let
                      [inner-opened : i64
                        (embedded-native-computed-expr-ops
                          params
                          (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                          ops
                          ops-count)]
                      (if (< inner-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-expr-var-from-value)
                            "0"
                            "0"
                            "0")
                          (+ inner-opened 1))))))]
              ;; Module operands arrive as canonical identity Strings. Preserve
              ;; that value through the module-name op so computed consumers use
              ;; same identity as interpreted `(comptime.module-name format)`.
              [(and
                  (or
                    (string.eq head "comptime.module-name")
                    (string.eq head "module-name"))
                  (= argc 1))
                (let
                  [inner-opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< inner-opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-module-name)
                        "0"
                        "0"
                        "0")
                      (+ inner-opened 1))))]
              ;; Resolve a literal or computed hook name against a Module
              ;; operand through the host's interpreted-CTFE export index.
              [(and
                  (or
                    (string.eq head "comptime.module-hook")
                    (string.eq head "module-hook"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-module-hook)
                  ops
                  ops-count)]
              ;; Resolve the public signature recorded for a module value. Both
              ;; names are computed Strings/Names, and the host replaces them
              ;; with the reflected type just like interpreted CTFE. Refs #5606.
              [(and
                  (or
                    (string.eq head "comptime.module-value-type")
                    (string.eq head "module-value-type"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-module-value-type)
                  ops
                  ops-count)]
              ;; `(comptime.expr-type e)`: the checked type of an Expr operand
              ;; or let-bound expression value. Refs #5626, #5606.
              [(and
                  (or
                    (string.eq head "comptime.expr-type")
                    (string.eq head "expr-type"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-type)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              ;; `(comptime.expr-string-value p)`: the literal text of a
              ;; string-literal Expr operand, as a comptime String value.
              ;; Refs #5626.
              [(and
                  (or
                    (string.eq head "comptime.expr-string-value")
                    (string.eq head "expr-string-value"))
                  (= argc 1))
                (let
                  [param : i64
                    (embedded-native-var-param-index
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  (if (< param 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-operand-expr-string-value)
                        (string.int->string param)
                        "0"
                        "0")
                      1)))]
              ;; `(comptime.expr-string e)`: the argument's comptime String
              ;; value becomes a string-literal expression, carrying the same
              ;; intern id the interpreted builder reuses. Refs #5701.
              [(and
                  (or
                    (string.eq head "comptime.expr-string")
                    (string.eq head "expr-string"))
                  (= argc 1))
                (let
                  [inner-opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< inner-opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-string-from-value)
                        "0"
                        "0"
                        "0")
                      (+ inner-opened 1))))]
              ;; `(comptime.string-slice <String local> start len)`: the host
              ;; slices the bound local and pushes the generated String value,
              ;; with start and length as computed data immediates. Refs #5701.
              [(and
                  (or
                    (string.eq head "comptime.string-slice")
                    (string.eq head "string-slice"))
                  (= argc 3))
                (let
                  [slot : i64
                    (embedded-native-string-local-slot
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  [start-text : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 1 0))]
                  [len-text : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 2 0))]
                  (if (or
                    (< slot 0)
                    (string.eq start-text "")
                    (string.eq len-text ""))
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-local-string-slice)
                        (string.int->string slot)
                        start-text
                        len-text)
                      1)))]
              [(and
                  (or
                    (string.eq head "comptime.type-key")
                    (string.eq head "type-key"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-key)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.type-nominal-module")
                    (string.eq head "type-nominal-module"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-key)
                  "1"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.type-nominal-name")
                    (string.eq head "type-nominal-name"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-key)
                  "2"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.type-kind")
                    (string.eq head "type-kind"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-kind)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.array-element-type")
                    (string.eq head "array-element-type"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-array-element-type)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.reference-element-type")
                    (string.eq head "reference-element-type"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-reference-element-type)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.function-return-type")
                    (string.eq head "function-return-type"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-function-return-type)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.type-cleanup-function")
                    (string.eq head "type-cleanup-function"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-cleanup-function)
                  "0"
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.struct-field-name")
                    (string.eq head "struct-field-name"))
                  (= argc 2))
                (embedded-native-computed-indexed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-struct-field-name)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.enum-variant-name")
                    (string.eq head "enum-variant-name"))
                  (= argc 2))
                (embedded-native-computed-indexed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-enum-variant-name)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.struct-field-type")
                    (string.eq head "struct-field-type"))
                  (= argc 2))
                (embedded-native-computed-indexed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-struct-field-type)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.enum-variant-payload-type")
                    (string.eq head "enum-variant-payload-type"))
                  (= argc 3))
                (embedded-native-computed-double-indexed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 2 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-enum-variant-payload-type)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.tuple-element-type")
                    (string.eq head "tuple-element-type"))
                  (= argc 2))
                (embedded-native-computed-indexed-type-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-tuple-element-type)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-for-owned-state")
                    (string.eq head "expr-for-owned-state"))
                  (= argc 4))
                (embedded-native-computed-for-owned-ops
                  params
                  (& args)
                  4
                  0
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-for-owned-step")
                    (string.eq head "expr-for-owned-step"))
                  (= argc 5))
                (embedded-native-computed-for-owned-ops
                  params
                  (& args)
                  5
                  1
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-for-owned-step-typed")
                    (string.eq head "expr-for-owned-step-typed"))
                  (= argc 6))
                (embedded-native-computed-for-owned-ops
                  params
                  (& args)
                  6
                  2
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-resource-scope")
                    (string.eq head "expr-resource-scope"))
                  (= argc 5))
                (embedded-native-computed-resource-scope-ops
                  params
                  (& args)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-let-scope")
                    (string.eq head "expr-let-scope"))
                  (= argc 3))
                (embedded-native-computed-ternary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 2 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-let-scope)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-set-var")
                    (string.eq head "expr-set-var"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-set-var)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-not")
                    (string.eq head "expr-not"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-not)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              [(and
                  (or
                    (string.eq head "comptime.expr-while")
                    (string.eq head "expr-while"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-while)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-bool")
                    (string.eq head "expr-bool"))
                  (= argc 1))
                (let
                  [value : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  (if (string.eq value "")
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-bool-literal)
                        value
                        "0"
                        "0")
                      1)))]
              [(and
                  (or
                    (string.eq head "comptime.expr-call")
                    (string.eq head "expr-call"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-call)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-array-ref")
                    (string.eq head "expr-array-ref"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-array-ref)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-list-empty")
                    (string.eq head "expr-list-empty"))
                  (= argc 0))
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-expr-list-empty)
                    "0"
                    "0"
                    "0")
                  1)]
              [(and
                  (or
                    (string.eq head "comptime.expr-list-cons")
                    (string.eq head "expr-list-cons"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-list-cons)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-borrow")
                    (string.eq head "expr-borrow"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-borrow)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              [(and
                  (or
                    (string.eq head "comptime.expr-mut-borrow")
                    (string.eq head "expr-mut-borrow"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-borrow)
                        "1"
                        "0"
                        "0")
                      (+ opened 1))))]
              [(and
                  (or
                    (string.eq head "comptime.expr-struct-get")
                    (string.eq head "expr-struct-get"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-struct-get-from-value)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-struct-set")
                    (string.eq head "expr-struct-set"))
                  (= argc 3))
                (embedded-native-computed-ternary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 2 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-struct-set-from-value)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-tuple-ref")
                    (string.eq head "expr-tuple-ref"))
                  (= argc 2))
                (embedded-native-computed-indexed-expr-query-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-tuple-ref)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-list-bindings")
                    (string.eq head "pattern-list-bindings"))
                  (= argc 2))
                (embedded-native-computed-data-arg-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-pattern-list-bindings)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-binding")
                    (string.eq head "pattern-binding"))
                  (= argc 1))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-pattern-binding)
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              [(and
                  (or
                    (string.eq head "comptime.pattern-binding-typed")
                    (string.eq head "pattern-binding-typed"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-pattern-binding-typed)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-list-empty")
                    (string.eq head "pattern-list-empty"))
                  (= argc 0))
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-pattern-list-empty)
                    "0"
                    "0"
                    "0")
                  1)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-list-cons")
                    (string.eq head "pattern-list-cons"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-pattern-list-cons-from-values)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-variant")
                    (string.eq head "pattern-variant"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-pattern-variant-from-value)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.pattern-wildcard")
                    (string.eq head "pattern-wildcard"))
                  (= argc 0))
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-pattern-wildcard)
                    "0"
                    "0"
                    "0")
                  1)]
              [(and
                  (or
                    (string.eq head "comptime.match-arm")
                    (string.eq head "match-arm"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-match-arm)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.match-arm-list-empty")
                    (string.eq head "match-arm-list-empty"))
                  (= argc 0))
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    (tlci_core.tlci-host-callback-name-shared-view
                      tlci_core.tlci-host-callback-name-match-arm-list-empty)
                    "0"
                    "0"
                    "0")
                  1)]
              [(and
                  (or
                    (string.eq head "comptime.match-arm-list-cons")
                    (string.eq head "match-arm-list-cons"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-match-arm-list-cons-from-values)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-match")
                    (string.eq head "expr-match"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                  (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-expr-match)
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-int")
                    (string.eq head "expr-int"))
                  (= argc 1))
                (match (embedded-stdlib-tlci-unwrap-expr
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0))
                  [(compiler_ast_types.AstExpr.Literal
                      (compiler_ast_types.AstLiteral.Int value text))
                    (if (or
                      (= (string.string-length text) 0)
                      (string.eq text (string.int->string value)))
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-expr-int-literal)
                          (string.int->string value)
                          "0"
                          "0")
                        1)
                      -1)]
                  ;; A compile-time data local (a computed match binder), or
                  ;; arithmetic over one, flows into the literal builder as
                  ;; data. Refs #5617, #5602.
                  [_
                    (let
                      [text : String
                        (embedded-native-data-index-text
                          (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                      (if (string.eq text "")
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-expr-int-from-data)
                            text
                            "0"
                            "0")
                          1)))])]
              ;; `(comptime.expr-binding-clause-list-nth p index)` over the
              ;; variadic binding operand used by `for`. Refs #5606.
              [(and
                  (or
                    (string.eq head "comptime.expr-binding-clause-list-nth")
                    (string.eq head "expr-binding-clause-list-nth"))
                  (= argc 2))
                (let
                  [list-param : i64
                    (embedded-native-var-param-index
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  [index-text : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 1 0))]
                  (if (or (< list-param 0) (string.eq index-text ""))
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-binding-clause-list-nth)
                        (string.int->string list-param)
                        index-text
                        "0")
                      1)))]
              [(and
                  (= argc 1)
                  (or
                    (string.eq head "comptime.expr-binding-clause-name")
                    (string.eq head "expr-binding-clause-name")
                    (string.eq head "comptime.expr-binding-clause-type")
                    (string.eq head "expr-binding-clause-type")
                    (string.eq head "comptime.expr-binding-clause-init")
                    (string.eq head "expr-binding-clause-init")))
                (let
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  [op : String
                    (cond
                      [(or
                          (string.eq head "comptime.expr-binding-clause-name")
                          (string.eq head "expr-binding-clause-name"))
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-binding-clause-name)]
                      [(or
                          (string.eq head "comptime.expr-binding-clause-type")
                          (string.eq head "expr-binding-clause-type"))
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-binding-clause-type)]
                      [else
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-binding-clause-init)])]
                  (if (< opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        op
                        "0"
                        "0"
                        "0")
                      (+ opened 1))))]
              ;; `(comptime.expr-list-nth p index)` over a variadic operand:
              ;; the host op indexes the operand list exactly like the
              ;; interpreted builtin. Refs #5617.
              [(and
                  (or
                    (string.eq head "comptime.expr-list-nth")
                    (string.eq head "expr-list-nth"))
                  (= argc 2))
                (let
                  [list-param : i64
                    (embedded-native-var-param-index
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  ;; A destructured list payload lives in a session local, so
                  ;; the local-slot twin op indexes it. Refs #5602.
                  [list-slot : i64
                    (if (>= list-param 0)
                      -1
                      (match (embedded-stdlib-tlci-unwrap-expr
                        (compiler_ast_types.ast-expr-list-get (& args) 0 0))
                        [(compiler_ast_types.AstExpr.Var list-name)
                          (embedded-native-local-index
                            (ci.intern-str list-name))]
                        [_ -1]))]
                  [index-text : String
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 1 0))]
                  (if (or
                    (and (< list-param 0) (< list-slot 0))
                    (string.eq index-text ""))
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (if (>= list-param 0)
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-expr-list-nth)
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-local-expr-list-nth))
                        (string.int->string
                          (if (>= list-param 0)
                            list-param
                            list-slot))
                        index-text
                        "0")
                      1)))]
              [else
                (embedded-native-fallback-opened
                  (str_cat.str-cat "computed-call:" head))]))]
        [_ -1])]
    [_
      (embedded-native-fallback-opened
        (str_cat.str-cat
          "computed-node:"
          (embedded-native-expr-kind-name
            (embedded-stdlib-tlci-unwrap-expr node))))]))

;: The generated spelling of an arithmetic ordinal usable in data position, or
;: "" for an operator that is not. Division and remainder are deliberately
;: absent: the interpreted path reports a comptime diagnostic on a zero divisor
;: and generated i64 code would trap instead. Refs #5617, #5701.
(define (embedded-native-arithmetic-spelling [ordinal : i64]) : String
  (cond [(= ordinal 0) "+"] [(= ordinal 1) "-"] [(= ordinal 2) "*"] [else ""]))

;: True for a `(cast e : T)` whose target is an integral scalar the data
;: representation is already exact for. Comptime `char` values travel as their
;: i64 code, so `(cast ch : i64)` is the identity on the generated text.
;: Refs #5701.
(define (embedded-native-data-cast-type? [ty : compiler_ast_types.AstType]) : bool
  (match ty
    [(compiler_ast_types.AstType.I64) true]
    [(compiler_ast_types.AstType.Char) true]
    [_ false]))

;: The generated i64 text of a canonical int literal, a compile-time data
;: local, their sums, differences and products, or an identity cast over one;
;: "" for anything else. Refs #5617, #5701.
(define (embedded-native-data-index-text [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Literal
        (compiler_ast_types.AstLiteral.Int value text))
      (if (or
        (= (string.string-length text) 0)
        (string.eq text (string.int->string value)))
        (string.int->string value)
        "")]
    [(compiler_ast_types.AstExpr.Literal
        (compiler_ast_types.AstLiteral.Bool flag))
      (if flag
        "1"
        "0")]
    [(compiler_ast_types.AstExpr.Var name)
      (embedded-native-data-local-text (ci.intern-str name))]
    [(compiler_ast_types.AstExpr.Cast inner ty-id)
      (if (embedded-native-data-cast-type?
        (compiler_ast_types.ty-node-get ty-id))
        (embedded-native-data-index-text inner)
        "")]
    ;; `(+ i 1)` in an index or literal-builder position stays plain generated
    ;; i64 arithmetic over the data locals. Refs #5602.
    [(compiler_ast_types.AstExpr.Binary op left-node right-node)
      (let
        [ordinal : i64 (embedded-native-binop-ordinal op)]
        [spelling : String (embedded-native-arithmetic-spelling ordinal)]
        [left : String (embedded-native-data-index-text left-node)]
        [right : String (embedded-native-data-index-text right-node)]
        ;; A generated source literal at the i32 boundary is inferred before
        ;; the surrounding callback ABI supplies its i64 context. Preserve
        ;; source interpretation's negative i64 AST by folding `(0 - N)` into
        ;; one signed token; decode-int uses this for i32::MIN. Refs #5606.
        [negative-literal : String
          (if (and (= ordinal 1) (string.eq left "0"))
            (match (embedded-stdlib-tlci-unwrap-expr right-node)
              [(compiler_ast_types.AstExpr.Literal
                  (compiler_ast_types.AstLiteral.Int value _))
                (if (and (>= value 0) (not (string.eq right "")))
                  (string.int->string (- 0 value))
                  "")]
              [_ ""])
            "")]
        (if (not (string.eq negative-literal ""))
          negative-literal
          (if (or
            (string.eq spelling "")
            (string.eq left "")
            (string.eq right ""))
            ""
            (str_cat.str-cat "(" spelling " " left " " right ")"))))]
    [_ ""]))

;; One i64-valued comptime expression rendered for the generated entry: `open`
;; is the let/if chain any host probe needs (with `opens` let/if pairs to
;; close), and `text` is the value expression, or "" outside the subset.
;; Refs #5602.
(defstruct EmbeddedNativeDataValue
  (open String)
  (text String)
  (opens i64))

(define (embedded-native-data-value-none) : EmbeddedNativeDataValue
  (EmbeddedNativeDataValue "" "" 0))

;; The open chain for a data-returning probe: bind it, then unwind the public
;; bad-request status on the negative malformed-request sentinel.
(define (embedded-native-data-probe-open
  [name : String]
  [op : String]
  [arg : String]
  [arg-b : String]) : String
  (str_cat.str-cat
    "  (let ["
    name
    " : i64 (comptime-host-"
    op
    " host session "
    arg
    " "
    arg-b
    " 0)]\n"
    "  (if (< "
    name
    " 0)\n  "
    (string.int->string tlci_core.tlci-host-callback-status-bad-request)
    "\n"))

;; One probe bound to a fresh temporary, as a data value.
(define (embedded-native-data-probe-value
  [op : String]
  [arg : String]
  [arg-b : String]) : EmbeddedNativeDataValue
  (let
    [name : String (embedded-native-temp-name!)]
    (EmbeddedNativeDataValue
      (embedded-native-data-probe-open name op arg arg-b)
      name
      1)))

;; Render a contiguous neutral-call range as the still-open host-op let/if
;; chain used by data-returning probes and legacy-sized arm blocks.
(define (embedded-native-ops-open-text-range
  [ops : (__tl_dyn-array String)]
  [start : i64]
  [count : i64]) : String
  (let
    [out : String ""]
    [index : i64 start]
    [limit : i64 (+ start count)]
    (begin
      (while (< index limit)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (embedded-native-op-open-from-call index (array-ref ops index))))
          (set! index (+ index 1))))
      out)))

(define (embedded-native-ops-open-text
  [ops : (__tl_dyn-array String)]
  [count : i64]) : String
  (embedded-native-ops-open-text-range ops 0 count))

;; A data-returning reflection op first consumes a computed type stack value,
;; then returns its count directly. Keep both open chains visible to the
;; surrounding data expression so its caller closes them together. Refs #5626.
(define (embedded-native-stacked-data-probe-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [type-node : i64]
  [op : String]
  [arg : String]) : EmbeddedNativeDataValue
  (let
    [ops : (__tl_dyn-array String)
      (array.make-array String embedded-native-ops-cap)]
    [ops-count : (__tl_dyn-array i64) (make-array 0)]
    [type-opened : i64
      (embedded-native-computed-expr-ops params type-node ops ops-count)]
    (if (or
      (< type-opened 0)
      (>= type-opened embedded-native-ops-cap)
      (>= (array-ref ops-count 0) embedded-native-ops-cap))
      (embedded-native-data-value-none)
      (let
        [name : String (embedded-native-temp-name!)]
        (EmbeddedNativeDataValue
          (str_cat.str-cat
            (embedded-native-ops-open-text ops (array-ref ops-count 0))
            (embedded-native-data-probe-open name op arg "0"))
          name
          (+ type-opened 1))))))

;; A data-returning binary callback consumes two computed session values but
;; must not be emitted through the ordinary status-op chain: true is `1`, which
;; status chaining would mistake for an error. Open only the two operand chains,
;; then invoke the data callback once in probe position. Refs #5606.
(define (embedded-native-stacked-binary-data-probe-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [left-node : i64]
  [right-node : i64]
  [op : String]) : EmbeddedNativeDataValue
  (let
    [ops : (__tl_dyn-array String)
      (array.make-array String embedded-native-ops-cap)]
    [ops-count : (__tl_dyn-array i64) (make-array 0)]
    [left-opened : i64
      (embedded-native-computed-expr-ops params left-node ops ops-count)]
    (if (< left-opened 0)
      (embedded-native-data-value-none)
      (let
        [right-opened : i64
          (embedded-native-computed-expr-ops params right-node ops ops-count)]
        (if (or
          (< right-opened 0)
          (>= (array-ref ops-count 0) embedded-native-ops-cap))
          (embedded-native-data-value-none)
          (let
            [name : String (embedded-native-temp-name!)]
            (EmbeddedNativeDataValue
              (str_cat.str-cat
                (embedded-native-ops-open-text ops (array-ref ops-count 0))
                (embedded-native-data-probe-open name op "0" "0"))
              name
              (+ left-opened right-opened 1))))))))

;; Literals, data locals, and arithmetic over them need no probe; an operand or
;; local expression-list length, and the comptime string-scanner reads over a
;; String session local, each hoist one. Arithmetic recurses so a probed
;; sub-value can appear inside a sum -- the scanner bodies write
;; `(- (cast (string.string-ref key i) : i64) 48)`. Refs #5602, #5701.
(define (embedded-native-data-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (let
    [plain : String (embedded-native-data-index-text node)]
    (if (not (string.eq plain ""))
      (EmbeddedNativeDataValue "" plain 0)
      (match (embedded-stdlib-tlci-unwrap-expr node)
        [(compiler_ast_types.AstExpr.Cast inner ty-id)
          (if (embedded-native-data-cast-type?
            (compiler_ast_types.ty-node-get ty-id))
            (embedded-native-data-value params inner)
            (embedded-native-data-value-none))]
        [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
          (embedded-native-data-if-value params cond-node then-node else-node)]
        [(compiler_ast_types.AstExpr.Match match-box)
          (embedded-native-data-var-match-value params match-box)]
        [(compiler_ast_types.AstExpr.Binary op left-node right-node)
          (let
            [ordinal : i64 (embedded-native-binop-ordinal op)]
            [arithmetic : String (embedded-native-arithmetic-spelling ordinal)]
            (if (not (string.eq arithmetic ""))
              (embedded-native-data-binary-value
                params
                arithmetic
                left-node
                right-node)
              (if (and (>= ordinal 5) (<= ordinal 10))
                (embedded-native-data-comparison-value
                  params
                  (embedded-native-comparison-spelling ordinal)
                  left-node
                  right-node)
                (embedded-native-data-value-none))))]
        [(compiler_ast_types.AstExpr.Unary op inner-node)
          (if (= (embedded-native-unop-ordinal op) 1)
            (let
              [inner : EmbeddedNativeDataValue
                (embedded-native-data-value params inner-node)]
              (if (string.eq (struct-get inner text) "")
                (embedded-native-data-value-none)
                (EmbeddedNativeDataValue
                  (struct-get inner open)
                  (str_cat.str-cat "(if (= " (struct-get inner text) " 0) 1 0)")
                  (struct-get inner opens))))
            (embedded-native-data-value-none))]
        [_ (embedded-native-data-call-value params node)]))))

(define (embedded-native-data-binary-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [spelling : String]
  [left-node : i64]
  [right-node : i64]) : EmbeddedNativeDataValue
  (if (string.eq spelling "")
    (embedded-native-data-value-none)
    (let
      [left : EmbeddedNativeDataValue
        (embedded-native-data-value params left-node)]
      [right : EmbeddedNativeDataValue
        (embedded-native-data-value params right-node)]
      (if (or
        (string.eq (struct-get left text) "")
        (string.eq (struct-get right text) ""))
        (embedded-native-data-value-none)
        (EmbeddedNativeDataValue
          (str_cat.str-cat (struct-get left open) (struct-get right open))
          (str_cat.str-cat
            "("
            spelling
            " "
            (struct-get left text)
            " "
            (struct-get right text)
            ")")
          (+ (struct-get left opens) (struct-get right opens)))))))

(define (embedded-native-data-comparison-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [spelling : String]
  [left-node : i64]
  [right-node : i64]) : EmbeddedNativeDataValue
  (let
    [left : EmbeddedNativeDataValue
      (embedded-native-data-value params left-node)]
    [right : EmbeddedNativeDataValue
      (embedded-native-data-value params right-node)]
    (if (or
      (string.eq (struct-get left text) "")
      (string.eq (struct-get right text) ""))
      (embedded-native-data-value-none)
      (EmbeddedNativeDataValue
        (str_cat.str-cat (struct-get left open) (struct-get right open))
        (str_cat.str-cat
          "(if ("
          spelling
          " "
          (struct-get left text)
          " "
          (struct-get right text)
          ") 1 0)")
        (+ (struct-get left opens) (struct-get right opens))))))

;; Select the operand- or local-slot form of one unary Expr shape probe.
;; The argument must be a plain macro parameter or a session-local Expr.
;; Refs #5656.
(define (embedded-native-data-expr-probe-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [subject : i64]
  [operand-op : String]
  [local-op : String]) : EmbeddedNativeDataValue
  (let
    [param : i64 (embedded-native-var-param-index params subject)]
    (if (>= param 0)
      (embedded-native-data-probe-value
        operand-op
        (string.int->string param)
        "0")
      (match (embedded-stdlib-tlci-unwrap-expr subject)
        [(compiler_ast_types.AstExpr.Var name)
          (let
            [slot : i64 (embedded-native-local-index (ci.intern-str name))]
            (if (< slot 0)
              (embedded-native-data-value-none)
              (embedded-native-data-probe-value
                local-op
                (string.int->string slot)
                "0")))]
        [_ (embedded-native-data-value-none)]))))

;; Recognize a unary Expr-inspector call and return its 1/0 data probe.
(define (embedded-native-data-expr-probe-call-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [qualified-name : String]
  [short-name : String]
  [operand-op : String]
  [local-op : String]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (if (and
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (or
              (string.eq (ci.intern-str head-id) qualified-name)
              (string.eq (ci.intern-str head-id) short-name)))
            (embedded-native-data-expr-probe-value
              params
              (compiler_ast_types.ast-expr-list-get (& args) 0 0)
              operand-op
              local-op)
            (embedded-native-data-value-none))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

;; Render a data value as a status expression that stores its successful value
;; in `target`. Probe failures remain the public bad-request status instead of
;; becoming ordinary scalar data. Refs #5656.
(define (embedded-native-data-store-status-code
  [value : EmbeddedNativeDataValue]
  [target : String]) : String
  (str_cat.str-cat
    (struct-get value open)
    "  (begin\n"
    "  (set! "
    target
    " "
    (struct-get value text)
    ")\n"
    "  0)\n"
    (embedded-native-closing-parens (* 2 (struct-get value opens)))))

;; A scalar `if` can itself initialize a data local. Its selected branch may
;; contain a host probe, so keep a separate status local and open a continuation
;; only after that status succeeds. Refs #5656.
(define (embedded-native-data-if-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [cond-node : i64]
  [then-node : i64]
  [else-node : i64]) : EmbeddedNativeDataValue
  (let
    [cond-value : EmbeddedNativeDataValue
      (embedded-native-data-value params cond-node)]
    [then-value : EmbeddedNativeDataValue
      (embedded-native-data-value params then-node)]
    [else-value : EmbeddedNativeDataValue
      (embedded-native-data-value params else-node)]
    (if (or
      (string.eq (struct-get cond-value text) "")
      (string.eq (struct-get then-value text) "")
      (string.eq (struct-get else-value text) ""))
      (embedded-native-data-value-none)
      (let
        [result : String (embedded-native-temp-name!)]
        [status : String (embedded-native-temp-name!)]
        (EmbeddedNativeDataValue
          (str_cat.str-cat
            (struct-get cond-value open)
            "  (let ["
            result
            " : i64 0]\n"
            "  (let ["
            status
            " : i64\n"
            "  (if (= "
            (struct-get cond-value text)
            " 1)\n"
            (embedded-native-data-store-status-code then-value result)
            (embedded-native-data-store-status-code else-value result)
            ")]\n"
            "  (if (not (= "
            status
            " 0)) "
            status
            "\n"
            "  (begin\n")
          result
          (+ (struct-get cond-value opens) 2))))))

;; The boolean Expr.Var match used by the scoped string concatenator is a pure
;; shape test. Lower it directly to the corresponding operand/local data probe
;; when it has exactly `[Var _ => true] [_ => false]`. Refs #5656.
(define (embedded-native-data-var-match-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [match-box : (Box compiler_ast_types.AstMatch)]) : EmbeddedNativeDataValue
  (match (box-get match-box)
    [(compiler_ast_types.AstMatch.Match scrutinee arms)
      (if (not (= (struct-get arms len) 2))
        (embedded-native-data-value-none)
        (match (array-ref (struct-get arms slots) 0)
          [(compiler_ast_types.AstMatchArm.Arm first-pattern first-body)
            (match (array-ref (struct-get arms slots) 1)
              [(compiler_ast_types.AstMatchArm.Arm second-pattern second-body)
                (match first-pattern
                  [(compiler_ast_types.AstPattern.Variant name-id args-box)
                    (let
                      [args : compiler_ast_types.AstPatternList
                        (box-get args-box)]
                      (if (and
                        (string.eq
                          (embedded-native-expr-variant-name name-id)
                          "Var")
                        (= (struct-get args len) 1)
                        (match (compiler_ast_types.ast-pattern-list-get
                          (& args)
                          0
                          (compiler_ast_types.ast-pattern-fallback))
                          [(compiler_ast_types.AstPattern.Wildcard) true]
                          [_ false])
                        (match second-pattern
                          [(compiler_ast_types.AstPattern.Wildcard) true]
                          [_ false])
                        (= (embedded-native-bool-literal-flag first-body) 1)
                        (= (embedded-native-bool-literal-flag second-body) 0))
                        (embedded-native-data-expr-probe-value
                          params
                          scrutinee
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-operand-expr-var?)
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-local-expr-var?))
                        (embedded-native-data-value-none)))]
                  [_ (embedded-native-data-value-none)])])]
          [_ (embedded-native-data-value-none)]))]
    [_ (embedded-native-data-value-none)]))

;; One reflection count over a type operand/session local, or no value.
(define (embedded-native-reflection-count-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            [argc : i64 (compiler_ast_types.ast-expr-list-len (& args))]
            [op : String
              (cond
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.struct-field-count")
                      (string.eq head "struct-field-count")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-struct-field-count)]
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.enum-variant-count")
                      (string.eq head "enum-variant-count")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-enum-variant-count)]
                [(and
                    (= argc 2)
                    (or
                      (string.eq head "comptime.enum-variant-payload-count")
                      (string.eq head "enum-variant-payload-count")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-enum-variant-payload-count)]
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.tuple-element-count")
                      (string.eq head "tuple-element-count")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-tuple-element-count)]
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.array-length")
                      (string.eq head "array-length")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-array-length)]
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.function-param-count")
                      (string.eq head "function-param-count")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-function-param-count)]
                [(and
                    (= argc 1)
                    (or
                      (string.eq head "comptime.type-cleanup-owning?")
                      (string.eq head "type-cleanup-owning?")))
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-type-cleanup-owning?)]
                [else ""])]
            (if (= (string.string-length op) 0)
              (embedded-native-data-value-none)
              (let
                [index-text : String
                  (if (= argc 2)
                    (embedded-native-data-index-text
                      (compiler_ast_types.ast-expr-list-get (& args) 1 0))
                    "0")]
                (if (string.eq index-text "")
                  (embedded-native-data-value-none)
                  (embedded-native-stacked-data-probe-value
                    params
                    (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                    op
                    index-text)))))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

;; The probe-backed data calls: expression-list lengths, reflection counts, and
;; comptime string reads over a String session local. Refs #5602, #5626, #5701.
(define (embedded-native-expr-binding-clause-list-length-param
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (if (and
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (or
              (string.eq
                (ci.intern-str head-id)
                "comptime.expr-binding-clause-list-length")
              (string.eq
                (ci.intern-str head-id)
                "expr-binding-clause-list-length")))
            (embedded-native-var-param-index
              params
              (compiler_ast_types.ast-expr-list-get (& args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

(define (embedded-native-binding-clause-has-type-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (if (and
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (or
              (string.eq
                (ci.intern-str head-id)
                "comptime.expr-binding-clause-has-type?")
              (string.eq
                (ci.intern-str head-id)
                "expr-binding-clause-has-type?")))
            (match (embedded-stdlib-tlci-unwrap-expr
              (compiler_ast_types.ast-expr-list-get (& args) 0 0))
              [(compiler_ast_types.AstExpr.Var name-id)
                (let
                  [slot : i64
                    (embedded-native-local-index (ci.intern-str name-id))]
                  (if (< slot 0)
                    (embedded-native-data-value-none)
                    (embedded-native-data-probe-value
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-binding-clause-has-type?)
                      (string.int->string slot)
                      "0")))]
              [_ (embedded-native-data-value-none)])
            (embedded-native-data-value-none))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

(define (embedded-native-data-string-eq-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            (if (and
              (= (compiler_ast_types.ast-expr-list-len (& args)) 2)
              (or
                (string.eq head "comptime.string-eq")
                (string.eq head "string-eq")
                (string.eq head "string=?")
                (string.eq head "string.eq")))
              (embedded-native-stacked-binary-data-probe-value
                params
                (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-string-eq))
              (embedded-native-data-value-none)))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

(define (embedded-native-data-module-value-exists-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            (if (and
              (= (compiler_ast_types.ast-expr-list-len (& args)) 2)
              (or
                (string.eq head "comptime.module-value?")
                (string.eq head "module-value?")))
              (embedded-native-stacked-binary-data-probe-value
                params
                (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                (compiler_ast_types.ast-expr-list-get (& args) 1 0)
                (tlci_core.tlci-host-callback-name-shared-view
                  tlci_core.tlci-host-callback-name-module-value?))
              (embedded-native-data-value-none)))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

(define (embedded-native-data-call-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (let
    [expr-string : EmbeddedNativeDataValue
      (embedded-native-data-expr-probe-call-value
        params
        node
        "comptime.expr-string?"
        "expr-string?"
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-operand-expr-string?)
        (tlci_core.tlci-host-callback-name-shared-view
          tlci_core.tlci-host-callback-name-local-expr-string?))]
    (if (not (string.eq (struct-get expr-string text) ""))
      expr-string
      (let
        [string-eq : EmbeddedNativeDataValue
          (embedded-native-data-string-eq-value params node)]
        (if (not (string.eq (struct-get string-eq text) ""))
          string-eq
          (let
            [module-value : EmbeddedNativeDataValue
              (embedded-native-data-module-value-exists-value params node)]
            (if (not (string.eq (struct-get module-value text) ""))
              module-value
              (let
                [has-type : EmbeddedNativeDataValue
                  (embedded-native-binding-clause-has-type-value params node)]
                (if (not (string.eq (struct-get has-type text) ""))
                  has-type
                  (let
                    [binding-operand : i64
                      (embedded-native-expr-binding-clause-list-length-param
                        params
                        node)]
                    (if (>= binding-operand 0)
                      (embedded-native-data-probe-value
                        (tlci_core.tlci-host-callback-name-shared-view
                          tlci_core.tlci-host-callback-name-expr-binding-clause-list-length)
                        (string.int->string binding-operand)
                        "0")
                      (let
                        [operand : i64
                          (embedded-native-expr-list-length-param params node)]
                        (if (>= operand 0)
                          (embedded-native-data-probe-value
                            (tlci_core.tlci-host-callback-name-shared-view
                              tlci_core.tlci-host-callback-name-expr-list-length)
                            (string.int->string operand)
                            "0")
                          (let
                            [slot : i64
                              (embedded-native-expr-list-length-local
                                params
                                node)]
                            (if (>= slot 0)
                              (embedded-native-data-probe-value
                                (tlci_core.tlci-host-callback-name-shared-view
                                  tlci_core.tlci-host-callback-name-local-expr-list-length)
                                (string.int->string slot)
                                "0")
                              (let
                                [reflection : EmbeddedNativeDataValue
                                  (embedded-native-reflection-count-value
                                    params
                                    node)]
                                (if (string.eq (struct-get reflection text) "")
                                  (embedded-native-string-scan-value
                                    params
                                    node)
                                  reflection)))))))))))))))))

;; `(string.string-length <String local>)` and
;; `(string.string-ref <String local> <data>)`: the stdlib string functions the
;; comptime scanners call, evaluated by the host against the bound local rather
;; than emitted as runtime code. The index is itself a data value, so a probed
;; sub-expression can index the string. Refs #5701.
(define (embedded-native-string-scan-value
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            [argc : i64 (compiler_ast_types.ast-expr-list-len (& args))]
            [slot : i64
              (if (= argc 0)
                -1
                (embedded-native-string-local-slot
                  params
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)))]
            (cond
              [(< slot 0) (embedded-native-data-value-none)]
              [(and
                  (embedded-native-stdlib-string-call? head "string-length")
                  (= argc 1))
                (embedded-native-data-probe-value
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-local-string-length)
                  (string.int->string slot)
                  "0")]
              [(and
                  (or
                    (embedded-native-stdlib-string-call? head "string-ref")
                    (embedded-native-stdlib-string-call? head "char-at"))
                  (= argc 2))
                (let
                  [index : EmbeddedNativeDataValue
                    (embedded-native-data-value
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 1 0))]
                  (if (string.eq (struct-get index text) "")
                    (embedded-native-data-value-none)
                    (let
                      [probe : EmbeddedNativeDataValue
                        (embedded-native-data-probe-value
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-local-string-ref)
                          (string.int->string slot)
                          (struct-get index text))]
                      (EmbeddedNativeDataValue
                        (str_cat.str-cat
                          (struct-get index open)
                          (struct-get probe open))
                        (struct-get probe text)
                        (+ (struct-get index opens) 1)))))]
              [else (embedded-native-data-value-none)]))]
        [_ (embedded-native-data-value-none)])]
    [_ (embedded-native-data-value-none)]))

;: The session-local slot a `String`-valued name is bound to, or -1 when the
;: node is not a plain name, names a macro parameter, or names nothing bound.
;: Refs #5701.
(define (embedded-native-string-local-slot
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Var name)
      (if (>= (embedded-stdlib-tlci-param-index params name) 0)
        -1
        (embedded-native-local-index (ci.intern-str name)))]
    [_ -1]))

;: A `stdlib.string` helper call spelled the way the module-qualified imports
;: reach the producer. This mirrors `ctfe-stdlib-string-helper-name?`, which is
;: what decides the same call under interpretation: a module separator is
;: required, so a local function named `string-length` is never mistaken for
;: the stdlib one. Refs #5701.
(define (embedded-native-stdlib-string-call? [head : String] [base : String]) : bool
  (or
    (string.eq head (str_cat.str-cat "string." base))
    (string.eq head (str_cat.str-cat "string/" base))
    (string.eq head (str_cat.str-cat "stdlib.string." base))
    (string.eq head (str_cat.str-cat "stdlib.string/" base))
    (string.eq head (str_cat.str-cat "stdlib/string." base))
    (string.eq head (str_cat.str-cat "stdlib/string/" base))
    (string.eq head (str_cat.str-cat "stdlib/string.tl." base))
    (string.eq head (str_cat.str-cat "stdlib/string.tl/" base))))

;: The session-local slot of a `(comptime.expr-list-length <local>)` call, or
;: -1 for anything else. Refs #5602.
(define (embedded-native-expr-list-length-local
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call length-func length-args)
      (match (embedded-stdlib-tlci-unwrap-expr length-func)
        [(compiler_ast_types.AstExpr.Var length-head)
          (if (and
            (or
              (string.eq
                (ci.intern-str length-head)
                "comptime.expr-list-length")
              (string.eq (ci.intern-str length-head) "expr-list-length"))
            (= (compiler_ast_types.ast-expr-list-len (& length-args)) 1)
            (<
              (embedded-native-var-param-index
                params
                (compiler_ast_types.ast-expr-list-get (& length-args) 0 0))
              0))
            (match (embedded-stdlib-tlci-unwrap-expr
              (compiler_ast_types.ast-expr-list-get (& length-args) 0 0))
              [(compiler_ast_types.AstExpr.Var list-name)
                (embedded-native-local-index (ci.intern-str list-name))]
              [_ -1])
            -1)]
        [_ -1])]
    [_ -1]))

;; Compile `(if (<cmp> <i64> <i64>) then else)` where each side is a literal,
;; a compile-time data local, arithmetic over them, or an operand/local
;; expression-list length. Returns "" outside that shape. Refs #5602.
(define (embedded-native-data-if-body
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
      (match (embedded-stdlib-tlci-unwrap-expr cond-node)
        [(compiler_ast_types.AstExpr.Binary op left-node right-node)
          (let
            [ordinal : i64 (embedded-native-binop-ordinal op)]
            [left : EmbeddedNativeDataValue
              (embedded-native-data-value params left-node)]
            [right : EmbeddedNativeDataValue
              (embedded-native-data-value params right-node)]
            (if (or
              (< ordinal 5)
              (> ordinal 10)
              (string.eq (struct-get left text) "")
              (string.eq (struct-get right text) ""))
              ""
              (let
                [then-code : String
                  (embedded-native-body-code params then-node)]
                [else-code : String
                  (embedded-native-body-code params else-node)]
                (if (or (string.eq then-code "") (string.eq else-code ""))
                  ""
                  (str_cat.str-cat
                    (struct-get left open)
                    (struct-get right open)
                    "  (if ("
                    (embedded-native-comparison-spelling ordinal)
                    " "
                    (struct-get left text)
                    " "
                    (struct-get right text)
                    ")\n"
                    then-code
                    else-code
                    ")\n"
                    (embedded-native-closing-parens
                      (* 2 (+ (struct-get left opens) (struct-get right opens)))))))))]
        [_ ""])]
    [_ ""]))

;; Two computed expressions then one binary host op over their session values.
(define (embedded-native-computed-binary-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [left-node : i64]
  [right-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [left-opened : i64
      (embedded-native-computed-expr-ops params left-node ops ops-count)]
    (if (< left-opened 0)
      -1
      (let
        [right-opened : i64
          (embedded-native-computed-expr-ops params right-node ops ops-count)]
        (if (< right-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op "0" "0" "0")
            (+ left-opened right-opened 1)))))))

(define (embedded-native-computed-ternary-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [first-node : i64]
  [second-node : i64]
  [third-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [first-opened : i64
      (embedded-native-computed-expr-ops params first-node ops ops-count)]
    (if (< first-opened 0)
      -1
      (let
        [second-opened : i64
          (embedded-native-computed-expr-ops params second-node ops ops-count)]
        (if (< second-opened 0)
          -1
          (let
            [third-opened : i64
              (embedded-native-computed-expr-ops
                params
                third-node
                ops
                ops-count)]
            (if (< third-opened 0)
              -1
              (begin
                (embedded-native-template-push! ops ops-count op "0" "0" "0")
                (+ first-opened second-opened third-opened 1)))))))))

(define (embedded-native-computed-call-args-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [args : (& args compiler_ast_types.AstExprList)]
  [index : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (if (>= index (compiler_ast_types.ast-expr-list-len args))
    0
    (let
      [opened : i64
        (embedded-native-computed-expr-ops
          params
          (compiler_ast_types.ast-expr-list-get args index 0)
          ops
          ops-count)]
      (if (< opened 0)
        -1
        (let
          [rest-opened : i64
            (embedded-native-computed-call-args-ops
              params
              args
              (+ index 1)
              ops
              ops-count)]
          (if (< rest-opened 0)
            -1
            (+ opened rest-opened)))))))

(define (embedded-native-computed-for-owned-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [args : (& args compiler_ast_types.AstExprList)]
  [expected-count : i64]
  [mode : i64]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (if (not (= (compiler_ast_types.ast-expr-list-len args) expected-count))
    -1
    (let
      [opened : i64
        (embedded-native-computed-call-args-ops params args 0 ops ops-count)]
      (if (< opened 0)
        -1
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            (tlci_core.tlci-host-callback-name-shared-view
              tlci_core.tlci-host-callback-name-expr-for-owned)
            (string.int->string mode)
            "0"
            "0")
          (+ opened 1))))))

(define (embedded-native-computed-resource-scope-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [args : (& args compiler_ast_types.AstExprList)]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [move-aware : String
      (embedded-native-data-index-text
        (compiler_ast_types.ast-expr-list-get args 4 0))]
    [name-opened : i64
      (embedded-native-computed-expr-ops
        params
        (compiler_ast_types.ast-expr-list-get args 0 0)
        ops
        ops-count)]
    (if (or (string.eq move-aware "") (< name-opened 0))
      -1
      (let
        [init-opened : i64
          (embedded-native-computed-expr-ops
            params
            (compiler_ast_types.ast-expr-list-get args 1 0)
            ops
            ops-count)]
        (if (< init-opened 0)
          -1
          (let
            [cleanup-opened : i64
              (embedded-native-computed-expr-ops
                params
                (compiler_ast_types.ast-expr-list-get args 2 0)
                ops
                ops-count)]
            (if (< cleanup-opened 0)
              -1
              (let
                [body-opened : i64
                  (embedded-native-computed-expr-ops
                    params
                    (compiler_ast_types.ast-expr-list-get args 3 0)
                    ops
                    ops-count)]
                (if (< body-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-expr-resource-scope)
                      move-aware
                      "0"
                      "0")
                    (+ name-opened init-opened cleanup-opened body-opened 1)))))))))))

;; Compile one stack-valued argument followed by an i64 literal/data-local
;; immediate. Used by dense computed pattern binding construction. Refs #5626.
(define (embedded-native-computed-data-arg-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [value-node : i64]
  [data-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [data-text : String (embedded-native-data-index-text data-node)]
    (if (string.eq data-text "")
      -1
      (let
        [value-opened : i64
          (embedded-native-computed-expr-ops params value-node ops ops-count)]
        (if (< value-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op data-text "0" "0")
            (+ value-opened 1)))))))

;; `(type-key T)` / `(type-kind T)` over any computed type value. Direct
;; operands, projected expression types, and let-bound session values all use
;; the same stack-value protocol; the query replaces that value with its
;; reflected String result. Refs #5606.
(define (embedded-native-computed-type-query-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arg-node : i64]
  [op : String]
  [arg-a : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [opened : i64
      (embedded-native-computed-expr-ops params arg-node ops ops-count)]
    (if (< opened 0)
      -1
      (begin
        (embedded-native-template-push! ops ops-count op arg-a "0" "0")
        (+ opened 1)))))

;; Compile an indexed reflection query whose type can be either a macro
;; operand or a let-bound session value and whose index is a literal/data
;; local. The host operation replaces the pushed type with its reflected
;; result. Refs #5626.
(define (embedded-native-computed-indexed-type-query-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [type-node : i64]
  [index-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [index-text : String (embedded-native-data-index-text index-node)]
    (if (string.eq index-text "")
      -1
      (let
        [type-opened : i64
          (embedded-native-computed-expr-ops params type-node ops ops-count)]
        (if (< type-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op index-text "0" "0")
            (+ type-opened 1)))))))

;; Compile a reflection query with two literal/data-local indexes. The type
;; value stays on the session stack while both indexes travel in the callback
;; operation's immediate arguments. Refs #5626.
(define (embedded-native-computed-double-indexed-type-query-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [type-node : i64]
  [first-index-node : i64]
  [second-index-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [first-index-text : String
      (embedded-native-data-index-text first-index-node)]
    [second-index-text : String
      (embedded-native-data-index-text second-index-node)]
    (if (or (string.eq first-index-text "") (string.eq second-index-text ""))
      -1
      (let
        [type-opened : i64
          (embedded-native-computed-expr-ops params type-node ops ops-count)]
        (if (< type-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              op
              first-index-text
              second-index-text
              "0")
            (+ type-opened 1)))))))

;; Compile an expression projection with a literal/data-local index. The
;; expression value is pushed first and the host operation replaces it with
;; the projected expression. Refs #5626.
(define (embedded-native-computed-indexed-expr-query-ops
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [expr-node : i64]
  [index-node : i64]
  [op : String]
  [ops : (__tl_dyn-array String)]
  [ops-count : (__tl_dyn-array i64)]) : i64
  (let
    [index-text : String (embedded-native-data-index-text index-node)]
    (if (string.eq index-text "")
      -1
      (let
        [expr-opened : i64
          (embedded-native-computed-expr-ops params expr-node ops ops-count)]
        (if (< expr-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op index-text "0" "0")
            (+ expr-opened 1)))))))

;; The `(comptime-host-local-set host session N 0 0)` local-set final text
;; for one binding slot.
(define (embedded-native-local-set-final [slot : i64]) : String
  (str_cat.str-cat
    "  (comptime-host-local-set host session "
    (string.int->string slot)
    " 0 0)\n"))

;; Compile one computed expression to a balanced code string evaluating to a
;; host status, ending with the `final` operation over the produced session
;; value. Quasiquoted fragments reuse the general template walker.
;; Returns "" outside the supported subset.
(define (embedded-native-computed-expr-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [final : String]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
      (embedded-native-computed-if-code
        params
        cond-node
        then-node
        else-node
        final)]
    [(compiler_ast_types.AstExpr.Begin exprs)
      (embedded-native-computed-begin-code params (& exprs) final)]
    [(compiler_ast_types.AstExpr.Match match-box)
      (embedded-native-computed-match-code params match-box final)]
    ;; A let nested in a computed position (an if/match branch at body
    ;; level): the body commits like a top-level body. Refs #5603.
    [(compiler_ast_types.AstExpr.Let _)
      (embedded-native-let-body-code params node)]
    [(compiler_ast_types.AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(compiler_ast_types.AstExpr.Var head-id)
          (let
            [head : String (ci.intern-str head-id)]
            [argc : i64 (compiler_ast_types.ast-expr-list-len (& args))]
            (cond
              ;; `(comptime.expr-int data)`: reflection counts, local data, and
              ;; arithmetic over either flow into the literal builder without
              ;; forcing the value through the session stack. Refs #5701,
              ;; #5606.
              [(and
                  (or
                    (string.eq head "comptime.expr-int")
                    (string.eq head "expr-int"))
                  (= argc 1))
                (let
                  [data : EmbeddedNativeDataValue
                    (embedded-native-data-value
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0))]
                  (if (string.eq (struct-get data text) "")
                    (embedded-native-computed-expr-code-linear
                      params
                      node
                      final)
                    (str_cat.str-cat
                      (struct-get data open)
                      "  (let [q0 : i64 (comptime-host-expr-int-from-data host session "
                      (struct-get data text)
                      " 0 0)] (if (not (= q0 0)) q0\n"
                      final
                      "))\n"
                      (embedded-native-closing-parens
                        (* 2 (struct-get data opens))))))]
              ;; `(comptime.comptime-error msg)` / `(comptime.error msg)`:
              ;; the message flows to the session diagnostic with the
              ;; diagnostic status, ignoring `final`.
              [(and
                  (or
                    (string.eq head "comptime.comptime-error")
                    (string.eq head "comptime.error")
                    (string.eq head "comptime-error"))
                  (= argc 1))
                (let
                  [ops : (__tl_dyn-array String)
                    (array.make-array String embedded-native-ops-cap)]
                  [ops-count : (__tl_dyn-array i64) (make-array 0)]
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (compiler_ast_types.ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (or
                    (< opened 0)
                    (>= (array-ref ops-count 0) embedded-native-ops-cap))
                    ""
                    (embedded-native-arm-block-with-final
                      ops
                      (array-ref ops-count 0)
                      opened
                      "  (comptime-host-diagnostic-from-value host session 0 0 0)\n")))]
              [else
                (embedded-native-computed-expr-code-linear params node final)]))]
        [_ (embedded-native-computed-expr-code-linear params node final)])]
    [_ (embedded-native-computed-expr-code-linear params node final)]))

;; The linear chain fallback for computed-expr-code.
(define (embedded-native-computed-expr-code-linear
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]
  [final : String]) : String
  (let
    [ops : (__tl_dyn-array String)
      (array.make-array String embedded-native-ops-cap)]
    [ops-count : (__tl_dyn-array i64) (make-array 0)]
    [opened : i64
      (if (match (embedded-stdlib-tlci-unwrap-expr node)
        [(compiler_ast_types.AstExpr.Quasiquote _) true]
        [_ false])
        (embedded-native-body-ops params node ops ops-count)
        (embedded-native-computed-expr-ops params node ops ops-count))]
    (if (or (< opened 0) (>= (array-ref ops-count 0) embedded-native-ops-cap))
      ""
      (embedded-native-arm-block-with-final
        ops
        (array-ref ops-count 0)
        opened
        final))))

;; Sequence two generated i64 status expressions without discarding an earlier
;; diagnostic/bad-request status.
(define (embedded-native-status-sequence-code [head : String] [rest : String]) : String
  (let
    [status : String (embedded-native-temp-name!)]
    (str_cat.str-cat
      "  (let ["
      status
      " : i64\n"
      head
      "] (if (not (= "
      status
      " 0)) "
      status
      "\n"
      rest
      "))\n")))

;; Compile the statement prefix of a computed `(begin ...)`; every prefix item
;; is an i64 status expression, and the final item is compiled separately with
;; the caller's result operation.
(define (embedded-native-computed-begin-statements-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [exprs : (& exprs compiler_ast_types.AstExprList)]
  [index : i64]
  [last : i64]) : String
  (if (>= index last)
    "  0\n"
    (let
      [head : String
        (embedded-native-computed-statement-code
          params
          (compiler_ast_types.ast-expr-list-get exprs index 0))]
      (if (string.eq head "")
        "\x01"
        (let
          [rest : String
            (embedded-native-computed-begin-statements-code
              params
              exprs
              (+ index 1)
              last)]
          (if (string.eq rest "\x01")
            "\x01"
            (embedded-native-status-sequence-code head rest)))))))

(define (embedded-native-computed-begin-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [exprs : (& exprs compiler_ast_types.AstExprList)]
  [final : String]) : String
  (let
    [count : i64 (compiler_ast_types.ast-expr-list-len exprs)]
    (if (= count 0)
      ""
      (let
        [prefix : String
          (embedded-native-computed-begin-statements-code
            params
            exprs
            0
            (- count 1))]
        [tail : String
          (embedded-native-computed-expr-code
            params
            (compiler_ast_types.ast-expr-list-get exprs (- count 1) 0)
            final)]
        (if (or (string.eq prefix "\x01") (string.eq tail ""))
          ""
          (embedded-native-status-sequence-code prefix tail))))))

;; A statement-position expression in a computed begin. The scoped string
;; concatenator needs unit, mutation of an i64-backed bool local, and if over a
;; scalar/probe condition. Refs #5656.
(define (embedded-native-computed-statement-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : String
  (begin
    (embedded-native-full-walked-note!
      (str_cat.str-cat
        "statement-node:"
        (embedded-native-expr-kind-name (embedded-stdlib-tlci-unwrap-expr node))))
    (embedded-native-computed-statement-code-inner params node)))

(define (embedded-native-computed-statement-code-inner
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Literal (compiler_ast_types.AstLiteral.Unit))
      "  0\n"]
    [(compiler_ast_types.AstExpr.Begin exprs)
      (embedded-native-computed-statement-list-code params (& exprs) 0)]
    [(compiler_ast_types.AstExpr.Let _)
      (embedded-native-let-statement-code params node)]
    [(compiler_ast_types.AstExpr.While cond-node body-node)
      (let
        [condition : EmbeddedNativeDataValue
          (embedded-native-data-value params cond-node)]
        [body-code : String
          (embedded-native-computed-statement-code params body-node)]
        (if (string.eq (struct-get condition text) "")
          (embedded-native-fallback-code "statement-while:condition")
          (if (string.eq body-code "")
            (embedded-native-fallback-code "statement-while:body")
            (let
              [status : String (embedded-native-temp-name!)]
              (str_cat.str-cat
                (struct-get condition open)
                "  (let ["
                status
                " : i64 0]\n"
                "  (begin\n"
                "  (while (if (= "
                (struct-get condition text)
                " 1) (= "
                status
                " 0) false)\n"
                "  (set! "
                status
                "\n"
                body-code
                "))\n"
                status
                "))\n"
                (embedded-native-closing-parens
                  (* 2 (struct-get condition opens))))))))]
    [(compiler_ast_types.AstExpr.Set name-id value-node)
      (let
        [target : String
          (embedded-native-data-local-text (ci.intern-str name-id))]
        (if (not (string.eq target ""))
          (let
            [value : EmbeddedNativeDataValue
              (embedded-native-data-value params value-node)]
            (if (string.eq (struct-get value text) "")
              ""
              (str_cat.str-cat
                (struct-get value open)
                "  (begin\n  (set! "
                target
                " "
                (struct-get value text)
                ")\n  0)\n"
                (embedded-native-closing-parens (* 2 (struct-get value opens))))))
          (let
            [slot : i64 (embedded-native-local-index (ci.intern-str name-id))]
            (if (< slot 0)
              ""
              (embedded-native-computed-expr-code
                params
                value-node
                (embedded-native-local-set-final slot))))))]
    [(compiler_ast_types.AstExpr.If cond-node then-node else-node)
      (let
        [condition : EmbeddedNativeDataValue
          (embedded-native-data-value params cond-node)]
        [then-code : String
          (embedded-native-computed-statement-code params then-node)]
        [else-code : String
          (embedded-native-computed-statement-code params else-node)]
        (if (or
          (string.eq (struct-get condition text) "")
          (string.eq then-code "")
          (string.eq else-code ""))
          ""
          (str_cat.str-cat
            (struct-get condition open)
            "  (if (= "
            (struct-get condition text)
            " 1)\n"
            then-code
            else-code
            ")\n"
            (embedded-native-closing-parens (* 2 (struct-get condition opens))))))]
    ;; Diagnostic calls ignore this final and retain their interpreted status.
    [(compiler_ast_types.AstExpr.Call _ _)
      (embedded-native-computed-expr-code params node "  0\n")]
    [_
      (embedded-native-fallback-code
        (str_cat.str-cat
          "statement-node:"
          (embedded-native-expr-kind-name
            (embedded-stdlib-tlci-unwrap-expr node))))]))

(define (embedded-native-computed-statement-list-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [exprs : (& exprs compiler_ast_types.AstExprList)]
  [index : i64]) : String
  (if (>= index (compiler_ast_types.ast-expr-list-len exprs))
    "  0\n"
    (let
      [head : String
        (embedded-native-computed-statement-code
          params
          (compiler_ast_types.ast-expr-list-get exprs index 0))]
      (if (string.eq head "")
        ""
        (let
          [rest : String
            (embedded-native-computed-statement-list-code
              params
              exprs
              (+ index 1))]
          (if (string.eq rest "")
            ""
            (embedded-native-status-sequence-code head rest)))))))

(define (embedded-native-let-statement-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Let let-box)
      (match (box-get let-box)
        [(compiler_ast_types.AstLet.Let bindings body)
          (let
            [saved : i64 (array-ref embedded-native-local-len 0)]
            [data-saved : i64 (array-ref embedded-native-data-local-len 0)]
            [opens : (__tl_dyn-array i64) (make-array 0)]
            [open-code : String
              (embedded-native-let-bindings-open params (& bindings) 0 opens)]
            (if (string.eq open-code "\x01")
              (begin
                (embedded-native-fallback-reason-note! "statement-let:bindings")
                (array-set! embedded-native-local-len 0 saved)
                (array-set! embedded-native-data-local-len 0 data-saved)
                (if embedded-native-full-blocker-diagnostic-active
                  "  0\n"
                  ""))
              (let
                [body-code : String
                  (embedded-native-computed-statement-code params body)]
                (begin
                  (array-set! embedded-native-local-len 0 saved)
                  (array-set! embedded-native-data-local-len 0 data-saved)
                  (if (string.eq body-code "")
                    (embedded-native-fallback-code "statement-let:body")
                    (str_cat.str-cat
                      open-code
                      body-code
                      (embedded-native-closing-parens (array-ref opens 0))))))))])]
    [_ ""]))

;; Scalar conditions (including mutable data locals and local Expr probes) use
;; the same continuation shape as specialized length/string guards.
(define (embedded-native-computed-data-if-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [cond-node : i64]
  [then-code : String]
  [else-code : String]) : String
  (let
    [condition : EmbeddedNativeDataValue
      (embedded-native-data-value params cond-node)]
    (if (string.eq (struct-get condition text) "")
      ""
      (str_cat.str-cat
        (struct-get condition open)
        "  (if (= "
        (struct-get condition text)
        " 1)\n"
        then-code
        else-code
        ")\n"
        (embedded-native-closing-parens (* 2 (struct-get condition opens)))))))

;: The type-operand index of `(comptime.expr-int (array-length T))` given the
;: builder's argument list, or -1 when the argument is any other shape.
;: Refs #5701.
;; A one-entry ops array for a single host op.
(define (embedded-native-single-op-ops
  [op : String]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : (__tl_dyn-array String)
  (let
    [ops : (__tl_dyn-array String)
      (array.make-array String embedded-native-ops-cap)]
    [ops-count : (__tl_dyn-array i64) (make-array 0)]
    (begin
      (embedded-native-template-push! ops ops-count op arg-a arg-b arg-c)
      ops)))

;; `(if (string.eq A B) then else)` or `(if (cmp (expr-list-length p) lit)
;; then else)` with computed branches sharing one `final` operation.
(define (embedded-native-computed-if-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [cond-node : i64]
  [then-node : i64]
  [else-node : i64]
  [final : String]) : String
  (let
    [then-code : String
      (embedded-native-computed-expr-code params then-node final)]
    (if (string.eq then-code "")
      ""
      (let
        [else-code : String
          (embedded-native-computed-expr-code params else-node final)]
        (if (string.eq else-code "")
          ""
          (match (embedded-native-length-probe params cond-node)
            [(EmbeddedNativeLengthProbe.LengthProbe param ordinal literal)
              (str_cat.str-cat
                "  (let [t0 : i64 (comptime-host-expr-list-length host session "
                (string.int->string param)
                " 0 0)]\n"
                "  (if (< t0 0)\n  "
                (string.int->string
                  tlci_core.tlci-host-callback-status-bad-request)
                "\n  (if ("
                (embedded-native-comparison-spelling ordinal)
                " t0 "
                (string.int->string literal)
                ")\n"
                then-code
                else-code
                ")))\n")]
            [(EmbeddedNativeLengthProbe.NoLengthProbe)
              (match (embedded-stdlib-tlci-unwrap-expr cond-node)
                [(compiler_ast_types.AstExpr.Call cond-func cond-args)
                  (match (embedded-stdlib-tlci-unwrap-expr cond-func)
                    [(compiler_ast_types.AstExpr.Var cond-head)
                      (let
                        [cond-name : String (ci.intern-str cond-head)]
                        (cond
                          [(and
                              (or
                                (string.eq cond-name "comptime.array-dynamic?")
                                (string.eq cond-name "array-dynamic?"))
                              (=
                                (compiler_ast_types.ast-expr-list-len
                                  (& cond-args))
                                1))
                            (let
                              [ops : (__tl_dyn-array String)
                                (array.make-array
                                  String
                                  embedded-native-ops-cap)]
                              [ops-count : (__tl_dyn-array i64) (make-array 0)]
                              [opened : i64
                                (embedded-native-computed-expr-ops
                                  params
                                  (compiler_ast_types.ast-expr-list-get
                                    (& cond-args)
                                    0
                                    0)
                                  ops
                                  ops-count)]
                              (if (or
                                (< opened 0)
                                (>=
                                  (array-ref ops-count 0)
                                  embedded-native-ops-cap))
                                ""
                                (embedded-native-arm-block-with-final
                                  ops
                                  (array-ref ops-count 0)
                                  opened
                                  (str_cat.str-cat
                                    "  (let [t0 : i64 (comptime-host-array-dynamic? host session 0 0 0)] (if (< t0 0)\n  "
                                    (string.int->string
                                      tlci_core.tlci-host-callback-status-bad-request)
                                    "\n  (if (= t0 1)\n"
                                    then-code
                                    else-code
                                    ")))\n"))))]
                          ;; `(comptime.expr-string? p)`: the literal-template
                          ;; guard, probed as data on the operand the same way
                          ;; `array-dynamic?` is. Refs #5701.
                          [(and
                              (or
                                (string.eq cond-name "comptime.expr-string?")
                                (string.eq cond-name "expr-string?"))
                              (=
                                (compiler_ast_types.ast-expr-list-len
                                  (& cond-args))
                                1))
                            (let
                              [str-param : i64
                                (embedded-native-var-param-index
                                  params
                                  (compiler_ast_types.ast-expr-list-get
                                    (& cond-args)
                                    0
                                    0))]
                              (if (< str-param 0)
                                ""
                                (str_cat.str-cat
                                  "  (let [t0 : i64 (comptime-host-operand-expr-string? host session "
                                  (string.int->string str-param)
                                  " 0 0)] (if (< t0 0)\n  "
                                  (string.int->string
                                    tlci_core.tlci-host-callback-status-bad-request)
                                  "\n  (if (= t0 1)\n"
                                  then-code
                                  else-code
                                  ")))\n")))]
                          [else
                            (embedded-native-computed-data-if-code
                              params
                              cond-node
                              then-code
                              else-code)]))]
                    [_
                      (embedded-native-computed-data-if-code
                        params
                        cond-node
                        then-code
                        else-code)])]
                [_
                  (embedded-native-computed-data-if-code
                    params
                    cond-node
                    then-code
                    else-code)])]))))))

;; A computed value-position match first recognizes the narrow Expr.Var
;; destructuring shape used to validate generated-name operands. The bound name
;; is staged in a session local, so the arm may return it through the caller's
;; `final`; the wildcard arm retains the interpreted diagnostic path. Refs
;; #5606.
(define (embedded-native-computed-var-match-arm-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [param : i64]
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [body-node : i64]
  [final : String]) : String
  (let
    [saved : i64 (array-ref embedded-native-local-len 0)]
    [slot : i64
      (match (compiler_ast_types.ast-pattern-list-get
        pat-args
        0
        (compiler_ast_types.ast-pattern-fallback))
        [(compiler_ast_types.AstPattern.Binding bind-id)
          (embedded-native-local-push! (ci.intern-str bind-id))]
        [(compiler_ast_types.AstPattern.Wildcard) -2]
        [_ -1])]
    [arm-code : String
      (if (= slot -1)
        ""
        (embedded-native-computed-expr-code params body-node final))]
    (begin
      (array-set! embedded-native-local-len 0 saved)
      (let
        [rest-code : String
          (embedded-native-computed-var-match-arms-code
            params
            arms
            (+ index 1)
            param
            final)]
        (if (or (string.eq arm-code "") (string.eq rest-code ""))
          ""
          (let
            [probe : String (embedded-native-temp-name!)]
            (str_cat.str-cat
              "  (let ["
              probe
              " : i64 (comptime-host-operand-expr-var? host session "
              (string.int->string param)
              " 0 0)]\n"
              "  (if (< "
              probe
              " 0)\n  "
              (string.int->string
                tlci_core.tlci-host-callback-status-bad-request)
              "\n  (if (= "
              probe
              " 1)\n"
              (if (>= slot 0)
                (str_cat.str-cat
                  "  (let [s"
                  (string.int->string slot)
                  " : i64\n"
                  (embedded-native-arm-block-with-final
                    (embedded-native-single-op-ops
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-operand-expr-var-name)
                      (string.int->string param)
                      "0"
                      "0")
                    1
                    1
                    (embedded-native-local-set-final slot))
                  "] (if (not (= s"
                  (string.int->string slot)
                  " 0)) s"
                  (string.int->string slot)
                  "\n")
                "")
              arm-code
              (if (>= slot 0)
                "))\n"
                "")
              rest-code
              ")))\n")))))))

(define (embedded-native-computed-var-match-arms-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [param : i64]
  [final : String]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
        (match pattern
          [(compiler_ast_types.AstPattern.Variant name-id args-box)
            (let
              [pat-args : compiler_ast_types.AstPatternList (box-get args-box)]
              (if (and
                (string.eq (embedded-native-expr-variant-name name-id) "Var")
                (= (struct-get pat-args len) 1))
                (embedded-native-computed-var-match-arm-code
                  params
                  arms
                  index
                  param
                  (& pat-args)
                  body-node
                  final)
                ""))]
          [(compiler_ast_types.AstPattern.Wildcard)
            (embedded-native-computed-expr-code params body-node final)]
          [_ ""])])))

;; A computed `(match scrutinee ["literal" arm] ... [_ else])` over a String
;; scrutinee: the scrutinee is computed into a fresh session slot, then each
;; literal arm compares with raw local-get/string-value/string-eq chains.
(define (embedded-native-computed-match-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [match-box : (Box compiler_ast_types.AstMatch)]
  [final : String]) : String
  (match (box-get match-box)
    [(compiler_ast_types.AstMatch.Match scrutinee arms)
      (let
        [param : i64 (embedded-native-var-param-index params scrutinee)]
        [value-text : String
          (if (< param 0)
            ""
            (embedded-native-computed-var-match-arms-code
              params
              (& arms)
              0
              param
              final))]
        (if (not (string.eq value-text ""))
          value-text
          (embedded-native-computed-string-match-code
            params
            scrutinee
            (& arms)
            final)))]))

(define (embedded-native-computed-string-match-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [scrutinee : i64]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [final : String]) : String
  (let
    [slot : i64 (embedded-native-local-push! "__tlci_match")]
    (if (< slot 0)
      ""
      (let
        [scrut-code : String
          (embedded-native-computed-expr-code
            params
            scrutinee
            (embedded-native-local-set-final slot))]
        (if (string.eq scrut-code "")
          ""
          (let
            [arms-code : String
              (embedded-native-computed-match-arms-code
                params
                arms
                0
                slot
                final)]
            (if (string.eq arms-code "")
              ""
              (str_cat.str-cat
                "  (let [m"
                (string.int->string slot)
                " : i64\n"
                scrut-code
                "] (if (not (= m"
                (string.int->string slot)
                " 0)) m"
                (string.int->string slot)
                "\n"
                arms-code
                "))\n"))))))))

(define (embedded-native-computed-match-arms-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [slot : i64]
  [final : String]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
        (match pattern
          [(compiler_ast_types.AstPattern.Literal
              (compiler_ast_types.AstLiteral.String sid))
            (let
              [lit : String (ci.intern-str sid)]
              [blockers-before : i64 embedded-native-full-blocker-events]
              [arm-code : String
                (embedded-native-computed-expr-code params body-node final)]
              [rest-code : String
                (embedded-native-computed-match-arms-code
                  params
                  arms
                  (+ index 1)
                  slot
                  final)]
              (if (string.eq arm-code "")
                (begin
                  (when
                    (embedded-native-fallback-unreported-since? blockers-before)
                    (embedded-native-fallback-reason-note!
                      (str_cat.str-cat
                        "computed-match-arm:"
                        (string.int->string index)
                        ":body-shape:"
                        (embedded-native-expr-kind-name
                          (embedded-stdlib-tlci-unwrap-expr body-node)))))
                  "")
                (if (string.eq rest-code "")
                  ""
                  (str_cat.str-cat
                    "  (let [t"
                    (string.int->string index)
                    " : i64 (comptime-host-local-get host session "
                    (string.int->string slot)
                    " 0 0)] (if (not (= t"
                    (string.int->string index)
                    " 0)) t"
                    (string.int->string index)
                    "\n  (let [u"
                    (string.int->string index)
                    " : i64 (comptime-host-string-value host session "
                    (embedded-native-name-arg
                      (embedded-native-escape-string lit))
                    " "
                    (string.int->string (string.string-length lit))
                    " 0)] (if (not (= u"
                    (string.int->string index)
                    " 0)) u"
                    (string.int->string index)
                    "\n  (let [c"
                    (string.int->string index)
                    " : i64 (comptime-host-string-eq host session 0 0 0)] (if (< c"
                    (string.int->string index)
                    " 0)\n  "
                    (string.int->string
                      tlci_core.tlci-host-callback-status-bad-request)
                    "\n  (if (= c"
                    (string.int->string index)
                    " 1)\n"
                    arm-code
                    rest-code
                    ")))))))\n"))))]
          [(compiler_ast_types.AstPattern.Wildcard)
            (let
              [blockers-before : i64 embedded-native-full-blocker-events]
              [arm-code : String
                (embedded-native-computed-expr-code params body-node final)]
              (if (string.eq arm-code "")
                (begin
                  (when
                    (embedded-native-fallback-unreported-since? blockers-before)
                    (embedded-native-fallback-reason-note!
                      (str_cat.str-cat
                        "computed-match-arm:"
                        (string.int->string index)
                        ":body-shape:"
                        (embedded-native-expr-kind-name
                          (embedded-stdlib-tlci-unwrap-expr body-node)))))
                  "")
                arm-code))]
          [_ ""])])))

;; Compile a let-rooted body: each binding's init becomes either a compile-time
;; data local (a scalar the host answers as data) or a session slot holding a
;; comptime value, then the body compiles with the new locals visible. let*
;; scoping: binding inits see only earlier locals, and both local tables are
;; restored afterwards. Refs #5603, #5701.
(define (embedded-native-let-body-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.Let let-box)
      (match (box-get let-box)
        [(compiler_ast_types.AstLet.Let bindings body)
          (let
            [saved : i64 (array-ref embedded-native-local-len 0)]
            [data-saved : i64 (array-ref embedded-native-data-local-len 0)]
            [opens : (__tl_dyn-array i64) (make-array 0)]
            [open-code : String
              (embedded-native-let-bindings-open params (& bindings) 0 opens)]
            (if (string.eq open-code "\x01")
              (begin
                (array-set! embedded-native-local-len 0 saved)
                (array-set! embedded-native-data-local-len 0 data-saved)
                "")
              (let
                [body-code : String (embedded-native-body-code params body)]
                (begin
                  (array-set! embedded-native-local-len 0 saved)
                  (array-set! embedded-native-data-local-len 0 data-saved)
                  (if (string.eq body-code "")
                    ""
                    (str_cat.str-cat
                      open-code
                      body-code
                      (embedded-native-closing-parens (array-ref opens 0))))))))]
        [_ ""])]
    [_ ""]))

;; The open chain for one or more bindings, or "\x01" on any failure (a
;; sentinel that cannot appear in valid generated code). `opens` accumulates
;; the closing parens the chain owes, which is per binding neither fixed nor
;; the same across the two binding kinds: a session binding always opens a
;; let/if pair, a probed data binding opens one pair per probe, and a data
;; binding that folds to plain arithmetic over names already in scope opens
;; nothing at all.
(define (embedded-native-let-bindings-open
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [bindings : (& bindings compiler_ast_types.AstLetBindingList)]
  [index : i64]
  [opens : (__tl_dyn-array i64)]) : String
  (if (>= index (struct-get bindings len))
    ""
    (match (compiler_ast_types.ast-let-binding-list-get
      bindings
      index
      (compiler_ast_types.ast-let-binding-fallback))
      [(compiler_ast_types.AstLetBinding.Binding name _ init)
        (let
          [blockers-before : i64 embedded-native-full-blocker-events]
          [binding-code : String
            (embedded-native-let-binding-open params name init opens)]
          (if (string.eq binding-code "\x01")
            (begin
              (when
                (embedded-native-fallback-unreported-since? blockers-before)
                (embedded-native-fallback-reason-note!
                  (str_cat.str-cat
                    "let-binding:"
                    (ci.intern-str name)
                    ":unsupported-init")))
              (if embedded-native-full-blocker-diagnostic-active
                (embedded-native-let-bindings-open
                  params
                  bindings
                  (+ index 1)
                  opens)
                "\x01"))
            (let
              [rest : String
                (embedded-native-let-bindings-open
                  params
                  bindings
                  (+ index 1)
                  opens)]
              (if (string.eq rest "\x01")
                "\x01"
                (str_cat.str-cat binding-code rest)))))])))

;; One binding: an i64-valued init joins the compile-time data table. Materialize
;; every such binding as a generated local: interpreted let evaluates the init
;; once, and statement-position `set!` may update any scalar binding (not just a
;; literal bool). Session values use host local slots below.
;; Anything else is computed into a session slot. A name that would shadow a
;; binding in the *other* table keeps the fallback shell: the two tables are
;; searched independently, so the shadowed spelling would resolve to the data
;; local in index position and to the stale session slot in template position.
;; Refs #5603, #5701, #5656.
(define (embedded-native-let-binding-open
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [name : i64]
  [init : i64]
  [opens : (__tl_dyn-array i64)]) : String
  (let
    [data : EmbeddedNativeDataValue (embedded-native-data-value params init)]
    (if (not (string.eq (struct-get data text) ""))
      (let
        [generated : String (embedded-native-temp-name!)]
        (if (and
          (< (embedded-native-local-index (ci.intern-str name)) 0)
          (embedded-native-data-local-push! (ci.intern-str name) generated))
          (begin
            (array-set!
              opens
              0
              (+ (array-ref opens 0) (* 2 (struct-get data opens)) 1))
            (str_cat.str-cat
              (struct-get data open)
              "  (let ["
              generated
              " : i64 "
              (struct-get data text)
              "]\n"))
          "\x01"))
      (if (not
        (string.eq (embedded-native-data-local-text (ci.intern-str name)) ""))
        "\x01"
        (embedded-native-let-session-binding-open params name init opens)))))

(define (embedded-native-let-session-binding-open
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [name : i64]
  [init : i64]
  [opens : (__tl_dyn-array i64)]) : String
  (let
    [slot : i64 (embedded-native-local-push! (ci.intern-str name))]
    (if (< slot 0)
      "\x01"
      (let
        [init-code : String
          (embedded-native-computed-expr-code
            params
            init
            (embedded-native-local-set-final slot))]
        (if (string.eq init-code "")
          "\x01"
          (begin
            (array-set! opens 0 (+ (array-ref opens 0) 2))
            (str_cat.str-cat
              "  (let [s"
              (string.int->string slot)
              " : i64\n"
              init-code
              "] (if (not (= s"
              (string.int->string slot)
              " 0)) s"
              (string.int->string slot)
              "\n")))))))

(define (embedded-native-closing-parens [count : i64]) : String
  (if (<= count 0)
    ""
    (str_cat.str-cat ")" (embedded-native-closing-parens (- count 1)))))

;; Desugar `(match (type-kind T) ["kind" template] ...)` into nested
;; type-kind-eq queries with a complete arm block per match; an unmatched
;; scrutinee falls back to the interpreter by returning ok with no result.
;; Returns "" when the body is outside the supported shape.
(define (embedded-native-match-arms
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [probe-op : String]
  [type-index : i64]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]) : String
  ;; Falling off the end of the arm chain is itself an interpreted-arm site: it
  ;; is reached at run time whenever no arm's probe matched, which only happens
  ;; for a dispatch with no wildcard default. Mark it so the coverage report
  ;; counts it; a dispatch that does end in a wildcard never reaches here.
  (if (>= index (struct-get arms len))
    (embedded-native-global-shared-view embedded-native-interpreted-arm-code)
    (match (array-ref (struct-get arms slots) index)
      [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
        (match pattern
          [(compiler_ast_types.AstPattern.Literal
              (compiler_ast_types.AstLiteral.String sid))
            (let
              [kind : String (ci.intern-str sid)]
              [arm-code : String (embedded-native-body-code params body-node)]
              [rest : String
                (embedded-native-match-arms
                  params
                  probe-op
                  type-index
                  arms
                  (+ index 1))]
              (if (string.eq rest "")
                ""
                (str_cat.str-cat
                  "  (let [t"
                  (string.int->string index)
                  " : i64 (comptime-host-"
                  probe-op
                  " host session "
                  (string.int->string type-index)
                  " "
                  (embedded-native-name-arg kind)
                  " "
                  (string.int->string (string.string-length kind))
                  ")]\n"
                  "  (if (< t"
                  (string.int->string index)
                  " 0)\n"
                  "  "
                  (string.int->string
                    tlci_core.tlci-host-callback-status-bad-request)
                  "\n"
                  "  (if (= t"
                  (string.int->string index)
                  " 1)\n"
                  (if (string.eq arm-code "")
                    (embedded-native-global-shared-view
                      embedded-native-interpreted-arm-code)
                    arm-code)
                  "\n"
                  rest
                  ")))\n")))]
          ;; A wildcard arm ends the chain: nothing after it is reachable, so
          ;; its body compiles as the final alternative instead of handing the
          ;; scrutinee back to the interpreter. This is the whole of the
          ;; `partial-entries` gap -- `stdlib.eq/inline-eq` raises a
          ;; comptime-error here and `stdlib.hash/hash` generates its module for
          ;; every type except `unit`. Refs #5658.
          [(compiler_ast_types.AstPattern.Wildcard)
            (let
              [arm-code : String (embedded-native-body-code params body-node)]
              (if (string.eq arm-code "")
                (embedded-native-global-shared-view
                  embedded-native-interpreted-arm-code)
                arm-code))]
          [_
            (embedded-native-global-shared-view
              embedded-native-interpreted-arm-code)])])))

;; One recognized string-dispatch scrutinee: the data probe op and the operand
;; index it reads. Refs #5604.
(defenum EmbeddedNativeScrutineeProbe
  (ScrutineeProbe String i64)
  (NoScrutineeProbe))

;; Recognize the three string-valued scrutinee shapes the stdlib dispatches
;; on: `(type-kind T)` over a type operand, `(type-kind (comptime.expr-type
;; e))` over an Expr operand's produced type, and `(type-key T)`. Each maps to
;; a probe with the same 1/0-as-data contract, so the arm chain is identical.
(define (embedded-native-scrutinee-probe
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [scrutinee : i64]) : EmbeddedNativeScrutineeProbe
  (match (embedded-stdlib-tlci-unwrap-expr scrutinee)
    [(compiler_ast_types.AstExpr.Call head-id args)
      (match (embedded-stdlib-tlci-unwrap-expr head-id)
        [(compiler_ast_types.AstExpr.Var head-name)
          (let
            [head : String (ci.intern-str head-name)]
            [kind? : bool
              (or
                (string.eq head "type-kind")
                (string.eq head "comptime.type-kind"))]
            [key? : bool
              (or
                (string.eq head "type-key")
                (string.eq head "comptime.type-key"))]
            (if (or
              (not (or kind? key?))
              (not (= (compiler_ast_types.ast-expr-list-len (& args)) 1)))
              (EmbeddedNativeScrutineeProbe.NoScrutineeProbe)
              (let
                [arg-node : i64
                  (compiler_ast_types.ast-expr-list-get (& args) 0 0)]
                [direct : i64 (embedded-native-var-param-index params arg-node)]
                (if (>= direct 0)
                  (EmbeddedNativeScrutineeProbe.ScrutineeProbe
                    (if kind?
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-operand-type-kind-eq)
                      (tlci_core.tlci-host-callback-name-shared-view
                        tlci_core.tlci-host-callback-name-operand-type-key-eq))
                    direct)
                  ;; `(type-kind (comptime.expr-type e))` is the only nested
                  ;; operand form in the dispatch set; `type-key` never wraps
                  ;; one.
                  (if key?
                    (EmbeddedNativeScrutineeProbe.NoScrutineeProbe)
                    (let
                      [expr-index : i64
                        (embedded-native-expr-type-param-index params arg-node)]
                      (if (< expr-index 0)
                        (EmbeddedNativeScrutineeProbe.NoScrutineeProbe)
                        (EmbeddedNativeScrutineeProbe.ScrutineeProbe
                          (tlci_core.tlci-host-callback-name-shared-view
                            tlci_core.tlci-host-callback-name-operand-expr-type-kind-eq)
                          expr-index))))))))]
        [_ (EmbeddedNativeScrutineeProbe.NoScrutineeProbe)])]
    [_ (EmbeddedNativeScrutineeProbe.NoScrutineeProbe)]))

;; The operand index behind `(comptime.expr-type <param>)`, or -1.
(define (embedded-native-expr-type-param-index
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call head-id args)
      (match (embedded-stdlib-tlci-unwrap-expr head-id)
        [(compiler_ast_types.AstExpr.Var head-name)
          (if (and
            (or
              (string.eq (ci.intern-str head-name) "comptime.expr-type")
              (string.eq (ci.intern-str head-name) "expr-type"))
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1))
            (embedded-native-var-param-index
              params
              (compiler_ast_types.ast-expr-list-get (& args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

(define (embedded-native-match-body
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.Match match-box)
      (match (box-get match-box)
        [(compiler_ast_types.AstMatch.Match scrutinee arms)
          (match (embedded-native-scrutinee-probe params scrutinee)
            [(EmbeddedNativeScrutineeProbe.ScrutineeProbe
                probe-op
                operand-index)
              (embedded-native-match-arms
                params
                probe-op
                operand-index
                (& arms)
                0)]
            [_ ""])])]
    [_ ""]))

;; One extracted `(cmp (comptime.expr-list-length p) lit)` condition: the
;; variadic-operand index, the comparison AstBinOp ordinal (Eq..Ge only), and
;; the canonical literal bound.
(defenum EmbeddedNativeLengthProbe
  (LengthProbe i64 i64 i64)
  (NoLengthProbe))

;: The variadic-operand index of a `(comptime.expr-list-length p)` call; -1 for
;: any other expression. Refs #5617.
(define (embedded-native-expr-list-length-param
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(compiler_ast_types.AstExpr.Call length-func length-args)
      (match (embedded-stdlib-tlci-unwrap-expr length-func)
        [(compiler_ast_types.AstExpr.Var length-head)
          (if (and
            (or
              (string.eq
                (ci.intern-str length-head)
                "comptime.expr-list-length")
              (string.eq (ci.intern-str length-head) "expr-list-length"))
            (= (compiler_ast_types.ast-expr-list-len (& length-args)) 1))
            (embedded-native-var-param-index
              params
              (compiler_ast_types.ast-expr-list-get (& length-args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

;; Extract `(cmp (comptime.expr-list-length p) lit)` with the length call on
;; the left and a canonical int literal on the right. Anything else is not a
;; length probe.
(define (embedded-native-length-probe
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [cond-node : i64]) : EmbeddedNativeLengthProbe
  (match (embedded-stdlib-tlci-unwrap-expr cond-node)
    [(compiler_ast_types.AstExpr.Binary op left-node right-node)
      (let
        [ordinal : i64 (embedded-native-binop-ordinal op)]
        [param : i64 (embedded-native-expr-list-length-param params left-node)]
        (if (or (< ordinal 5) (> ordinal 10) (< param 0))
          (EmbeddedNativeLengthProbe.NoLengthProbe)
          (match (embedded-stdlib-tlci-unwrap-expr right-node)
            [(compiler_ast_types.AstExpr.Literal
                (compiler_ast_types.AstLiteral.Int value text))
              (if (or
                (= (string.string-length text) 0)
                (string.eq text (string.int->string value)))
                (EmbeddedNativeLengthProbe.LengthProbe param ordinal value)
                (EmbeddedNativeLengthProbe.NoLengthProbe))]
            [_ (EmbeddedNativeLengthProbe.NoLengthProbe)])))]
    [_ (EmbeddedNativeLengthProbe.NoLengthProbe)]))

;; Compile `(match (comptime.expr-list-length p) [<int> body] ... [n body])`:
;; the operand count is probed once into a fresh i64 temporary, each integer
;; arm compares against it, and a trailing binder or wildcard arm is the
;; default. A binder also binds the count as a compile-time data local so the
;; arm can rebuild it with `(comptime.expr-int n)`. Returns "" outside that
;; shape. Refs #5617.
(define (embedded-native-int-match-body
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.Match match-box)
      (match (box-get match-box)
        [(compiler_ast_types.AstMatch.Match scrutinee arms)
          (let
            [param : i64
              (embedded-native-expr-list-length-param params scrutinee)]
            (if (< param 0)
              ""
              (let
                [name : String (embedded-native-temp-name!)]
                [arms-code : String
                  (embedded-native-int-match-arms params (& arms) 0 name)]
                (if (string.eq arms-code "")
                  ""
                  (str_cat.str-cat
                    "  (let ["
                    name
                    " : i64 (comptime-host-expr-list-length host session "
                    (string.int->string param)
                    " 0 0)]\n"
                    "  (if (< "
                    name
                    " 0)\n  "
                    (string.int->string
                      tlci_core.tlci-host-callback-status-bad-request)
                    "\n"
                    arms-code
                    "))\n")))))])]
    [_ ""]))

;; Compile `(match <operand> [(comptime.Expr.Call callee args) body] ... [_ body])`:
;; the operand's expression shape is probed as data, and a matching arm binds
;; the callee expression and the argument list into session local slots, the
;; same two values the interpreted `comptime.Expr.Call` pattern binds. Returns
;; "" outside that shape. Refs #5602.
(define (embedded-native-value-match-body
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(compiler_ast_types.AstExpr.Match match-box)
      (match (box-get match-box)
        [(compiler_ast_types.AstMatch.Match scrutinee arms)
          (let
            [param : i64 (embedded-native-var-param-index params scrutinee)]
            (if (< param 0)
              ""
              (embedded-native-value-match-arms params (& arms) 0 param)))])]
    [_ ""]))

;: The `comptime.Expr.<name>` variant a pattern names, or "" for anything else.
(define (embedded-native-expr-variant-name [name-id : i64]) : String
  (let
    [name : String (ci.intern-str name-id)]
    (cond
      [(string.eq name "comptime.Expr.Call") "Call"]
      [(string.eq name "Expr.Call") "Call"]
      [(string.eq name "comptime.Expr.Int") "Int"]
      [(string.eq name "Expr.Int") "Int"]
      [(string.eq name "comptime.Expr.Var") "Var"]
      [(string.eq name "Expr.Var") "Var"]
      [else ""])))

;; One `(comptime.Expr.Int i)` arm: the operand's shape is probed as data, and
;; the matching arm reads the literal's value into a fresh i64 temporary bound
;; as a compile-time data local for the arm body. Refs #5602.
(define (embedded-native-int-value-arm-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [body-node : i64]
  [param : i64]
  [rest : String]) : String
  (let
    [probe : String (embedded-native-temp-name!)]
    [value : String (embedded-native-temp-name!)]
    [saved : i64 (array-ref embedded-native-data-local-len 0)]
    [bound : bool
      (match (compiler_ast_types.ast-pattern-list-get
        pat-args
        0
        (compiler_ast_types.ast-pattern-fallback))
        [(compiler_ast_types.AstPattern.Wildcard) true]
        [(compiler_ast_types.AstPattern.Binding bind-id)
          (embedded-native-data-local-push! (ci.intern-str bind-id) value)]
        [_ false])]
    [arm-code : String
      (if bound
        (embedded-native-body-code params body-node)
        "")]
    (begin
      (array-set! embedded-native-data-local-len 0 saved)
      (if (or (string.eq arm-code "") (string.eq rest ""))
        ""
        (str_cat.str-cat
          "  (let ["
          probe
          " : i64 (comptime-host-operand-expr-int? host session "
          (string.int->string param)
          " 0 0)]\n"
          "  (if (< "
          probe
          " 0)\n  "
          (string.int->string tlci_core.tlci-host-callback-status-bad-request)
          "\n  (if (= "
          probe
          " 1)\n"
          "  (let ["
          value
          " : i64 (comptime-host-operand-expr-int-value host session "
          (string.int->string param)
          " 0 0)]\n"
          arm-code
          ")\n"
          rest
          ")))\n")))))

;; One `[(comptime.Expr.Var t) body]` arm: the operand's identifier shape is
;; probed as data, and the matching arm binds the identifier's spelling into a
;; session slot as a comptime String, so the body can append to it. Unlike the
;; `Expr.Int` arm this binds a *session* local rather than a generated i64
;; variable, because the payload is a String value the existing string-append
;; and expr-var op chains already consume. Refs #5700.
(define (embedded-native-var-value-arm-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [body-node : i64]
  [param : i64]
  [rest : String]) : String
  (let
    [probe : String (embedded-native-temp-name!)]
    [saved : i64 (array-ref embedded-native-local-len 0)]
    [slot : i64
      (match (compiler_ast_types.ast-pattern-list-get
        pat-args
        0
        (compiler_ast_types.ast-pattern-fallback))
        [(compiler_ast_types.AstPattern.Binding bind-id)
          (embedded-native-local-push! (ci.intern-str bind-id))]
        [(compiler_ast_types.AstPattern.Wildcard) -2]
        [_ -1])]
    [arm-code : String
      (if (= slot -1)
        ""
        (embedded-native-body-code params body-node))]
    (begin
      (array-set! embedded-native-local-len 0 saved)
      (if (or (string.eq arm-code "") (string.eq rest ""))
        ""
        (str_cat.str-cat
          "  (let ["
          probe
          " : i64 (comptime-host-operand-expr-var? host session "
          (string.int->string param)
          " 0 0)]
"
          "  (if (< "
          probe
          " 0)
  "
          (string.int->string tlci_core.tlci-host-callback-status-bad-request)
          "
  (if (= "
          probe
          " 1)
"
          (if (>= slot 0)
            (str_cat.str-cat
              "  (let [s"
              (string.int->string slot)
              " : i64
"
              (embedded-native-arm-block-with-final
                (embedded-native-single-op-ops
                  (tlci_core.tlci-host-callback-name-shared-view
                    tlci_core.tlci-host-callback-name-operand-expr-var-name)
                  (string.int->string param)
                  "0"
                  "0")
                1
                1
                (embedded-native-local-set-final slot))
              "] (if (not (= s"
              (string.int->string slot)
              " 0)) s"
              (string.int->string slot)
              "
")
            "")
          arm-code
          (if (>= slot 0)
            (embedded-native-closing-parens 2)
            "")
          "
"
          rest
          ")))
")))))

(define (embedded-native-value-match-arms
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [param : i64]) : String
  (if (>= index (struct-get arms len))
    "  0
"
    (match (array-ref (struct-get arms slots) index)
      [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
        (match pattern
          [(compiler_ast_types.AstPattern.Variant name-id args-box)
            (let
              [pat-args : compiler_ast_types.AstPatternList (box-get args-box)]
              (embedded-native-value-match-variant-arm
                params
                arms
                index
                param
                (embedded-native-expr-variant-name name-id)
                (& pat-args)
                body-node))]
          [(compiler_ast_types.AstPattern.Wildcard)
            (embedded-native-body-code params body-node)]
          [_ ""])])))

;; One variant-pattern arm of an operand value match. Split out of
;; `embedded-native-value-match-arms` so the three destructuring shapes form a
;; flat guard ladder rather than a nested if chain.
(define (embedded-native-value-match-variant-arm
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [param : i64]
  [variant : String]
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [body-node : i64]) : String
  (cond
    [(and (string.eq variant "Var") (= (struct-get pat-args len) 1))
      (embedded-native-var-value-arm-code
        params
        pat-args
        body-node
        param
        (embedded-native-value-match-arms params arms (+ index 1) param))]
    [(and (string.eq variant "Int") (= (struct-get pat-args len) 1))
      (embedded-native-int-value-arm-code
        params
        pat-args
        body-node
        param
        (embedded-native-value-match-arms params arms (+ index 1) param))]
    [(and (string.eq variant "Call") (= (struct-get pat-args len) 2))
      (embedded-native-call-value-arm-code
        params
        arms
        index
        param
        pat-args
        body-node)]
    [else ""]))

;; The `(comptime.Expr.Call callee args)` arm: probe the operand's shape, bind
;; both payloads into session slots, then chain the remaining arms.
(define (embedded-native-call-value-arm-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [param : i64]
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [body-node : i64]) : String
  (let
    [name : String (embedded-native-temp-name!)]
    [saved : i64 (array-ref embedded-native-local-len 0)]
    [bind-code : String (embedded-native-value-match-bind pat-args 0 param)]
    [arm-code : String
      (if (string.eq bind-code "")
        ""
        (embedded-native-body-code params body-node))]
    [bound : i64 (embedded-native-pattern-binder-count pat-args 0)]
    (begin
      (array-set! embedded-native-local-len 0 saved)
      (let
        [rest : String
          (embedded-native-value-match-arms params arms (+ index 1) param)]
        (if (or (string.eq arm-code "") (string.eq rest ""))
          ""
          (str_cat.str-cat
            "  (let ["
            name
            " : i64 (comptime-host-operand-expr-call? host session "
            (string.int->string param)
            " 0 0)]
"
            "  (if (< "
            name
            " 0)
  "
            (string.int->string tlci_core.tlci-host-callback-status-bad-request)
            "
  (if (= "
            name
            " 1)
"
            bind-code
            arm-code
            (embedded-native-closing-parens (* 2 bound))
            "
"
            rest
            ")))
"))))))

(define (embedded-native-pattern-binder-count
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [index : i64]) : i64
  (if (>= index (struct-get pat-args len))
    0
    (+
      (match (compiler_ast_types.ast-pattern-list-get
        pat-args
        index
        (compiler_ast_types.ast-pattern-fallback))
        [(compiler_ast_types.AstPattern.Binding _) 1]
        [_ 0])
      (embedded-native-pattern-binder-count pat-args (+ index 1)))))

;; Emit the `(let [sN : i64 <accessor>] (if (not (= sN 0)) sN` opens that bind
;; one arm's payload patterns to session local slots: a binder takes the value,
;; a wildcard consumes nothing. Returns "\x01" on any unsupported piece.
(define (embedded-native-value-match-bind
  [pat-args : (& pat-args compiler_ast_types.AstPatternList)]
  [index : i64]
  [param : i64]) : String
  (if (>= index (struct-get pat-args len))
    ""
    (let
      [op : String
        (if (= index 0)
          (tlci_core.tlci-host-callback-name-shared-view
            tlci_core.tlci-host-callback-name-operand-expr-call-callee)
          (tlci_core.tlci-host-callback-name-shared-view
            tlci_core.tlci-host-callback-name-operand-expr-call-args))]
      [head : String
        (match (compiler_ast_types.ast-pattern-list-get
          pat-args
          index
          (compiler_ast_types.ast-pattern-fallback))
          [(compiler_ast_types.AstPattern.Wildcard) ""]
          [(compiler_ast_types.AstPattern.Binding bind-id)
            (let
              [slot : i64 (embedded-native-local-push! (ci.intern-str bind-id))]
              (if (< slot 0)
                "\x01"
                (str_cat.str-cat
                  "  (let [s"
                  (string.int->string slot)
                  " : i64\n"
                  (embedded-native-arm-block-with-final
                    (embedded-native-single-op-ops
                      op
                      (string.int->string param)
                      "0"
                      "0")
                    1
                    1
                    (embedded-native-local-set-final slot))
                  "] (if (not (= s"
                  (string.int->string slot)
                  " 0)) s"
                  (string.int->string slot)
                  "\n")))]
          [_ "\x01"])]
      (if (string.eq head "\x01")
        "\x01"
        (let
          [rest : String
            (embedded-native-value-match-bind pat-args (+ index 1) param)]
          (if (string.eq rest "\x01")
            "\x01"
            (str_cat.str-cat head rest)))))))

(define (embedded-native-int-match-arms
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [arms : (& arms compiler_ast_types.AstMatchArmList)]
  [index : i64]
  [name : String]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(compiler_ast_types.AstMatchArm.Arm pattern body-node)
        (match pattern
          [(compiler_ast_types.AstPattern.Literal
              (compiler_ast_types.AstLiteral.Int value text))
            (if (and
              (> (string.string-length text) 0)
              (not (string.eq text (string.int->string value))))
              ""
              (let
                [arm-code : String (embedded-native-body-code params body-node)]
                [rest : String
                  (embedded-native-int-match-arms params arms (+ index 1) name)]
                (if (or (string.eq arm-code "") (string.eq rest ""))
                  ""
                  (str_cat.str-cat
                    "  (if (= "
                    name
                    " "
                    (string.int->string value)
                    ")\n"
                    arm-code
                    rest
                    ")\n"))))]
          [(compiler_ast_types.AstPattern.Wildcard)
            (embedded-native-body-code params body-node)]
          [(compiler_ast_types.AstPattern.Binding binder)
            (embedded-native-int-match-default params body-node binder name)]
          [(compiler_ast_types.AstPattern.Var
              binder
              (compiler_ast_types.AstMaybeType.No))
            (embedded-native-int-match-default params body-node binder name)]
          [_ ""])])))

;; The default arm of a computed integer match: the binder names the probed
;; count for the arm body, and the binding is dropped again afterwards.
(define (embedded-native-int-match-default
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]
  [binder : i64]
  [name : String]) : String
  (let
    [saved : i64 (array-ref embedded-native-data-local-len 0)]
    [bound : bool
      (embedded-native-data-local-push! (ci.intern-str binder) name)]
    [code : String
      (if bound
        (embedded-native-body-code params body-node)
        "")]
    (begin
      (array-set! embedded-native-data-local-len 0 saved)
      code)))

;; Compile a linear op-chain body (template, fold, or plain builder) into a
;; complete arm block; returns "" when the body is outside the supported
;; subset or would overflow the per-entry op budget (a dropped op can never
;; be emitted silently).
(define (embedded-native-linear-body-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (let
    [ops : (__tl_dyn-array String)
      (array.make-array String embedded-native-ops-cap)]
    [ops-count : (__tl_dyn-array i64) (make-array 0)]
    [opened : i64 (embedded-native-body-ops params body-node ops ops-count)]
    (if (or (< opened 0) (>= (array-ref ops-count 0) embedded-native-ops-cap))
      ""
      (embedded-native-arm-block ops (array-ref ops-count 0) opened))))

;; Unified native body compiler: a type-kind match, a computed list-length
;; if, or a linear template/fold/plain body. Returns "" when the body stays
;; an interpreted-fallback shell.
;; Last-resort reason: when every body compiler declines and none of them
;; recorded why, name the body's own shape so the report says something more
;; useful than "unreported". The body-level compilers (let/match/if) each have
;; several give-up points; this catches all of them at one place. Refs #5596.
(define (embedded-native-body-code
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (let
    [blockers-before : i64 embedded-native-full-blocker-events]
    [text : String (embedded-native-body-code-inner params body-node)]
    (begin
      (embedded-native-full-walked-note!
        (str_cat.str-cat
          "body-shape:"
          (embedded-native-expr-kind-name
            (embedded-stdlib-tlci-unwrap-expr body-node))))
      (when
        (and
          (= (string.string-length text) 0)
          (embedded-native-fallback-unreported-since? blockers-before))
        (embedded-native-fallback-reason-note!
          (str_cat.str-cat
            "body-shape:"
            (embedded-native-expr-kind-name
              (embedded-stdlib-tlci-unwrap-expr body-node)))))
      text)))

(define (embedded-native-body-code-inner
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : String
  (let
    [let-blockers-before : i64 embedded-native-full-blocker-events]
    [let-text : String (embedded-native-let-body-code params body-node)]
    (if (not (string.eq let-text ""))
      let-text
      (if (and
        embedded-native-full-blocker-diagnostic-active
        (> embedded-native-full-blocker-events let-blockers-before))
        "  0\n"
        (let
          [match-blockers-before : i64 embedded-native-full-blocker-events]
          [match-text : String (embedded-native-match-body params body-node)]
          (if (not (string.eq match-text ""))
            match-text
            (if (and
              embedded-native-full-blocker-diagnostic-active
              (> embedded-native-full-blocker-events match-blockers-before))
              "  0\n"
              (let
                [int-match-blockers-before : i64
                  embedded-native-full-blocker-events]
                [int-match-text : String
                  (embedded-native-int-match-body params body-node)]
                (if (not (string.eq int-match-text ""))
                  int-match-text
                  (if (and
                    embedded-native-full-blocker-diagnostic-active
                    (>
                      embedded-native-full-blocker-events
                      int-match-blockers-before))
                    "  0\n"
                    (let
                      [value-match-blockers-before : i64
                        embedded-native-full-blocker-events]
                      [value-match-text : String
                        (embedded-native-value-match-body params body-node)]
                      (if (not (string.eq value-match-text ""))
                        value-match-text
                        (if (and
                          embedded-native-full-blocker-diagnostic-active
                          (>
                            embedded-native-full-blocker-events
                            value-match-blockers-before))
                          "  0\n"
                          (let
                            [data-if-blockers-before : i64
                              embedded-native-full-blocker-events]
                            [data-if-text : String
                              (embedded-native-data-if-body params body-node)]
                            (if (not (string.eq data-if-text ""))
                              data-if-text
                              (if (and
                                embedded-native-full-blocker-diagnostic-active
                                (>
                                  embedded-native-full-blocker-events
                                  data-if-blockers-before))
                                "  0\n"
                                (let
                                  [linear-blockers-before : i64
                                    embedded-native-full-blocker-events]
                                  [linear-text : String
                                    (embedded-native-linear-body-code
                                      params
                                      body-node)]
                                  (if (not (string.eq linear-text ""))
                                    linear-text
                                    (if (and
                                      embedded-native-full-blocker-diagnostic-active
                                      (>
                                        embedded-native-full-blocker-events
                                        linear-blockers-before))
                                      "  0\n"
                                      ;; Computed string matches and string-eq
                                      ;; ifs at body level (the module-generator
                                      ;; dispatch shapes) share the commit final
                                      ;; with template bodies. Refs #5603.
                                      (embedded-native-computed-expr-code
                                        params
                                        body-node
                                        "  (comptime-host-commit-result host session 0 0 0)\n"))))))))))))))))))))

(define (embedded-native-full-report-append!
  [identity : String]
  [status : String]
  [capability : String]) : unit
  (array-set!
    embedded-stdlib-tlci-native-report-full-reasons
    0
    (str_cat.str-cat
      (string.copy
        (& (array-ref embedded-stdlib-tlci-native-report-full-reasons 0)))
      identity
      "\t"
      status
      "\t"
      capability
      "\n")))

;; Revisit the shell, then union in the emitting pass's scalar reason. The union
;; makes the full report a strict superset of the stable default even if a
;; recovery placeholder takes a slightly different diagnostic-only branch.
(define (embedded-native-full-blocker-diagnose!
  [params : (& params compiler_ast_types.AstMacroParamList)]
  [body-node : i64]) : unit
  (let
    [first-reason : String
      (string.copy (& (array-ref embedded-native-fallback-reason 0)))]
    (begin
      (embedded-native-locals-reset!)
      (embedded-native-full-blocker-reset!)
      (set! embedded-native-full-blocker-diagnostic-active true)
      (let
        [_ignored : String (embedded-native-body-code params body-node)]
        (begin
          (when
            (> (string.string-length first-reason) 0)
            (embedded-native-fallback-reason-note! first-reason))
          (set! embedded-native-full-blocker-diagnostic-active false))))))

(define (embedded-native-full-blocker-render! [identity : String]) : unit
  (let
    [blocker-index : i64 0]
    [walked-index : i64 0]
    (begin
      (if (= embedded-native-full-blocker-len 0)
        (embedded-native-full-report-append! identity "blocked" "unreported")
        (while (< blocker-index embedded-native-full-blocker-len)
          (begin
            (embedded-native-full-report-append!
              identity
              "blocked"
              (string.copy
                (& (array-ref embedded-native-full-blockers blocker-index))))
            (set! blocker-index (+ blocker-index 1)))))
      (when
        embedded-native-full-blocker-overflow
        (embedded-native-full-report-append!
          identity
          "blocked"
          "diagnostic-capacity-exceeded"))
      (while (< walked-index embedded-native-full-walked-len)
        (let
          [capability : String
            (string.copy
              (& (array-ref embedded-native-full-walked walked-index)))]
          (begin
            (when
              (not
                (embedded-native-full-string-set-contains?
                  (& embedded-native-full-blockers)
                  embedded-native-full-blocker-len
                  capability))
              (embedded-native-full-report-append! identity "walked" capability))
            (set! walked-index (+ walked-index 1)))))
      (when
        embedded-native-full-walked-overflow
        (embedded-native-full-report-append!
          identity
          "walked"
          "diagnostic-capacity-exceeded")))))

(define (embedded-native-host-externs) : String
  (str_cat.str-cat
    "(extern comptime-host-fuel-check (:symbol \"_tl_comptime_host_fuel-check\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-diagnostic (:symbol \"_tl_comptime_host_diagnostic\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-scratch-alloc (:symbol \"_tl_comptime_host_scratch-alloc\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-scratch-reset (:symbol \"_tl_comptime_host_scratch-reset\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-var (:symbol \"_tl_comptime_host_expr-var\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-module-name (:symbol \"_tl_comptime_host_module-name\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-module-hook (:symbol \"_tl_comptime_host_module-hook\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-module-value? (:symbol \"_tl_comptime_host_module-value?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-module-value-type (:symbol \"_tl_comptime_host_module-value-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-empty (:symbol \"_tl_comptime_host_expr-list-empty\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-cons (:symbol \"_tl_comptime_host_expr-list-cons\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-append (:symbol \"_tl_comptime_host_expr-list-append\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-push-operand (:symbol \"_tl_comptime_host_push-operand\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-call (:symbol \"_tl_comptime_host_expr-call\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-tuple (:symbol \"_tl_comptime_host_expr-tuple\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-array-ref (:symbol \"_tl_comptime_host_expr-array-ref\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-array-push (:symbol \"_tl_comptime_host_expr-array-push\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-make-array (:symbol \"_tl_comptime_host_expr-make-array\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-type-kind-eq (:symbol \"_tl_comptime_host_operand-type-kind-eq\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-type-kind-eq (:symbol \"_tl_comptime_host_operand-expr-type-kind-eq\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-type-key-eq (:symbol \"_tl_comptime_host_operand-type-key-eq\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-type (:symbol \"_tl_comptime_host_expr-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-cast (:symbol \"_tl_comptime_host_expr-cast\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ann (:symbol \"_tl_comptime_host_expr-ann\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-init (:symbol \"_tl_comptime_host_expr-init\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-bool-literal (:symbol \"_tl_comptime_host_expr-bool-literal\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-int-literal (:symbol \"_tl_comptime_host_expr-int-literal\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-string (:symbol \"_tl_comptime_host_expr-string\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-splice (:symbol \"_tl_comptime_host_expr-splice\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-if (:symbol \"_tl_comptime_host_expr-if\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-length (:symbol \"_tl_comptime_host_expr-list-length\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-list-length (:symbol \"_tl_comptime_host_expr-binding-clause-list-length\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-syntax-name-fresh (:symbol \"_tl_comptime_host_syntax-name-fresh\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-begin-unit (:symbol \"_tl_comptime_host_expr-begin-unit\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-nth (:symbol \"_tl_comptime_host_expr-list-nth\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-list-nth (:symbol \"_tl_comptime_host_expr-binding-clause-list-nth\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-name (:symbol \"_tl_comptime_host_expr-binding-clause-name\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-has-type? (:symbol \"_tl_comptime_host_expr-binding-clause-has-type?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-type (:symbol \"_tl_comptime_host_expr-binding-clause-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binding-clause-init (:symbol \"_tl_comptime_host_expr-binding-clause-init\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-begin (:symbol \"_tl_comptime_host_expr-begin\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-binary-op (:symbol \"_tl_comptime_host_expr-binary-op\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-unary-op (:symbol \"_tl_comptime_host_expr-unary-op\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-char-literal (:symbol \"_tl_comptime_host_expr-char-literal\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-unit-literal (:symbol \"_tl_comptime_host_expr-unit-literal\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-set (:symbol \"_tl_comptime_host_local-set\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-get (:symbol \"_tl_comptime_host_local-get\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-var-from-value (:symbol \"_tl_comptime_host_expr-var-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-bracket-clause (:symbol \"_tl_comptime_host_expr-bracket-clause\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-borrow (:symbol \"_tl_comptime_host_expr-borrow\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-key (:symbol \"_tl_comptime_host_type-key\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-struct-field-name (:symbol \"_tl_comptime_host_struct-field-name\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-enum-variant-name (:symbol \"_tl_comptime_host_enum-variant-name\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-struct-field-count (:symbol \"_tl_comptime_host_struct-field-count\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-enum-variant-count (:symbol \"_tl_comptime_host_enum-variant-count\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-enum-variant-payload-count (:symbol \"_tl_comptime_host_enum-variant-payload-count\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-tuple-element-count (:symbol \"_tl_comptime_host_tuple-element-count\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-struct-field-type (:symbol \"_tl_comptime_host_struct-field-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-enum-variant-payload-type (:symbol \"_tl_comptime_host_enum-variant-payload-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-tuple-element-type (:symbol \"_tl_comptime_host_tuple-element-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-string-append (:symbol \"_tl_comptime_host_string-append\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-wildcard (:symbol \"_tl_comptime_host_pattern-wildcard\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-binding (:symbol \"_tl_comptime_host_pattern-binding\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-binding-typed (:symbol \"_tl_comptime_host_pattern-binding-typed\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-variant (:symbol \"_tl_comptime_host_pattern-variant\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-list-empty (:symbol \"_tl_comptime_host_pattern-list-empty\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-list-cons (:symbol \"_tl_comptime_host_pattern-list-cons\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-list-cons-from-values (:symbol \"_tl_comptime_host_pattern-list-cons-from-values\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-list-bindings (:symbol \"_tl_comptime_host_pattern-list-bindings\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-variant-from-value (:symbol \"_tl_comptime_host_pattern-variant-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-match-arm-list-cons-from-values (:symbol \"_tl_comptime_host_match-arm-list-cons-from-values\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-match-arm (:symbol \"_tl_comptime_host_match-arm\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-match-arm-list-empty (:symbol \"_tl_comptime_host_match-arm-list-empty\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-match-arm-list-cons (:symbol \"_tl_comptime_host_match-arm-list-cons\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-match (:symbol \"_tl_comptime_host_expr-match\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-string-value (:symbol \"_tl_comptime_host_string-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-diagnostic-from-value (:symbol \"_tl_comptime_host_diagnostic-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-pattern-var (:symbol \"_tl_comptime_host_pattern-var\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-string-eq (:symbol \"_tl_comptime_host_string-eq\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-tuple-ref (:symbol \"_tl_comptime_host_expr-tuple-ref\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-struct-get (:symbol \"_tl_comptime_host_expr-struct-get\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-struct-get-from-value (:symbol \"_tl_comptime_host_expr-struct-get-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-struct-set-from-value (:symbol \"_tl_comptime_host_expr-struct-set-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-array-set (:symbol \"_tl_comptime_host_expr-array-set\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-struct-set (:symbol \"_tl_comptime_host_expr-struct-set\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-return (:symbol \"_tl_comptime_host_expr-return\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-box (:symbol \"_tl_comptime_host_expr-box\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-box-get (:symbol \"_tl_comptime_host_expr-box-get\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ptr-read (:symbol \"_tl_comptime_host_expr-ptr-read\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ptr-to-int (:symbol \"_tl_comptime_host_expr-ptr-to-int\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-string-data (:symbol \"_tl_comptime_host_expr-string-data\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-array-data (:symbol \"_tl_comptime_host_expr-array-data\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-string-from-bytes (:symbol \"_tl_comptime_host_expr-string-from-bytes\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ptr-write (:symbol \"_tl_comptime_host_expr-ptr-write\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ptr-offset (:symbol \"_tl_comptime_host_expr-ptr-offset\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-unsafe (:symbol \"_tl_comptime_host_expr-unsafe\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-float-literal (:symbol \"_tl_comptime_host_expr-float-literal\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-let-binding (:symbol \"_tl_comptime_host_let-binding\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-let-binding-list-empty (:symbol \"_tl_comptime_host_let-binding-list-empty\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-let-binding-list-cons (:symbol \"_tl_comptime_host_let-binding-list-cons\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-let (:symbol \"_tl_comptime_host_expr-let\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-var (:symbol \"_tl_comptime_host_type-var\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-scalar (:symbol \"_tl_comptime_host_type-scalar\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-array-element-type (:symbol \"_tl_comptime_host_array-element-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-reference-element-type (:symbol \"_tl_comptime_host_reference-element-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-function-param-count (:symbol \"_tl_comptime_host_function-param-count\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-function-return-type (:symbol \"_tl_comptime_host_function-return-type\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-cleanup-owning? (:symbol \"_tl_comptime_host_type-cleanup-owning?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-cleanup-function (:symbol \"_tl_comptime_host_type-cleanup-function\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-array-length (:symbol \"_tl_comptime_host_array-length\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-array-dynamic? (:symbol \"_tl_comptime_host_array-dynamic?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-call? (:symbol \"_tl_comptime_host_operand-expr-call?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-call-callee (:symbol \"_tl_comptime_host_operand-expr-call-callee\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-call-args (:symbol \"_tl_comptime_host_operand-expr-call-args\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-ptr-cast (:symbol \"_tl_comptime_host_expr-ptr-cast\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-ptr (:symbol \"_tl_comptime_host_type-ptr\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-box (:symbol \"_tl_comptime_host_type-box\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-dyn-array (:symbol \"_tl_comptime_host_type-dyn-array\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-array (:symbol \"_tl_comptime_host_type-array\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-slice (:symbol \"_tl_comptime_host_type-slice\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-ref (:symbol \"_tl_comptime_host_type-ref\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-string-value (:symbol \"_tl_comptime_host_operand-expr-string-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-string? (:symbol \"_tl_comptime_host_operand-expr-string?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-int? (:symbol \"_tl_comptime_host_operand-expr-int?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-int-value (:symbol \"_tl_comptime_host_operand-expr-int-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-expr-list-length (:symbol \"_tl_comptime_host_local-expr-list-length\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-expr-list-nth (:symbol \"_tl_comptime_host_local-expr-list-nth\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-expr-string? (:symbol \"_tl_comptime_host_local-expr-string?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-expr-var? (:symbol \"_tl_comptime_host_local-expr-var?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-value-i64 (:symbol \"_tl_comptime_host_value-i64\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-value-unit (:symbol \"_tl_comptime_host_value-unit\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-value-select (:symbol \"_tl_comptime_host_value-select\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-int->string (:symbol \"_tl_comptime_host_int->string\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-var? (:symbol \"_tl_comptime_host_operand-expr-var?\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-operand-expr-var-name (:symbol \"_tl_comptime_host_operand-expr-var-name\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-string-length (:symbol \"_tl_comptime_host_local-string-length\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-string-ref (:symbol \"_tl_comptime_host_local-string-ref\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-local-string-slice (:symbol \"_tl_comptime_host_local-string-slice\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-string-from-value (:symbol \"_tl_comptime_host_expr-string-from-value\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-int-from-data (:symbol \"_tl_comptime_host_expr-int-from-data\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-set-var (:symbol \"_tl_comptime_host_expr-set-var\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-resource-scope (:symbol \"_tl_comptime_host_expr-resource-scope\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-let-scope (:symbol \"_tl_comptime_host_expr-let-scope\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-for-owned (:symbol \"_tl_comptime_host_expr-for-owned\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-not (:symbol \"_tl_comptime_host_expr-not\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-while (:symbol \"_tl_comptime_host_expr-while\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-let-binding-typed (:symbol \"_tl_comptime_host_let-binding-typed\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-type-kind (:symbol \"_tl_comptime_host_type-kind\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-list-fold-if (:symbol \"_tl_comptime_host_expr-list-fold-if\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-expr-clause-list-fold-if (:symbol \"_tl_comptime_host_expr-clause-list-fold-if\") : (-> i64 i64 i64 i64 i64 i64))\n"
    "(extern comptime-host-commit-result (:symbol \"_tl_comptime_host_commit-result\") : (-> i64 i64 i64 i64 i64 i64))\n"))

(define (embedded-native-source
  [names : (__tl_dyn-array String)]
  [captures : (& captures TlciNativeMacroCaptures)]) : String
  (let
    [out : String
      (str_cat.str-cat "(module tlci-entries)\n" (embedded-native-host-externs))]
    [count : i64 (array-length names)]
    [index : i64 0]
    [native-count : i64 0]
    [partial-count : i64 0]
    [interpreted-arms : i64 0]
    [_reasons-reset : unit
      (array-set! embedded-stdlib-tlci-native-report-reasons 0 "")]
    [_full-reasons-reset : unit
      (array-set! embedded-stdlib-tlci-native-report-full-reasons 0 "")]
    (begin
      (while (< index count)
        (let
          [slot : i64
            (tlci-native-macro-capture-slot captures (array-ref names index))]
          [body-text : String
            (if (>= slot 0)
              (begin
                (embedded-native-locals-reset!)
                (embedded-native-fallback-reason-reset!)
                (embedded-native-body-code
                  (&
                    (struct-get
                      (array-ref (struct-get captures slots) slot)
                      params))
                  (struct-get (array-ref (struct-get captures slots) slot) body)))
              "")]
          (begin
            (set!
              out
              (str_cat.str-cat
                out
                "(define (macro-entry-"
                (string.int->string index)
                " [image-ctx : i64] [host : i64] [session : i64]"
                " [operands : i64] [count : i64] [result : i64]) : i64\n"))
            (if (string.eq body-text "")
              (begin
                (array-set!
                  embedded-stdlib-tlci-native-report-reasons
                  0
                  (str_cat.str-cat
                    (string.copy
                      (&
                        (array-ref embedded-stdlib-tlci-native-report-reasons 0)))
                    (array-ref names index)
                    "\t"
                    (if (=
                      (string.string-length
                        (& (array-ref embedded-native-fallback-reason 0)))
                      0)
                      "unreported"
                      (string.copy
                        (& (array-ref embedded-native-fallback-reason 0))))
                    "\n"))
                (when
                  embedded-native-full-blocker-report-enabled
                  (begin
                    (if (>= slot 0)
                      (embedded-native-full-blocker-diagnose!
                        (&
                          (struct-get
                            (array-ref (struct-get captures slots) slot)
                            params))
                        (struct-get
                          (array-ref (struct-get captures slots) slot)
                          body))
                      (embedded-native-full-blocker-reset!))
                    (embedded-native-full-blocker-render!
                      (array-ref names index))))
                (set!
                  out
                  (str_cat.str-cat
                    out
                    "  (if (= count -"
                    (string.int->string (+ index 2))
                    ") 1 0))\n")))
              (let
                [arm-sites : i64
                  (embedded-native-count-occurrences
                    body-text
                    (string.copy (& embedded-native-interpreted-arm-marker)))]
                (begin
                  (set! native-count (+ native-count 1))
                  (set! interpreted-arms (+ interpreted-arms arm-sites))
                  (when
                    (> arm-sites 0)
                    (set! partial-count (+ partial-count 1)))
                  (set!
                    out
                    (str_cat.str-cat
                      out
                      (embedded-native-fuel-open)
                      body-text
                      ")))\n")))))
            (set! index (+ index 1)))))
      (array-set! embedded-stdlib-tlci-native-report-count 0 native-count)
      (array-set!
        embedded-stdlib-tlci-native-report-partial-count
        0
        partial-count)
      (array-set!
        embedded-stdlib-tlci-native-report-interpreted-arms
        0
        interpreted-arms)
      out)))

(define (embedded-native-entry-offsets
  [image : cobj.CompilerObjectImage]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (array.make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [offset : i64
            (compiler_tlci_native_image.compiler-tlci-native-entry-offset
              image
              (str_cat.str-cat "_tl_f" (string.int->string index)))]
          (if (< offset 0)
            (set! ok false)
            (begin
              (array-set! out index offset)
              (set! index (+ index 1))))))
      (if ok
        out
        (array.make-array i64 0)))))

;; Compile the generated transformer program and assemble the native package
;; image. Identities without captured sources become interpreted-fallback
;; shells, so a caller with no captures gets a pure registration image.
(define (embedded-native-emit-package
  [metadata-text : String]
  [build-hash : String]
  [windows-target : bool]
  [rodata : (__tl_dyn-array u8)]
  [names : (__tl_dyn-array String)]
  [captures : (& captures TlciNativeMacroCaptures)]) : ResultProducerBytes
  (let
    [source : String (embedded-native-source names captures)]
    [target : compiler_backend.CompilerBackendTarget
      (if windows-target
        (compiler_backend.CompilerBackendTarget.Windows)
        (compiler_backend.CompilerBackendTarget.Linux))]
    (match (compiler_backend.compiler-backend-lower-source-for-target-in-session
      source
      target)
      [(ResultCompilerLower.Err diag)
        (ResultProducerBytes.Err
          (str_cat.str-cat
            "generated source rejected: "
            (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]
      [(ResultCompilerLower.Ok program spans)
        (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-and-crt
          program
          target
          (compiler_backend.CompilerBackendMode.Scalar)
          spans
          false
          false)
          [(compiler_backend.ResultCompilerBackendObject.Err diag)
            (ResultProducerBytes.Err
              (str_cat.str-cat
                "object emission failed: "
                (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]
          [(compiler_backend.ResultCompilerBackendObject.Ok image)
            (match (compiler_tlci_native_image.compiler-tlci-native-layout-image
              image)
              [(compiler_tlci_native_image.ResultCompilerTlciNativeLayout.Err
                  message)
                (ResultProducerBytes.Err message)]
              [(compiler_tlci_native_image.ResultCompilerTlciNativeLayout.Ok
                  layout)
                (let
                  [entry-offsets : (__tl_dyn-array i64)
                    (embedded-native-entry-offsets image (array-length names))]
                  (if (not
                    (= (array-length entry-offsets) (array-length names)))
                    (ResultProducerBytes.Err
                      "entry count does not match catalog")
                    (match (compiler_tlci_native_image.compiler-tlci-native-emit-imports
                      (& layout))
                      [(compiler_tlci_native_image.ResultCompilerTlciNativeImports.Err
                          message)
                        (ResultProducerBytes.Err message)]
                      [(compiler_tlci_native_image.ResultCompilerTlciNativeImports.Ok
                          imports)
                        (match (compiler_tlci_native_image.compiler-tlci-native-package
                          metadata-text
                          build-hash
                          rodata
                          (struct-get layout bytes)
                          imports
                          (struct-get layout fixup-offsets)
                          (struct-get layout fixup-count)
                          names
                          entry-offsets
                          (array-length names))
                          [(compiler_tlci_native_image.ResultCompilerTlciNativeBytes.Err
                              message)
                            (ResultProducerBytes.Err message)]
                          [(compiler_tlci_native_image.ResultCompilerTlciNativeBytes.Ok
                              bytes)
                            (ResultProducerBytes.Ok bytes)])])))])])])))