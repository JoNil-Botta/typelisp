;; reader_tests.tl - White-box tests for the reader (read.tl), the lexer
;; (lex.tl) and token spans (token.tl).
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import lex as lexer)
(import token)
(import read as reader)
(import stdlib.result)
(import (result.result i64 String) as result_lex_i64)

;; A pool grow preserves its source rows, so aggregate relocation must use an
;; explicit shared view instead of consuming an element through ordinary
;; by-value indexing. Exercise a String-bearing row across the exact capacity
;; boundary as well as the scalar fields.
(define (sp-node-pool-growth-preserves-string?) : bool
  (reader.sp-node-pool-reset!)
  (if (< (reader.sp-node-pool-capacity) 1)
    (reader.sp-node-pool-grow!)
    unit)
  (let
    [span : token.SourceSpan (token.SourceSpan 1 1 1 1)]
    [old-cap : i64 (reader.sp-node-pool-capacity)]
    [i : i64 0]
    (while (<= i old-cap)
      (reader.sp-node-push (Int i "__tl_pool_growth_marker" span))
      (set! i (+ i 1)))
    (let
      [grew : bool (> (reader.sp-node-pool-capacity) old-cap)]
      [first-ok : bool
        (match (reader.sp-node-get 0)
          [(Int value text _)
            (and (= value 0) (string.eq text "__tl_pool_growth_marker"))]
          [_ false])]
      [boundary-ok : bool
        (match (reader.sp-node-get old-cap)
          [(Int value text _)
            (and (= value old-cap) (string.eq text "__tl_pool_growth_marker"))]
          [_ false])]
      (reader.sp-node-pool-reset!)
      (and grew first-ok boundary-ok))))

(define (sp-node-pool-arena-ownership-self-test) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (in-arena scratch (reader.sp-node-pool-grow!) (reader.sp-builder-grow!))
    (arena.destroy-safe! scratch)
    (reader.sp-node-pool-reset!)
    (let
      [growth-ok : bool (sp-node-pool-growth-preserves-string?)]
      [span : token.SourceSpan (token.SourceSpan 1 1 1 1)]
      [sp-list : reader.SpannedSexpr
        (reader.spanned-sexpr-list1
          (Sym (ci.intern-syntax-id-from-raw 7) span)
          span)]
      [sp-count-before-transfer : i64 (reader.sp-node-pool-len)]
      [sp-arena-before-transfer : i64 reader.sp-node-pool-base-arena]
      [_compact-retained-origins : unit (reader.sp-node-pool-compact-retained!)]
      [retained-transfer-ok : bool
        (and
          (> sp-count-before-transfer 0)
          (= (reader.sp-node-pool-len) sp-count-before-transfer)
          (=
            (reader.sp-node-pool-capacity)
            (*
              (/
                (+ sp-count-before-transfer (- reader.sp-node-segment-rows 1))
                reader.sp-node-segment-rows)
              reader.sp-node-segment-rows))
          (= (array-length reader.sp-builder-slots) 0)
          (!= reader.sp-node-pool-base-arena 0)
          (!= reader.sp-node-pool-base-arena sp-arena-before-transfer))]
      (match sp-list
        [(List sp-start sp-length sp-span)
          (if (and
            (= sp-start 0)
            (= sp-length 1)
            (= sp-span.start-line 1)
            growth-ok
            retained-transfer-ok)
            (match (reader.sp-node-get sp-start)
              [(Sym sp-value _)
                (if (= (ci.intern-syntax-id-value sp-value) 7)
                  42
                  1)]
              [_ 1])
            1)]
        [_ 2]))))

(define (symbol-id-preservation-ok?) : bool
  (match (lexer.spanned-result "(alpha alpha)")
    [(Ok toks)
      (let
        [first-id : ci.InternId
          (token.sym-id (token.spanned-token-token-ref (& (array-ref toks 1))))]
        [second-id : ci.InternId
          (token.sym-id (token.spanned-token-token-ref (& (array-ref toks 2))))]
        [pool-len-before : i64 (ci.intern-pool-len)]
        (reader.sp-node-pool-reset!)
        (match (reader.spanned-result toks)
          [(Ok form)
            (and
              (= pool-len-before (ci.intern-pool-len))
              (ci.intern-id-eq? first-id second-id)
              (match (reader.spanned-sexpr-view form)
                [(Cons first tail _)
                  (match first
                    [(Sym first-text _)
                      (match (reader.spanned-sexpr-view tail)
                        [(Cons second _ _)
                          (match second
                            [(Sym second-text _)
                              (and
                                (=
                                  (reader.symbol-id first-text)
                                  (ci.intern-id-value first-id))
                                (=
                                  (reader.symbol-id second-text)
                                  (ci.intern-id-value second-id)))]
                            [_ false])]
                        [_ false])]
                    [_ false])]
                [_ false]))]
          [(Err _) false]))]
    [(Err _) false]))

(define (reader-test-symbol? [form : reader.SpannedSexpr] [expected : String]) : bool
  (match (reader.sexpr-view form)
    [(Sym name-id)
      (string.eq (reader.symbol-text-for-syntax-id name-id) expected)]
    [_ false]))

(define (reader-test-projection-suffix-cursor?
  [source : String]
  [expected-cursor : i64]) : bool
  (match (lexer.spanned-result source)
    [(Err _) false]
    [(Ok toks)
      (let
        [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (reader.sp-node-pool-reset!)
        (set! (array-ref cur 0) 0)
        (match (reader.form-spanned-result (& toks) (&mut cur))
          [(Err _) false]
          [(Ok _) (= (array-ref cur 0) expected-cursor)]))]))

(define (reader-test-data-error? [source : String] [expected : String]) : bool
  (match (reader.data-result source)
    [(Ok _) false]
    [(Err message) (string.eq message expected)]))

;; `data-result` keeps the plain data reader's texts, and reads an adjacent
;; `.name` after a list as a separate symbol.
(define (reader-test-data-mode?) : bool
  (let
    [errors-ok : bool
      (and
        (reader-test-data-error?
          "(alpha"
          "reader: unterminated list (missing ')')")
        (reader-test-data-error?
          "[alpha"
          "reader: unterminated list (missing ']')")
        (reader-test-data-error? "(alpha]" "reader: unexpected ']'")
        (reader-test-data-error? ")" "reader: unexpected ')'")
        (reader-test-data-error? "" "reader: unexpected end of input"))]
    [suffix-ok : bool
      (match (reader.data-result "((alpha).beta)")
        [(Err _) false]
        [(Ok form)
          (match (reader.sexpr-view form)
            [(Cons inner tail)
              (and
                (match (reader.sexpr-view inner)
                  [(Cons alpha _) (reader-test-symbol? alpha "alpha")]
                  [_ false])
                (match (reader.sexpr-view tail)
                  [(Cons beta _) (reader-test-symbol? beta ".beta")]
                  [_ false]))]
            [_ false])])]
    (reader.sp-node-pool-reset!)
    (and errors-ok suffix-ok (not reader.sp-reader-data-mode?))))

(test
  reader-traversal-ids-typed-and-preserved
  (if (let
    [source : ci.InternId (ci.intern-source-slice-id "reader-view-name" 0 16)]
    [text : ci.InternId (ci.intern-source-slice-id "reader-view-string" 0 18)]
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity
            session
            7
            (ci.intern-id-value source))))]
    [span : token.SourceSpan (token.source-span-new 2 3 2 7)]
    (and
      (match (reader.sexpr-view (Sym structural span))
        [(Sym found)
          (and
            (ci.intern-syntax-id-eq? found structural)
            (string.eq
              (ci.intern-source-name-session-handle-str
                (cis.intern-structural-session-handle-source-names session)
                (cis.intern-structural-session-syntax-source-name-id-or
                  session
                  (ci.intern-syntax-id-value found)
                  -1))
              "reader-view-name"))]
        [_ false])
      (match (reader.sexpr-view (Str text span))
        [(Str found) (ci.intern-id-eq? found text)]
        [_ false])
      (match (reader.spanned-sexpr-view (Sym structural span))
        [(Sym found found-span)
          (and
            (ci.intern-syntax-id-eq? found structural)
            (= (token.span-start-line found-span) 2)
            (= (token.span-start-col found-span) 3))]
        [_ false])
      (match (reader.spanned-sexpr-view (Str text span))
        [(Str found _) (ci.intern-id-eq? found text)]
        [_ false])))
    unit
    (io.panic "reader: typed traversal identity self-test failed")))

(test
  reader-dense-child-ranges
  (if (and
    (match (begin
      (reader.sp-node-pool-reset!)
      (reader.data-result "(alpha (beta gamma) [])"))
      [(Err _) false]
      [(Ok form)
        (and
          (= (reader.sp-node-pool-len) 5)
          (match (unsafe
            (ptr-read (ptr-addr-of form)))
            [(List start length _)
              (and
                (= start 2)
                (= length 3)
                (match (reader.sexpr-view form)
                  [(Cons first tail1)
                    (and
                      (reader-test-symbol? first "alpha")
                      (match (reader.sexpr-view tail1)
                        [(Cons nested tail2)
                          (and
                            (match (reader.sexpr-view nested)
                              [(Cons beta nested-tail)
                                (and
                                  (reader-test-symbol? beta "beta")
                                  (match (reader.sexpr-view nested-tail)
                                    [(Cons gamma nested-end)
                                      (and
                                        (reader-test-symbol? gamma "gamma")
                                        (match (reader.sexpr-view nested-end)
                                          [(Nil) true]
                                          [_ false]))]
                                    [_ false]))]
                              [_ false])
                            (match (reader.sexpr-view tail2)
                              [(Cons empty tail3)
                                (and
                                  (match (reader.sexpr-view empty)
                                    [(Nil) true]
                                    [_ false])
                                  (match (reader.sexpr-view tail3)
                                    [(Nil) true]
                                    [_ false]))]
                              [_ false]))]
                        [_ false]))]
                  [_ false]))]
            [_ false]))])
    (begin
      (reader.sp-node-pool-reset!)
      (match (lexer.spanned-result "[alpha (beta gamma)]")
        [(Err _) false]
        [(Ok toks)
          (match (reader.spanned-result toks)
            [(Err _) false]
            [(Ok form)
              (and
                (= (reader.sp-node-pool-len) 4)
                (match (unsafe
                  (ptr-read (ptr-addr-of form)))
                  [(BracketList start length span)
                    (and
                      (= start 2)
                      (= length 2)
                      (= (token.span-start-line span) 1)
                      (= (token.span-start-col span) 1)
                      (match (reader.spanned-sexpr-view form)
                        [(BracketList items _)
                          (match (reader.spanned-sexpr-view items)
                            [(Cons alpha tail _)
                              (and
                                (match (reader.spanned-sexpr-view alpha)
                                  [(Sym name-id _)
                                    (string.eq
                                      (reader.symbol-text-for-syntax-id name-id)
                                      "alpha")]
                                  [_ false])
                                (match (reader.spanned-sexpr-view tail)
                                  [(Cons nested end _)
                                    (and
                                      (match (reader.spanned-sexpr-view nested)
                                        [(Cons _ _ _) true]
                                        [_ false])
                                      (match (reader.spanned-sexpr-view end)
                                        [(Nil _) true]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false])]
                        [_ false]))]
                  [_ false]))])]))
    (match (begin
      (reader.sp-node-pool-reset!)
      (reader.data-result "'alpha"))
      [(Err _) false]
      [(Ok form)
        (and
          (= (reader.sp-node-pool-len) 2)
          (match (reader.sexpr-view form)
            [(Cons quote tail)
              (and
                (reader-test-symbol? quote "quote")
                (match (reader.sexpr-view tail)
                  [(Cons value end)
                    (and
                      (reader-test-symbol? value "alpha")
                      (match (reader.sexpr-view end)
                        [(Nil) true]
                        [_ false]))]
                  [_ false]))]
            [_ false]))])
    (begin
      (reader.sp-node-pool-reset!)
      (match (lexer.spanned-result "(alpha]")
        [(Err _) false]
        [(Ok toks)
          (match (reader.spanned-result toks)
            [(Ok _) false]
            [(Err err)
              (let
                [span : token.SourceSpan
                  (token.source-error-span
                    (unsafe
                      (ptr-read (ptr-addr-of err))))]
                (and
                  (string.eq
                    (token.source-error-message err)
                    "reader: mismatched delimiter: expected ')' but found ']' at 1:7")
                  (= (token.span-start-line span) 1)
                  (= (token.span-start-col span) 7)))])]))
    (let
      [_reset-data : unit (reader.sp-node-pool-reset!)]
      [data-error-ok : bool
        (match (reader.data-result "((alpha)]")
          [(Ok _) false]
          [(Err _)
            (and (= (reader.sp-node-pool-len) 0) (= reader.sp-builder-count 0))])]
      [_reset-spanned : unit (reader.sp-node-pool-reset!)]
      [spanned-error-ok : bool
        (match (lexer.spanned-result "((alpha)]")
          [(Err _) false]
          [(Ok toks)
            (match (reader.spanned-result toks)
              [(Ok _) false]
              [(Err _)
                (and
                  (= (reader.sp-node-pool-len) 0)
                  (= reader.sp-builder-count 0))])])]
      [repeated-read-ok : bool
        (match (lexer.spanned-result "(beta)")
          [(Err _) false]
          [(Ok toks)
            (match (reader.spanned-result toks)
              [(Err _) false]
              [(Ok form)
                (and
                  (= (reader.sp-node-pool-len) 1)
                  (match (reader.spanned-sexpr-view form)
                    [(Cons value tail _)
                      (and
                        (match (reader.spanned-sexpr-view value)
                          [(Sym name-id _)
                            (string.eq
                              (reader.symbol-text-for-syntax-id name-id)
                              "beta")]
                          [_ false])
                        (match (reader.spanned-sexpr-view tail)
                          [(Nil _) true]
                          [_ false]))]
                    [_ false]))])])]
      [ok : bool (and data-error-ok spanned-error-ok repeated-read-ok)]
      (reader.sp-node-pool-reset!)
      ok))
    unit
    (io.panic "reader: dense child range self-test failed")))

(test
  reader-data-mode
  (if (reader-test-data-mode?)
    unit
    (io.panic "reader: data mode self-test failed")))

(test
  reader-projection-suffixes
  (if (and
    ;; The suffix token is consumed only when no whitespace separates it from
    ;; the closing delimiter. The final token in both streams is End.
    (reader-test-projection-suffix-cursor? "(array-ref items 0).inner.value" 6)
    (reader-test-projection-suffix-cursor? "(array-ref items 0) .value" 5)
    (match (lexer.spanned-result "(deref boxed).0")
      [(Err _) false]
      [(Ok toks)
        (let
          [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
          (reader.sp-node-pool-reset!)
          (set! (array-ref cur 0) 0)
          (match (reader.form-spanned-result (& toks) (&mut cur))
            [(Ok _) false]
            [(Err err)
              (string.eq
                (token.source-error-message err)
                "reader: dotted field access cannot use numeric field segments; use tuple-ref or array-ref")]))]))
    unit
    (io.panic "reader: projection suffix self-test failed")))

(define (spanned-token-buffer-release-regrow-ok?) : bool
  (lexer.spanned-token-buffer-release!)
  (if (and
    (= (array-length lexer.lex-spanned-token-buffer) 0)
    (= lexer.lex-spanned-token-buffer-arena 0))
    (match (lexer.spanned-result "(release-regrow)")
      [(Ok tokens)
        (let
          [regrown-ok : bool
            (and
              (> (array-length tokens) 0)
              (!= lexer.lex-spanned-token-buffer-arena 0)
              (=
                (token.tag
                  (token.spanned-token-tok (lexer.array-shared-view tokens 0)))
                (token.tag-lparen)))]
          (lexer.spanned-token-buffer-release!)
          (let
            [released-again-ok : bool
              (and
                (= (array-length lexer.lex-spanned-token-buffer) 0)
                (= lexer.lex-spanned-token-buffer-arena 0))]
            ;; A release without a backing arena is idempotent.
            (lexer.spanned-token-buffer-release!)
            (and
              regrown-ok
              released-again-ok
              (= (array-length lexer.lex-spanned-token-buffer) 0)
              (= lexer.lex-spanned-token-buffer-arena 0))))]
      [(Err _) false])
    false))

(define (spanned-token-buffer-arena-ownership-ok?) : bool
  (let
    [scratch : arena.Arena (arena.make)]
    [required : i64 (+ (array-length lexer.lex-spanned-token-buffer) 1)]
    [witness : token.SpannedToken (token.spanned-token-new LBracket 7 11)]
    ;; Earlier checks may intentionally release the shared storage. Keep
    ;; this ownership check independent of test order before parking slot 0.
    (lexer.spanned-token-buffer-ensure! 1 0)
    (in-arena
      scratch
      (lexer.spanned-token-buffer-set! 0 witness)
      (lexer.spanned-token-buffer-grow-to! required 1))
    (arena.destroy-safe! scratch)
    (and
      (>= (array-length lexer.lex-spanned-token-buffer) required)
      (spanned-token-buffer-grow-preserves-records?)
      (match (lexer.spanned-result "(arena-ok)")
        [(Ok tokens)
          (and
            (=
              (token.tag
                (token.spanned-token-tok
                  (unsafe
                    (ptr-read (ptr-offset (__tl_array-data tokens) 0)))))
              (token.tag-lparen))
            (=
              (token.tag
                (token.spanned-token-tok
                  (unsafe
                    (ptr-read (ptr-offset (__tl_array-data tokens) 3)))))
              (token.tag-end)))]
        [(Err _) false]))))

;; The record the ownership check parked at slot 0 must survive the grow above:
;; mid-scan growth relies on it.
(define (spanned-token-buffer-grow-preserves-records?) : bool
  (and
    (=
      (token.tag
        (token.spanned-token-tok
          (unsafe
            (ptr-read (__tl_array-data lexer.lex-spanned-token-buffer)))))
      (token.tag-lbracket))
    (=
      (token.spanned-token-line (array-ref lexer.lex-spanned-token-buffer 0))
      7)
    (=
      (token.spanned-token-col (array-ref lexer.lex-spanned-token-buffer 0))
      11)))

(define (result-with-intern-state
  [src : String]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : lexer.ResultTokens
  (ci.intern-compat-state-ensure-ready! intern-state)
  (lexer.result-with-intern-owner
    src
    (lexer.LexerInternOwner.State (& intern-state))))

(define (percent-symbol-ok?) : bool
  (match (lexer.result "(% n 16)")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-sym))
        (string.eq (token.sym (lexer.array-shared-view toks 1)) "%"))]
    [(Err _) false]))

(define (ampersand-symbol-ok?) : bool
  (match (lexer.result "(& r String) (&mut r String)")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-sym))
        (string.eq (token.sym (lexer.array-shared-view toks 1)) "&")
        (= (token.tag (lexer.array-shared-view toks 6)) (token.tag-sym))
        (string.eq (token.sym (lexer.array-shared-view toks 6)) "&mut"))]
    [(Err _) false]))

(define (float-token-ok?) : bool
  (match (lexer.result "(3.14)")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-float))
        (string.eq (token.float (& (array-ref toks 1))) "3.14"))]
    [(Err _) false]))

(define (negative-int-token-ok?) : bool
  (match (lexer.result "(-1 - x)")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-int))
        (= (token.int (& (array-ref toks 1))) -1)
        (= (token.tag (lexer.array-shared-view toks 2)) (token.tag-sym))
        (string.eq (token.sym (lexer.array-shared-view toks 2)) "-"))]
    [(Err _) false]))

(define (token-int-eq?
  [toks : (& toks (__tl_dyn-array token.Token))]
  [idx : i64]
  [value : i64]) : bool
  (let
    [tok : (& toks token.Token) (& (array-ref toks idx))]
    (and (= (token.tag-ref tok) (token.tag-int)) (= (token.int tok) value))))

(define (token-sym-eq?
  [toks : (& toks (__tl_dyn-array token.Token))]
  [idx : i64]
  [value : String]) : bool
  (let
    [tok : (& toks token.Token) (& (array-ref toks idx))]
    (and
      (= (token.tag-ref tok) (token.tag-sym))
      (string.eq (ci.intern-id-str (token.sym-id tok)) value))))

(define (prefixed-int-token-ok?) : bool
  (match (lexer.result "(0x2a 0x2A -0x2a 0b101010 -0b101010)")
    [(Ok toks)
      (and
        (token-int-eq? (& toks) 1 42)
        (token-int-eq? (& toks) 2 42)
        (token-int-eq? (& toks) 3 -42)
        (token-int-eq? (& toks) 4 42)
        (token-int-eq? (& toks) 5 -42)
        (= (token.tag (lexer.array-shared-view toks 7)) (token.tag-end)))]
    [(Err _) false]))

;; Returns 42 when the spanned lexer records correct 1-based line/column
;; positions, including a token inside a nested list and the trailing EOF.
;; Source `"(a\n  (b c))"` lexes to:
;;   0:'(' 1:1   1:'a' 1:2   2:'(' 2:3   3:'b' 2:4   4:'c' 2:6
;;   5:')' 2:7   6:')' 2:8   7:token.Token.End 2:9
(define (quote-text) : String
  "\"")

(define (backslash-text) : String
  "\\")

(define (basic-token-sequence-ok?) : bool
  (match (lexer.result "(define [x : i64] -42 \"ok\" '\\n')")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-lparen))
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-sym))
        (string.eq (token.sym (lexer.array-shared-view toks 1)) "define")
        (= (token.tag (lexer.array-shared-view toks 2)) (token.tag-lbracket))
        (string.eq (token.sym (lexer.array-shared-view toks 3)) "x")
        (string.eq (token.sym (lexer.array-shared-view toks 4)) ":")
        (string.eq (token.sym (lexer.array-shared-view toks 5)) "i64")
        (= (token.tag (lexer.array-shared-view toks 6)) (token.tag-rbracket))
        (= (token.int (& (array-ref toks 7))) -42)
        (string.eq (token.str (lexer.array-shared-view toks 8)) "ok")
        (= (token.char (& (array-ref toks 9))) '\n')
        (= (token.tag (lexer.array-shared-view toks 10)) (token.tag-rparen))
        (= (token.tag (lexer.array-shared-view toks 11)) (token.tag-end)))]
    [(Err _) false]))

(define (colon-annotation-tokens-ok?) : bool
  (match (lexer.result
    "[x:i64] [y :i32] (:link \"m\") ( :unknown 1) (import pkg:math.core :as math)")
    [(Ok toks)
      (and
        (token-sym-eq? (& toks) 1 "x")
        (token-sym-eq? (& toks) 2 ":")
        (token-sym-eq? (& toks) 3 "i64")
        (token-sym-eq? (& toks) 6 "y")
        (token-sym-eq? (& toks) 7 ":")
        (token-sym-eq? (& toks) 8 "i32")
        (token-sym-eq? (& toks) 11 ":link")
        (token-sym-eq? (& toks) 15 ":unknown")
        (token-sym-eq? (& toks) 20 "pkg:math.core")
        (token-sym-eq? (& toks) 21 ":as")
        (= (token.tag (lexer.array-shared-view toks 24)) (token.tag-end)))]
    [(Err _) false]))

(define (spanned-token-sym-eq?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [idx : i64]
  [value : String]) : bool
  (let
    [tok : (& toks token.Token)
      (token.spanned-token-token-ref (& (array-ref toks idx)))]
    (and
      (= (token.tag-ref tok) (token.tag-sym))
      (string.eq (ci.intern-id-str (token.sym-id tok)) value))))

(define (spanned-colon-annotation-tokens-ok?) : bool
  (match (lexer.spanned-result "[x:i64] (:link \"m\")")
    [(Ok toks)
      (and
        (spanned-token-sym-eq? (& toks) 1 "x")
        (spanned-token-sym-eq? (& toks) 2 ":")
        (spanned-token-sym-eq? (& toks) 3 "i64")
        (spanned-token-sym-eq? (& toks) 6 ":link")
        (=
          (token.tag (token.spanned-token-tok (lexer.array-shared-view toks 9)))
          (token.tag-end)))]
    [(Err _) false]))

(define (apostrophe-char-source [body : String]) : String
  (str_cat.str-cat "'" body "'"))

(define (quote-vs-apostrophe-char-ok?) : bool
  (and
    (match (lexer.result "'form")
      [(Ok toks)
        (and
          (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-quote))
          (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-sym))
          (string.eq (token.sym (lexer.array-shared-view toks 1)) "form")
          (= (token.tag (lexer.array-shared-view toks 2)) (token.tag-end)))]
      [(Err _) false])
    (match (lexer.result "'ab'")
      [(Ok toks)
        (and
          (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-quote))
          (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-sym))
          (string.eq (token.sym (lexer.array-shared-view toks 1)) "ab")
          (= (token.tag (lexer.array-shared-view toks 2)) (token.tag-quote))
          (= (token.tag (lexer.array-shared-view toks 3)) (token.tag-end)))]
      [(Err _) false])
    (match (lexer.result "'a'")
      [(Ok toks)
        (and
          (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-char))
          (= (token.char (& (array-ref toks 0))) 'a')
          (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-end)))]
      [(Err _) false])))

(define (one-apostrophe-char-ok? [body : String] [want : char]) : bool
  (match (lexer.result (apostrophe-char-source body))
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-char))
        (= (token.char (& (array-ref toks 0))) want)
        (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-end)))]
    [(Err _) false]))

(define (legacy-char-rejected? [src : String]) : bool
  (match (lexer.result src)
    [(Ok _) false]
    [(Err message) (string.eq message "lexer: unexpected character")]))

(define (char-literals-ok?) : bool
  (let
    [slash : String (backslash-text)]
    (and
      (one-apostrophe-char-ok? "a" 'a')
      (one-apostrophe-char-ok? "Z" 'Z')
      (one-apostrophe-char-ok? "0" '0')
      (one-apostrophe-char-ok? "+" '+')
      (one-apostrophe-char-ok? " " ' ')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "n")
        '\n')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "t")
        '\t')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "r")
        '\r')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "0")
        '\0')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) (string.copy (& slash)))
        '\\')
      (one-apostrophe-char-ok? (str_cat.str-cat slash "'") '\'')
      (legacy-char-rejected? "#x'")
      (legacy-char-rejected? "#\\n'")
      (legacy-char-rejected? "#\\space'"))))

(define (error-ok?
  [src : String]
  [want-line : i64]
  [want-col : i64]
  [want-message : String]) : bool
  (match (lexer.spanned-result src)
    [(Ok _) false]
    [(Err err)
      (and
        (string.eq
          (token.source-error-message (lexer.global-shared-view err))
          want-message)
        (span-eq?
          (token.source-error-span err)
          want-line
          want-col
          want-line
          want-col))]))

(define (error-spans-ok?) : bool
  (let
    [slash : String (backslash-text)]
    (and
      (error-ok? "\n#\\bogus'" 2 1 "lexer: unexpected character")
      (error-ok?
        (apostrophe-char-source (str_cat.str-cat (string.copy (& slash)) "x"))
        1
        1
        "lexer: unknown character escape")
      (error-ok?
        (str_cat.str-cat "'" slash "n")
        1
        1
        "lexer: unterminated character literal")
      (error-ok? "ok\n@" 2 1 "lexer: unexpected character"))))

(define (prefixed-int-errors-ok?) : bool
  (and
    (error-ok? "0x" 1 1 "lexer: malformed integer literal")
    (error-ok? "0xg" 1 1 "lexer: malformed integer literal")
    (error-ok? "0b102" 1 1 "lexer: malformed integer literal")))

(define (result-prefixed-int-ok?) : bool
  (match (lexer.result "(0x2a -0b101010)")
    [(Ok _) true]
    [(Err _) false]))

(define (result-prefixed-int-error-ok?) : bool
  (match (lexer.result "0b102")
    [(Ok _) false]
    [(Err message) (string.eq message "lexer: malformed integer literal")]))

(define (string-source [inner : String]) : String
  (str_cat.str-cat (quote-text) inner (quote-text)))

(define (string-token-ok? [src : String] [expected : String]) : bool
  (let
    [toks : (__tl_dyn-array token.Token) (lexer.lex src)]
    (and
      (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-str))
      (string.eq (token.str (lexer.array-shared-view toks 0)) expected)
      (= (token.tag (lexer.array-shared-view toks 1)) (token.tag-end)))))

(define (string-token-retains-id?) : bool
  (let
    [toks : (__tl_dyn-array token.Token)
      (lexer.lex (string-source "literal-id"))]
    [literal : token.Token (lexer.array-shared-view toks 0)]
    [literal-id : ci.InternId (token.str-id (& literal))]
    (and
      (>= (ci.intern-id-value literal-id) 0)
      (string.eq (ci.intern-id-str literal-id) "literal-id")
      (ci.intern-id-eq? (token.str-id (& literal)) literal-id))))

(define (escaped-quote-source-inner) : String
  (str_cat.str-cat
    "say "
    (backslash-text)
    (quote-text)
    "hi"
    (backslash-text)
    (quote-text)))

(define (backslash-quote-source-inner) : String
  (str_cat.str-cat
    (backslash-text)
    (backslash-text)
    (backslash-text)
    (quote-text)))

(define (string-escapes-ok?) : bool
  (let
    [slash : String (backslash-text)]
    [quote : String (quote-text)]
    (and
      (string-token-ok? (string-source "hello\\nworld") "hello\nworld")
      (string-token-ok?
        (string-source (escaped-quote-source-inner))
        (str_cat.str-cat
          "say "
          (string.copy (& quote))
          "hi"
          (string.copy (& quote))))
      (string-token-ok?
        (string-source
          (str_cat.str-cat (string.copy (& slash)) (string.copy (& slash))))
        (string.copy (& slash)))
      (string-token-ok?
        (string-source (backslash-quote-source-inner))
        (str_cat.str-cat (string.copy (& slash)) (string.copy (& quote)))))))

(define (quote-prefix-tokens-ok?) : bool
  (match (lexer.result "`(if ,x ,@xs)")
    [(Ok toks)
      (and
        (= (token.tag (lexer.array-shared-view toks 0)) (token.tag-backtick))
        (= (token.tag (lexer.array-shared-view toks 3)) (token.tag-comma))
        (= (token.tag (lexer.array-shared-view toks 5)) (token.tag-comma-at))
        (= (token.tag (lexer.array-shared-view toks 7)) (token.tag-rparen))
        (= (token.tag (lexer.array-shared-view toks 8)) (token.tag-end)))]
    [(Err _) false]))

(define (span-positions-ok? [s : (& s (__tl_dyn-array token.SpannedToken))]) : bool
  (and
    (= (token.spanned-token-line (array-ref s 0)) 1)
    (= (token.spanned-token-col (array-ref s 0)) 1)
    (= (token.spanned-token-col (array-ref s 1)) 2)
    (= (token.spanned-token-line (array-ref s 2)) 2)
    (= (token.spanned-token-col (array-ref s 2)) 3)
    (= (token.spanned-token-col (array-ref s 3)) 4)
    (= (token.spanned-token-col (array-ref s 4)) 6)
    (= (token.spanned-token-line (array-ref s 7)) 2)
    (= (token.spanned-token-col (array-ref s 7)) 9)
    (=
      (token.tag-ref (token.spanned-token-token-ref (& (array-ref s 7))))
      (token.tag-end))))

(define (lexer-intern-owner-isolation-ok?) : bool
  (let
    [active-decoy-id : i64 (ci.intern-source-slice "lexer-active-decoy" 0 18)]
    [active-table-before : i64 (ci.intern-active-table-id)]
    [active-generation-before : i64 (ci.intern-generation)]
    [active-len-before : i64 (ci.intern-pool-len)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : String "(alpha : pkg/module.name \"payload\")"]
    [ids-a : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [ids-b : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [len-a : i64 0]
    [len-b : i64 0]
    [len-b-after-spanned : i64 0]
    (match (result-with-intern-state
      (lexer.global-shared-view source)
      (&mut state-a))
      [(Err _) (return false)]
      [(Ok tokens)
        (unless
          (and
            (=
              (token.tag (lexer.array-shared-view tokens 0))
              (token.tag-lparen))
            (=
              (token.tag (lexer.array-shared-view tokens 5))
              (token.tag-rparen))
            (= (token.tag (lexer.array-shared-view tokens 6)) (token.tag-end)))
          (return false))
        (set!
          (array-ref ids-a 0)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 1)))))
        (set!
          (array-ref ids-a 1)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 2)))))
        (set!
          (array-ref ids-a 2)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 3)))))
        (set!
          (array-ref ids-a 3)
          (ci.intern-id-value (token.str-id (& (array-ref tokens 4)))))
        (set! len-a (ci.intern-compat-state-pool-len state-a))])
    (match (result-with-intern-state source (&mut state-b))
      [(Err _) (return false)]
      [(Ok tokens)
        (set!
          (array-ref ids-b 0)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 1)))))
        (set!
          (array-ref ids-b 1)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 2)))))
        (set!
          (array-ref ids-b 2)
          (ci.intern-id-value (token.sym-id (& (array-ref tokens 3)))))
        (set!
          (array-ref ids-b 3)
          (ci.intern-id-value (token.str-id (& (array-ref tokens 4)))))
        (set! len-b (ci.intern-compat-state-pool-len state-b))])
    (unless
      (and
        (= (array-ref ids-a 0) (array-ref ids-b 0))
        (= (array-ref ids-a 1) (array-ref ids-b 1))
        (= (array-ref ids-a 2) (array-ref ids-b 2))
        (= (array-ref ids-a 3) (array-ref ids-b 3))
        (= len-a len-b)
        (string.eq
          (ci.intern-compat-state-str state-a (array-ref ids-a 0))
          "alpha")
        (string.eq (ci.intern-compat-state-str state-a (array-ref ids-a 1)) ":")
        (string.eq
          (ci.intern-compat-state-str state-a (array-ref ids-a 2))
          "pkg/module.name")
        (string.eq
          (ci.intern-compat-state-str state-a (array-ref ids-a 3))
          "payload")
        (ci.intern-compat-state-qualified? state-a (array-ref ids-a 2))
        (ci.intern-compat-state-dotted? state-a (array-ref ids-a 2))
        (string.eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-dotted-final-id state-a (array-ref ids-a 2)))
          "name"))
      (return false))
    (match (lexer.spanned-result-with-intern-state "spanned" (&mut state-b))
      [(Err _) (return false)]
      [(Ok spanned)
        (let
          [spanned-token : token.Token
            (token.spanned-token-tok (lexer.array-shared-view spanned 0))]
          [spanned-id : i64
            (ci.intern-id-value (token.sym-id (& spanned-token)))]
          (unless
            (and
              (= (token.tag spanned-token) (token.tag-sym))
              (string.eq
                (ci.intern-compat-state-str state-b spanned-id)
                "spanned")
              (=
                (token.tag
                  (token.spanned-token-tok (lexer.array-shared-view spanned 1)))
                (token.tag-end)))
            (return false))
          (set! len-b-after-spanned (ci.intern-compat-state-pool-len state-b)))])
    (match (result-with-intern-state "failure @" (&mut state-a))
      [(Ok _) (return false)]
      [(Err message)
        (unless
          (string.eq message "lexer: unexpected character")
          (return false))])
    (and
      (= (ci.intern-compat-state-pool-len state-b) len-b-after-spanned)
      (= (ci.intern-active-table-id) active-table-before)
      (= (ci.intern-generation) active-generation-before)
      (= (ci.intern-pool-len) active-len-before)
      (string.eq (ci.intern-str active-decoy-id) "lexer-active-decoy"))))

(define (span-positions-self-ok?) : bool
  (match (lexer.spanned-result "(a\n  (b c))")
    [(Ok s) (span-positions-ok? (& s))]
    [(Err _) false]))

(define (span-self-test) : i64
  (let
    [ok : bool true]
    (set!
      ok
      (and
        ok
        (span-positions-self-ok?)
        (string-escapes-ok?)
        (string-token-retains-id?)
        (basic-token-sequence-ok?)
        (colon-annotation-tokens-ok?)
        (spanned-colon-annotation-tokens-ok?)
        (char-literals-ok?)
        (quote-vs-apostrophe-char-ok?)
        (error-spans-ok?)
        (percent-symbol-ok?)
        (ampersand-symbol-ok?)
        (float-token-ok?)
        (negative-int-token-ok?)
        (prefixed-int-token-ok?)
        (prefixed-int-errors-ok?)
        (result-prefixed-int-ok?)
        (result-prefixed-int-error-ok?)
        (quote-prefix-tokens-ok?)
        (lexer-intern-owner-isolation-ok?)
        (spanned-token-buffer-arena-ownership-ok?)
        (spanned-token-buffer-release-regrow-ok?)))
    (if ok
      42
      1)))

(define (span-eq?
  [span : token.SourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= (token.span-start-line span) start-line)
    (= (token.span-start-col span) start-col)
    (= (token.span-end-line span) end-line)
    (= (token.span-end-col span) end-col)))

;; A list never straddles a segment: one that would cross a boundary starts at
;; the next segment, the skipped rows hold the filler, and a list longer than a
;; segment still reads back in order. Growth never moves a row.
;; Builds a list of `count` Int rows and returns its first row id (-1 when the
;; list does not have `count` rows).
(define (sp-node-pool-test-list [count : i64] [span : token.SourceSpan]) : i64
  (let
    [builder : reader.SpannedSexprBuilder (reader.spanned-sexpr-builder-new)]
    [i : i64 0]
    (while (< i count)
      (set! builder (reader.spanned-sexpr-builder-push builder (Int i "" span)))
      (set! i (+ i 1)))
    (match (reader.spanned-sexpr-list-from-builder builder span)
      [(List start length _)
        (if (= length count)
          start
          -1)]
      [_ -1])))

(define (sp-node-pool-test-list-reads? [start : i64] [count : i64]) : bool
  (let
    [ok : bool true]
    [i : i64 0]
    (while (and ok (< i count))
      (match (reader.sp-node-get (+ start i))
        [(Int value _ _) (set! ok (= value i))]
        [_ (set! ok false)])
      (set! i (+ i 1)))
    ok))

(define (sp-node-pool-segment-placement-ok?) : bool
  (let
    [rows : i64 reader.sp-node-segment-rows]
    [span : token.SourceSpan (token.SourceSpan 1 1 1 1)]
    [_reset : unit (reader.sp-node-pool-reset!)]
    [_fill : unit
      (while (< (reader.sp-node-pool-len) (- rows 3))
        (reader.sp-node-pool-fill!
          (reader.sp-node-pool-reserve! 1)
          (Int 7 "__tl_pool_placement" span)))]
    [first-address : i64 (reader.sp-node-pool-row-address 0)]
    [straddler : i64 (sp-node-pool-test-list 10 span)]
    [long : i64 (sp-node-pool-test-list (+ (* 2 rows) 5) span)]
    [after : i64 (sp-node-pool-test-list 3 span)]
    [placed : bool
      (and
        (= straddler rows)
        (= long (* 2 rows))
        (= after (+ (* 4 rows) 5))
        (match (reader.sp-node-get (- rows 1))
          [(Int value text _) (and (= value 0) (string.eq text ""))]
          [_ false]))]
    [reads : bool
      (and
        (sp-node-pool-test-list-reads? straddler 10)
        (sp-node-pool-test-list-reads? long (+ (* 2 rows) 5))
        (sp-node-pool-test-list-reads? after 3))]
    [stable : bool (= (reader.sp-node-pool-row-address 0) first-address)]
    (reader.sp-node-pool-reset!)
    (and placed reads stable)))

(test
  reader-pool-segments
  (if (sp-node-pool-segment-placement-ok?)
    unit
    (io.panic "reader: segmented pool placement self-test failed")))