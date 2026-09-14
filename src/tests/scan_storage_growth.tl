;; Resource and semantic guards for scratch growth. These budgets describe
;; fixed source workloads, not allocator addresses or a particular grow call.
(import lex)
(import read as reader)
(import token)
(import compiler_intern as ci)
(cfg test (import compiler_allocation_profile as allocation_profile))
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(cfg compile-profile (import stdlib.profile))

(cfg
  compile-profile
  (test
    reader-builder-growth-after-large-file-has-bounded-allocation
    (begin
      (reader.sexpr-node-pool-release!)
      (let
        [index : i64 0]
        (while (< index 262144)
          (begin
            (reader.sexpr-node-push (reader.Sexpr.Int index ""))
            (set! index (+ index 1)))))
      (reader.sexpr-node-pool-reset!)
      (let
        [before : i64 (profile.alloc-total)]
        [builder : reader.SexprBuilder (reader.sexpr-builder-new)]
        [index : i64 0]
        (begin
          (while (< index 65536)
            (begin
              (set!
                builder
                (reader.sexpr-builder-push builder (reader.Sexpr.Int index "")))
              (set! index (+ index 1))))
          (let
            [allocated : i64 (- (profile.alloc-total) before)]
            [valid : bool
              (match (reader.sexpr-list-from-builder builder)
                [(reader.Sexpr.List start length)
                  (and
                    (= length 65536)
                    (match (reader.sexpr-node-get (+ start 65535))
                      [(reader.Sexpr.Int value _) (= value 65535)]
                      [_ false]))]
                [_ false])]
            (begin
              (reader.sexpr-node-pool-release!)
              (unless
                (and valid (> allocated 0) (<= allocated (* 4 1024 1024)))
                (io.panic
                  "scan storage: builder growth after a large file exceeded 4 MiB or changed records")))))))))

(define (scan-doubled-source [text : String] [times : i64]) : String
  (let
    [out : String text]
    [index : i64 0]
    (begin
      (while (< index times)
        (begin
          (set! out (str_cat.str-cat (string.copy out) out))
          (set! index (+ index 1))))
      out)))

(define (scan-token-valid?
  [record : (& record token.SpannedToken)]
  [index : i64]) : bool
  (let
    [position : i64 (% index 7)]
    [column : i64
      (cond
        [(= position 0) 1]
        [(= position 1) 2]
        [(= position 2) 7]
        [(= position 3) 12]
        [(= position 4) 16]
        [(= position 5) 24]
        [else 27])]
    (and
      (= (token.spanned-token-line record) (+ (/ index 7) 1))
      (= (token.spanned-token-col record) column)
      (match (token.spanned-token-token-ref record)
        [(token.Token.LParen) (= position 0)]
        [(token.Token.Sym name)
          (and
            (= position 1)
            (string.eq (ci.intern-str (ci.intern-id-value name)) "atom"))]
        [(token.Token.Int value text)
          (and (= position 2) (= (deref value) 123) (string.eq text "0x7b"))]
        [(token.Token.Char value) (and (= position 3) (= (deref value) 'q'))]
        [(token.Token.Str text)
          (and
            (= position 4)
            (string.eq (ci.intern-str (ci.intern-id-value text)) "bytes"))]
        [(token.Token.Float text) (and (= position 5) (string.eq text "1.5"))]
        [(token.Token.RParen) (= position 6)]
        [_ false]))))

(cfg
  test
  (define (scan-lexer-growth-ok?) : bool
    (begin
      (lex.spanned-token-buffer-release!)
      (let
        [source : String
          (scan-doubled-source "(atom 0x7b 'q' \"bytes\" 1.5)\n" 9)]
        [caller : i64 (arena.tl_arena_current)]
        [valid : bool
          (match (lex.spanned-result source)
            [(lex.ResultSpannedTokens.Err _) false]
            [(lex.ResultSpannedTokens.Ok tokens)
              (let
                [index : i64 0]
                [ok : bool true]
                (begin
                  (while (and ok (< index 3584))
                    (begin
                      (unless
                        (scan-token-valid? (& (array-ref tokens index)) index)
                        (begin
                          (io.eprintln
                            "scan storage: token {} failed; tag {} at {}:{}"
                            index
                            (token.tag-ref
                              (token.spanned-token-token-ref
                                (& (array-ref tokens index))))
                            (token.spanned-token-line (array-ref tokens index))
                            (token.spanned-token-col (array-ref tokens index)))
                          (set! ok false)))
                      (set! index (+ index 1))))
                  (and
                    ok
                    (=
                      (token.tag-ref
                        (token.spanned-token-token-ref
                          (& (array-ref tokens 3584))))
                      (token.tag-end))
                    (= (token.spanned-token-line (array-ref tokens 3584)) 513)
                    (= (token.spanned-token-col (array-ref tokens 3584)) 1)
                    (= (arena.tl_arena_current) caller)
                    (<=
                      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
                        (lex.spanned-token-buffer-arena-handle-value))
                      (* 160 1024)))))])]
        (begin
          (lex.spanned-token-buffer-release!)
          (and
            valid
            (= (lex.spanned-token-buffer-arena-handle-value) 0)
            (= (arena.tl_arena_current) caller)))))))

(define (scan-reader-int? [node : reader.Sexpr] [expected : i64]) : bool
  (match node
    [(reader.Sexpr.Int value _) (= value expected)]
    [_ false]))

(define (scan-reader-group? [node : reader.Sexpr] [position : i64]) : bool
  (match node
    [(reader.Sexpr.Int value _) (and (= position 0) (= value 1))]
    [(reader.Sexpr.List start length)
      (and
        (= position 1)
        (= length 2)
        (scan-reader-int? (reader.sexpr-node-get start) 2)
        (scan-reader-int? (reader.sexpr-node-get (+ start 1)) 3))]
    [(reader.Sexpr.Str text)
      (and
        (= position 2)
        (string.eq (ci.intern-str (ci.intern-id-value text)) "bytes"))]
    [_ false]))

(define (scan-reader-wide-ok? [source : String]) : bool
  (match (reader.result (lex.lex source))
    [(reader.ResultSexpr.Err _) false]
    [(reader.ResultSexpr.Ok form)
      (match form
        [(reader.Sexpr.List start length)
          (let
            [index : i64 1]
            [ok : bool true]
            (begin
              (while (and ok (< index (- length 1)))
                (begin
                  (unless
                    (scan-reader-group?
                      (reader.sexpr-node-get (+ start index))
                      (% (- index 1) 3))
                    (set! ok false))
                  (set! index (+ index 1))))
              (and
                ok
                (= length 1538)
                (scan-reader-int? (reader.sexpr-node-get start) 0)
                (scan-reader-int?
                  (reader.sexpr-node-get (+ start (- length 1)))
                  4))))]
        [_ false])]))

(cfg
  test
  (define (scan-reader-growth-ok?) : bool
    (begin
      (reader.sexpr-node-pool-release!)
      (let
        [body : String (scan-doubled-source "1 (2 3) \"bytes\" " 9)]
        [source : String (str_cat.str-cat "(0 " body " 4)")]
        [caller : i64 (arena.tl_arena_current)]
        [wide-ok : bool (scan-reader-wide-ok? (string.copy source))]
        [budget-ok : bool
          (<=
            (+
              (allocation_profile.compiler-allocation-profile-arena-bump-bytes
                (reader.sexpr-node-pool-base-arena-handle-value))
              (allocation_profile.compiler-allocation-profile-arena-bump-bytes
                (reader.sexpr-builder-base-arena-handle-value)))
            (* 176 1024))]
        [error-ok : bool
          (match (reader.result (lex.lex (str_cat.str-cat "(" source)))
            [(reader.ResultSexpr.Ok _) false]
            [(reader.ResultSexpr.Err message)
              (and
                (string.eq message "reader: unterminated list (missing ')')")
                (= (reader.sexpr-node-pool-len) 0))])]
        [reuse-ok : bool
          (match (reader.result (lex.lex "(8)"))
            [(reader.ResultSexpr.Err _) false]
            [(reader.ResultSexpr.Ok form)
              (match form
                [(reader.Sexpr.List start length)
                  (and
                    (= length 1)
                    (scan-reader-int? (reader.sexpr-node-get start) 8))]
                [_ false])])]
        (begin
          (reader.sexpr-node-pool-release!)
          (and
            wide-ok
            budget-ok
            error-ok
            reuse-ok
            (= (reader.sexpr-node-pool-base-arena-handle-value) 0)
            (= (reader.sexpr-builder-base-arena-handle-value) 0)
            (= (arena.tl_arena_current) caller)))))))

(test
  lexer-growth-preserves-records-with-bounded-storage
  (unless
    (scan-lexer-growth-ok?)
    (io.panic "scan storage: lexer growth changed records or exceeded 160 KiB")))

(test
  reader-growth-preserves-nested-builders-and-error-reuse
  (unless
    (scan-reader-growth-ok?)
    (io.panic
      "scan storage: reader growth, error reuse, or 176 KiB budget failed")))

(test
  scan-storage-restores-transient-caller-and-regrows-after-retirement
  (let
    [scratch : arena.Arena (arena.make)]
    [ok : bool
      (in-arena scratch (and (scan-lexer-growth-ok?) (scan-reader-growth-ok?)))]
    (begin
      (arena.destroy-safe! scratch)
      (unless
        (and ok (scan-lexer-growth-ok?) (scan-reader-growth-ok?))
        (io.panic
          "scan storage: transient caller or retirement/regrowth failed")))))

(test
  lexer-growth-failure-preserves-diagnostic-and-empty-reuse
  (begin
    (lex.spanned-token-buffer-release!)
    (let
      [source : String
        (str_cat.str-cat
          (scan-doubled-source "(atom 0x7b 'q' \"bytes\" 1.5)\n" 9)
          "\"unterminated")]
      [caller : i64 (arena.tl_arena_current)]
      [error-ok : bool
        (match (lex.spanned-result source)
          [(lex.ResultSpannedTokens.Ok _) false]
          [(lex.ResultSpannedTokens.Err err)
            (and
              (string.eq err.message "lexer: unterminated string literal")
              (= err.span.start-line 513)
              (= err.span.start-col 1))])]
      [empty-ok : bool
        (match (lex.spanned-result "")
          [(lex.ResultSpannedTokens.Err _) false]
          [(lex.ResultSpannedTokens.Ok tokens)
            (and
              (=
                (token.tag-ref
                  (token.spanned-token-token-ref (& (array-ref tokens 0))))
                (token.tag-end))
              (= (token.spanned-token-line (array-ref tokens 0)) 1)
              (= (token.spanned-token-col (array-ref tokens 0)) 1))])]
      (begin
        (lex.spanned-token-buffer-release!)
        (unless
          (and error-ok empty-ok (= (arena.tl_arena_current) caller))
          (io.panic
            "scan storage: post-growth lexer diagnostic or empty reuse failed"))))))