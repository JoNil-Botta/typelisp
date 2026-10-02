;; format_tests.tl - White-box tests for the formatter: token and CST shape,
;; rule rendering fixtures, and the fmt CLI error paths.
(import compiler_owned_view as owned_view)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as fmt_svec)
(import format_tokens as tokens)
(import format_rules)
(import format_cli_core as fcli)
(import format_cst as cst)
(import format_rules as rules)
(import stdlib.result)
(import (result.result i64 tokens.FormatSourceError) as result_fmt_i64)

(test
  fmt-write-failure-diagnostic-includes-path-and-reason
  (match (fcli.fmt-try-write-formatted-file "" "(define x 1)\n")
    [(fcli.ResultFmtWrite.Ok) (io.panic "fmt write unexpectedly succeeded")]
    [(fcli.ResultFmtWrite.Err message)
      (if (string.eq message "fmt: failed to write : io: invalid path: ")
        unit
        (io.panic (string.copy message)))]))

(test
  fmt-parse-diagnostic-includes-path-line-and-column
  (match (format_rules.format-rules-render-source-width-result
    "(define x\n  ]"
    80)
    [(format_rules.ResultFormatString.Ok _)
      (io.panic "fmt parse unexpectedly succeeded")]
    [(format_rules.ResultFormatString.Err err)
      (let
        [message : String (fcli.fmt-source-error-message "bad.tl" err)]
        (if (string.eq
          message
          "bad.tl:2:3: format cst: unexpected closing delimiter")
          unit
          (io.panic message)))]))

(define (fmt-malformed-int-error? [source : String]) : bool
  (match (format_rules.format-rules-render-source-width-result source 80)
    [(format_rules.ResultFormatString.Ok _) false]
    [(format_rules.ResultFormatString.Err err)
      (string.eq
        (tokens.format-source-error-message err)
        "format lexer: malformed integer literal")]))

(test
  fmt-number-literal-diagnostics-preserved
  (if (and
    (fmt-malformed-int-error? "(define x 0x)")
    (fmt-malformed-int-error? "(define x 0xg)")
    (fmt-malformed-int-error? "(define x 0b)")
    (fmt-malformed-int-error? "(define x 0b2)"))
    unit
    (io.panic "fmt number literal diagnostics changed")))

(define (fmt-or-pattern-source) : String
  "(define (classify [op : Op]) : i64 (match op [(or (Load dst) (Store dst)) dst] [(or (Alpha first-value) (Beta first-value)) (+ first-value (compute first-value))] [(or (Alpha-instruction dst _ _) (Beta-instruction dst _) (Gamma-instruction dst) (Delta-instruction dst _ _ _) (Epsilon-instruction dst)) dst] [(or (Alpha-instruction dst _ _)
;; a comment between alternatives
(Beta-instruction dst _) (Gamma-instruction dst)) dst] [_ (if (or (long-condition-name-one op) (long-condition-name-two op) (long-condition-name-three op)) 1 0)]))")

;; An `(or ...)` match pattern that fits stays on its line; one that does not
;; packs as many alternatives per line as fit, aligned under the first, and a
;; comment keeps its own line. A boolean `(or ...)` expression is unchanged.
(define (fmt-or-pattern-expected) : String
  "(define (classify [op : Op]) : i64
  (match op
    [(or (Load dst) (Store dst)) dst]
    [(or (Alpha first-value) (Beta first-value))
      (+ first-value (compute first-value))]
    [(or (Alpha-instruction dst _ _) (Beta-instruction dst _)
         (Gamma-instruction dst) (Delta-instruction dst _ _ _)
         (Epsilon-instruction dst))
      dst]
    [(or (Alpha-instruction dst _ _)
         ;; a comment between alternatives
         (Beta-instruction dst _) (Gamma-instruction dst))
      dst]
    [_
      (if (or
        (long-condition-name-one op)
        (long-condition-name-two op)
        (long-condition-name-three op))
        1
        0)]))")

(test
  fmt-or-pattern-fills-alternatives
  (let
    [formatted : String
      (format-rules-render-source-width (fmt-or-pattern-source) 80)]
    [fixpoint : String
      (format-rules-render-source-width
        (owned_view.compiler-owned-shared-view formatted)
        80)]
    (begin
      (unless
        (string.eq formatted (fmt-or-pattern-expected))
        (io.panic formatted))
      (unless
        (string.eq fixpoint formatted)
        (io.panic "fmt or-pattern fill is not a fixpoint")))))

(define (fmt-list-count [items : cst.FormatCstList]) : i64
  items.len)

(define (fmt-cst-count [node : cst.FormatCst]) : i64
  (match node
    [(cst.FormatCst.Atom _) 1]
    [(cst.FormatCst.Comment _) 1]
    [(cst.FormatCst.Prefix _ child) (+ 1 (fmt-cst-count (deref child)))]
    [(cst.FormatCst.Projection child _) (+ 1 (fmt-cst-count (deref child)))]
    [(cst.FormatCst.List items) (+ 1 (fmt-cst-list-total (deref items)))]
    [(cst.FormatCst.BracketList items) (+ 1 (fmt-cst-list-total (deref items)))]
    [(cst.FormatCst.Forms items) (+ 1 (fmt-cst-list-total (deref items)))]))

(define (fmt-cst-list-total [items : cst.FormatCstList]) : i64
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) 0]
    [(cst.FormatCstListStep.Item node rest)
      (+ (fmt-cst-count node) (fmt-cst-list-total rest))]))

(define (fmt-cst-comment-count [node : cst.FormatCst]) : i64
  (match node
    [(cst.FormatCst.Atom _) 0]
    [(cst.FormatCst.Comment _) 1]
    [(cst.FormatCst.Prefix _ child) (fmt-cst-comment-count (deref child))]
    [(cst.FormatCst.Projection child _) (fmt-cst-comment-count (deref child))]
    [(cst.FormatCst.List items) (fmt-cst-list-comment-count (deref items))]
    [(cst.FormatCst.BracketList items)
      (fmt-cst-list-comment-count (deref items))]
    [(cst.FormatCst.Forms items) (fmt-cst-list-comment-count (deref items))]))

(define (fmt-cst-list-comment-count [items : cst.FormatCstList]) : i64
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) 0]
    [(cst.FormatCstListStep.Item node rest)
      (+ (fmt-cst-comment-count node) (fmt-cst-list-comment-count rest))]))

(define (fmt-cst-bracket-count [node : cst.FormatCst]) : i64
  (match node
    [(cst.FormatCst.Atom _) 0]
    [(cst.FormatCst.Comment _) 0]
    [(cst.FormatCst.Prefix _ child) (fmt-cst-bracket-count (deref child))]
    [(cst.FormatCst.Projection child _) (fmt-cst-bracket-count (deref child))]
    [(cst.FormatCst.List items) (fmt-cst-list-bracket-count (deref items))]
    [(cst.FormatCst.BracketList items)
      (+ 1 (fmt-cst-list-bracket-count (deref items)))]
    [(cst.FormatCst.Forms items) (fmt-cst-list-bracket-count (deref items))]))

(define (fmt-cst-list-bracket-count [items : cst.FormatCstList]) : i64
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) 0]
    [(cst.FormatCstListStep.Item node rest)
      (+ (fmt-cst-bracket-count node) (fmt-cst-list-bracket-count rest))]))

(define (parse-format-source [src : String]) : cst.FormatCst
  (match (cst.parse-format-source-result src)
    [(cst.ResultFormatCst.Ok tree) tree]
    [(cst.ResultFormatCst.Err err)
      (io.panic (tokens.format-source-error-message err))]))

(define (format-cst-fixture) : String
  "(import std)
; header comment
(extern (io.emit [arg0 : i64]) : unit)
(defenum Maybe (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define (main [xs : (__tl_dyn-array i64)] [p : Point]) : i64
  (let
    [n : i64 (array-ref xs 0)]
    [c : char ' ']
    (match (Some n)
      [(Some v) (+ v (cast c : i64))]
      [None 0])))")

(define (format-cst-boxed-nested-ok?) : bool
  (let
    [tree : cst.FormatCst (parse-format-source "'(outer [x ; inner\n y] ,z)")]
    (and
      (= (fmt-cst-comment-count (owned_view.compiler-owned-shared-view tree)) 1)
      (> (fmt-cst-bracket-count (owned_view.compiler-owned-shared-view tree)) 0)
      (> (fmt-cst-count tree) 8))))

(define (format-cst-prefixed-int-ok?) : bool
  (let
    [stream : tokens.FormatTokenStream (format-lex "(0x2a -0b101010)")]
    (and
      (= (format-token-tag-count stream (tokens.fmt-tag-int)) 2)
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 1))
        (tokens.fmt-tag-int))
      (string.eq
        (tokens.format-token-text (tokens.format-token-at stream 1))
        "0x2a")
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 2))
        (tokens.fmt-tag-int))
      (string.eq
        (tokens.format-token-text (tokens.format-token-at stream 2))
        "-0b101010")
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 4))
        (tokens.fmt-tag-end)))))

(define (format-cst-apostrophe-char-ok?) : bool
  (let
    [stream : tokens.FormatTokenStream (format-lex "'a' '\"' '('")]
    (and
      (= (format-token-tag-count stream (tokens.fmt-tag-char)) 3)
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 3))
        (tokens.fmt-tag-end)))))

(define (format-cst-error-location-ok?) : bool
  (match (cst.parse-format-source-result "(define x\n  ]")
    [(cst.ResultFormatCst.Ok _) false]
    [(cst.ResultFormatCst.Err err)
      (and
        (string.eq
          (tokens.format-source-error-message
            (owned_view.compiler-owned-shared-view err))
          "format cst: unexpected closing delimiter")
        (format-source-span-eq? (tokens.format-source-error-span err) 2 3 2 3))]))

(define (format-cst-legacy-char-rejected-ok?) : bool
  (and
    (match (cst.parse-format-source-result "#x'")
      [(cst.ResultFormatCst.Ok _) false]
      [(cst.ResultFormatCst.Err err)
        (string.eq
          (tokens.format-source-error-message err)
          "format lexer: unexpected character")])
    (match (cst.parse-format-source-result "#\\space'")
      [(cst.ResultFormatCst.Ok _) false]
      [(cst.ResultFormatCst.Err err)
        (string.eq
          (tokens.format-source-error-message err)
          "format lexer: unexpected character")])))

(define (format-cst-dense-storage-ok?) : bool
  (match (parse-format-source "(a b c)")
    [(cst.FormatCst.Forms forms)
      (and
        (= (fmt-list-count (owned_view.compiler-owned-box-shared-view forms)) 1)
        (match (cst.fmt-cst-list-step (deref forms))
          [(cst.FormatCstListStep.Item node _)
            (match node
              [(cst.FormatCst.List items) (= (fmt-list-count (deref items)) 3)]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (format-cst-self-test) : i64
  (let
    [stream : tokens.FormatTokenStream (format-lex (format-cst-fixture))]
    [tree : cst.FormatCst (parse-format-source (format-cst-fixture))]
    (begin
      (unless (> (tokens.format-token-count stream) 40) (return 1))
      (unless
        (> (fmt-cst-count (owned_view.compiler-owned-shared-view tree)) 40)
        (return 2))
      (unless
        (=
          (fmt-cst-comment-count (owned_view.compiler-owned-shared-view tree))
          1)
        (return 3))
      (unless (> (fmt-cst-bracket-count tree) 4) (return 4))
      (unless
        (= (format-token-tag-count stream (tokens.fmt-tag-char)) 1)
        (return 5))
      (unless (format-cst-boxed-nested-ok?) (return 6))
      (unless (format-cst-prefixed-int-ok?) (return 7))
      (unless (format-cst-apostrophe-char-ok?) (return 8))
      (unless (format-cst-error-location-ok?) (return 9))
      (unless (format-cst-legacy-char-rejected-ok?) (return 10))
      (unless (format-cst-dense-storage-ok?) (return 11))
      42)))

(define (format-rules-render-width [node : cst.FormatCst] [width : i64]) : String
  (rules.format-rules-render-cst-width node width))

(define (format-rules-render-source-width [src : String] [width : i64]) : String
  (match (rules.format-rules-render-source-width-result src width)
    [(rules.ResultFormatString.Ok formatted) formatted]
    [(rules.ResultFormatString.Err err)
      (io.panic (tokens.format-source-error-message err))]))

(define (format-rules-decls-expected) : String
  "(import std)\n(import ffi)\n\n(extern (io.emit-string [arg0 : String]) : unit (:abi c) (:symbol \"external_emit_string\"))\n(extern (print-int [arg0 : i64]) : unit)\n\n(defenum Maybe\n  (Some i64)\n  (None))\n\n(defstruct Point\n  (x i64)\n  (y i64))\n\n(define KEY_A : i64\n  1)\n(define KEY_B : i64\n  2)")

(define (format-rules-flow-expected) : String
  "(define (main [x : i64]) : i64\n  (begin\n    (let\n      [y : i64 1]\n      (if (< x y)\n        (while (< x 10)\n          (set! x (+ x 1)))\n        x))\n    (match (Some x)\n      [(Some v) v]\n      [None 0])))")

(define (format-rules-empty-let-expected) : String
  "(define (main) : i64
  (let
    []
    1
    2))")

(define (format-rules-comments-expected) : String
  ";; module header
;; keeps adjacent lines
(import std)

;; item docs
;; stay attached
(define answer : i64
  42)

(begin
  ; keep
  (io.emit-string \"x\"))")

(define (format-rules-quote-expected) : String
  "(define (mk [e : Expr]) : Expr
  `(if ,e
    true
    false))

(define (body [xs : ExprList]) : Expr
  `(begin
    ,@xs))")

(define (format-rules-unsafe-expected) : String
  "(define (main [p : (Ptr i64)]) : i64
  (unsafe
    (ptr-read p)))

(unsafe
  (define (danger [x : i64]) : i64
    x))")

(define (format-rules-define-metadata-expected) : String
  "(define (probe-fn [x : i64])
  (:export-symbol \"probe_sym\") : unit
  unit)")

(define (format-rules-define-metadata-long-expected) : String
  "(define (probe-long [x : i64])
  (:export-symbol \"probe_long\")
  : (Tuple i64 i64 i64 i64 i64 i64 i64 i64)
  unit)")

(define (format-rules-spmd-callable-expected) : String
  "(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0)))
  : i64
  (+ x scale))")

(define (format-rules-variadic-macro-expected) : String
  "(defmacro (all [first : bool] [rest : bool ...]) : bool
  first)")

(define (format-rules-projection-suffix-expected) : String
  "(define (main) : i64
  (begin
    (array-ref items 0).value
    (tuple-ref items 0).value
    (deref item).inner.value))")

(define (format-rules-offset-slice-preserved?) : bool
  (let
    [head : cst.FormatCst (cst.FormatCst.Atom (tokens.FormatToken.Symbol "x"))]
    [colon : cst.FormatCst (cst.FormatCst.Atom (tokens.FormatToken.Colon))]
    [typ : cst.FormatCst (cst.FormatCst.Atom (tokens.FormatToken.Symbol "i64"))]
    [dense-slots : (__tl_dyn-array cst.FormatCst)
      (__tl_make-array cst.FormatCst 3)]
    [offset-slots : (__tl_dyn-array cst.FormatCst)
      (__tl_make-array cst.FormatCst 5)]
    (begin
      (set! (array-ref dense-slots 0) head)
      (set! (array-ref dense-slots 1) colon)
      (set! (array-ref dense-slots 2) typ)
      (set! (array-ref offset-slots 1) head)
      (set! (array-ref offset-slots 2) colon)
      (set! (array-ref offset-slots 3) typ)
      (let
        [dense-render : String
          (format-rules-render-width
            (cst.FormatCst.List (box (cst.FormatCstList dense-slots 0 3)))
            80)]
        [offset-render : String
          (format-rules-render-width
            (cst.FormatCst.List (box (cst.FormatCstList offset-slots 1 3)))
            80)]
        (and
          (string.eq dense-render "(x : i64)")
          (string.eq offset-render dense-render))))))

(define (format-rules-self-test) : i64
  (let
    [decls : String
      (format-rules-render-source-width
        "(import std) (import ffi) (extern (io.emit-string [arg0 : String]) : unit (:abi c) (:symbol \"external_emit_string\")) (extern (print-int [arg0 : i64]) : unit) (defenum Maybe (Some i64) (None)) (defstruct Point (x i64) (y i64)) (define KEY_A : i64 1) (define KEY_B : i64 2)"
        80)]
    [flow : String
      (format-rules-render-source-width
        "(define (main [x : i64]) : i64 (begin (let ([y : i64 1]) (if (< x y) (while (< x 10) (set! x (+ x 1))) x)) (match (Some x) [(Some v) v] [None 0])))"
        80)]
    [flow-fixpoint : String
      (format-rules-render-source-width
        (owned_view.compiler-owned-shared-view flow)
        80)]
    [empty-let : String
      (format-rules-render-source-width "(define (main) : i64 (let () 1 2))" 80)]
    [empty-let-fixpoint : String
      (format-rules-render-source-width
        (owned_view.compiler-owned-shared-view empty-let)
        80)]
    [comments : String
      (format-rules-render-source-width
        ";; module header
;; keeps adjacent lines
(import std)
;; item docs
;; stay attached
(define answer : i64 42)
(begin ; keep
 (io.emit-string \"x\"))"
        80)]
    [quote : String
      (format-rules-render-source-width
        "(define (mk [e : Expr]) : Expr `(if ,e true false)) (define (body [xs : ExprList]) : Expr `(begin ,@xs))"
        80)]
    [unsafe : String
      (format-rules-render-source-width
        "(define (main [p : (Ptr i64)]) : i64 (unsafe (ptr-read p))) (unsafe (define (danger [x : i64]) : i64 x))"
        80)]
    [metadata : String
      (format-rules-render-source-width
        "(define (probe-fn [x : i64]) (:export-symbol \"probe_sym\") : unit unit)"
        80)]
    [metadata-long : String
      (format-rules-render-source-width
        "(define (probe-long [x : i64]) (:export-symbol \"probe_long\") : (Tuple i64 i64 i64 i64 i64 i64 i64 i64) unit)"
        48)]
    [spmd-callable : String
      (format-rules-render-source-width
        "(define (helper [x : i64] [scale : i64]) (:spmd-callable (specialization (lanes 8) (args varying uniform) (result varying) (index-param 0))) : i64 (+ x scale))"
        80)]
    [variadic : String
      (format-rules-render-source-width
        "(defmacro (all [first : bool] [rest : bool ...]) : bool first)"
        80)]
    [projection-suffix : String
      (format-rules-render-source-width
        "(define (main) : i64 (begin (array-ref items 0).value (tuple-ref items 0).value (deref item).inner.value))"
        80)]
    (begin
      (unless (string.eq decls (format-rules-decls-expected)) (return 1))
      (unless (string.eq flow (format-rules-flow-expected)) (return 2))
      (unless (string.eq flow-fixpoint flow) (return 11))
      (unless
        (string.eq empty-let (format-rules-empty-let-expected))
        (return 12))
      (unless (string.eq empty-let-fixpoint empty-let) (return 13))
      (unless (string.eq comments (format-rules-comments-expected)) (return 3))
      (unless (string.eq quote (format-rules-quote-expected)) (return 4))
      (unless (string.eq unsafe (format-rules-unsafe-expected)) (return 5))
      (unless
        (string.eq metadata (format-rules-define-metadata-expected))
        (return 6))
      (unless
        (string.eq metadata-long (format-rules-define-metadata-long-expected))
        (return 7))
      (unless
        (string.eq spmd-callable (format-rules-spmd-callable-expected))
        (return 8))
      (unless
        (string.eq variadic (format-rules-variadic-macro-expected))
        (return 9))
      (unless
        (string.eq projection-suffix (format-rules-projection-suffix-expected))
        (return 14))
      (unless (format-rules-offset-slice-preserved?) (return 10))
      42)))

(define (format-source-span-eq?
  [span : tokens.FormatSourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= span.start-line start-line)
    (= span.start-col start-col)
    (= span.end-line end-line)
    (= span.end-col end-col)))

(define (format-token-tag-count
  [stream : (& stream tokens.FormatTokenStream)]
  [wanted : i64]) : i64
  (let
    [i : i64 0]
    [hits : i64 0]
    (begin
      (while (< i stream.count)
        (begin
          (if (=
            (tokens.format-token-tag (tokens.format-token-at stream i))
            wanted)
            (set! hits (+ hits 1))
            (set! hits hits))
          (set! i (+ i 1))))
      hits)))

(define (format-lex [src : String]) : tokens.FormatTokenStream
  (match (tokens.format-lex-result src)
    [(tokens.ResultFormatTokenStream.Ok stream) stream]
    [(tokens.ResultFormatTokenStream.Err err)
      (io.panic (tokens.format-source-error-message err))]))