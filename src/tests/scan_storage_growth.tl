;; Resource and semantic guards for scratch growth. These budgets describe
;; fixed source workloads, not allocator addresses or a particular grow call.
(import stdlib.iterator)
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

(define (retained-reader-row? [index : i64]) : bool
  (match (reader.sp-node-get index)
    [(Int value text span)
      (and
        (= value index)
        (string.eq (reader.sp-text text) "retained")
        (= span.start-line (+ index 1)))]
    [_ false]))

(define (retained-reader-growth-ok? [pool-current? : bool]) : bool
  (reader.sp-node-pool-reset!)
  (reader.sp-node-pool-compact-retained!)
  (let
    [caller : i64 (arena.tl_arena_current)]
    (for [index (iterator.range 0 32768)]
      (reader.sp-node-push
        (Int
          index
          (reader.sp-text-id "retained")
          (token.SourceSpan (+ index 1) 2 3 4)))
      unit)
    (reader.sp-node-pool-compact-retained!)
    (let
      [builder : reader.SpannedSexprBuilder (reader.spanned-sexpr-builder-new)]
      [span : token.SourceSpan (token.SourceSpan 9 8 7 6)]
      [old-owner : i64 (reader.sp-node-pool-base-arena-handle-value)]
      ;; Intern the spellings before the measured window below.
      [float-text : ci.InternId (reader.sp-text-id "1.5")]
      [retained-text : ci.InternId (reader.sp-text-id "retained")]
      [_old-bytes : i64
        (allocation_profile.compiler-allocation-profile-arena-bump-bytes
          old-owner)]
      [_before : i64 (cfg compile-profile (profile.alloc-live) 0)]
      [valid : bool true]
      (reader.spanned-sexpr-builder-push builder (Float float-text span))
      (reader.spanned-sexpr-builder-push builder (List 4 2 span))
      (if pool-current?
        (unsafe
          ;; lint-allow: raw-arena-op
          (arena.tl_arena_set old-owner))
        unit)
      (reader.sp-node-push
        (Int 32768 retained-text (token.SourceSpan 32769 2 3 4)))
      (let
        [new-owner : i64 (reader.sp-node-pool-base-arena-handle-value)]
        [new-bytes : i64
          (allocation_profile.compiler-allocation-profile-arena-bump-bytes
            new-owner)]
        [_after : i64 (cfg compile-profile (profile.alloc-live) 0)]
        (set!
          valid
          (and
            ;; Growth appends a segment to the retained owner; no row
            ;; moves and no owner is retired.
            (= old-owner new-owner)
            (<= (* new-bytes 4) (* 32769 56 5))
            (=
              (arena.tl_arena_current)
              (if pool-current?
                new-owner
                caller))
            (cfg
              compile-profile
              (= (- _after _before) (- new-bytes _old-bytes))
              true)))
        (unsafe
          ;; lint-allow: raw-arena-op
          (arena.tl_arena_set caller)))
      (for [index (iterator.range 0 32769)]
        (set! valid (and valid (retained-reader-row? index))))
      (match (reader.spanned-sexpr-list-from-builder builder span)
        [(List start length _)
          (set!
            valid
            (and
              valid
              (= start 32769)
              (= length 2)
              (match (reader.sp-node-get start)
                [(Float text saved)
                  (and
                    (string.eq (reader.sp-text text) "1.5")
                    (= saved.start-line 9))]
                [_ false])
              (match (reader.sp-node-get (+ start 1))
                [(List child count _)
                  (and (= child 4) (= count 2) (retained-reader-row? child))]
                [_ false])))]
        [_ (set! valid false)])
      (reader.sp-node-pool-reset!)
      (reader.sp-node-pool-compact-retained!)
      (and valid (= (reader.sp-node-pool-base-arena-handle-value) 0)))))

(test
  retained-reader-growth-preserves-rows-and-builders
  (unless
    (and (retained-reader-growth-ok? false) (retained-reader-growth-ok? true))
    (io.panic
      "retained reader: growth changed rows, builders, owner accounting or active arena")))

(test
  retained-reader-reset-restores-shared-growth
  (reader.sp-node-pool-reset!)
  (reader.sp-node-pool-compact-retained!)
  (reader.sp-node-push
    (Int 0 (reader.sp-text-id "") (token.SourceSpan 1 1 1 1)))
  (reader.sp-node-pool-compact-retained!)
  (reader.sp-node-pool-reset!)
  (let
    [owner : i64 (reader.sp-node-pool-base-arena-handle-value)]
    [shared : String
      (in-arena (arena.Arena owner) (string.copy "shared reader storage"))]
    (for [index (iterator.range 0 2049)]
      (reader.sp-node-push
        (Int index (reader.sp-text-id "") (token.SourceSpan 1 1 1 1)))
      unit)
    (unless
      (and
        (= owner (reader.sp-node-pool-base-arena-handle-value))
        (string.eq shared "shared reader storage"))
      (io.panic
        "retained reader: reset allowed growth to destroy shared storage")))
  (reader.sp-node-pool-reset!)
  (reader.sp-node-pool-compact-retained!))

(test
  retained-reader-error-and-empty-reuse
  (reader.sp-node-pool-reset!)
  (reader.sp-node-pool-compact-retained!)
  (reader.sp-node-push
    (Int 0 (reader.sp-text-id "retained") (token.SourceSpan 1 1 1 1)))
  (reader.sp-node-pool-compact-retained!)
  (match (lex.spanned-result "(7 (8) \"text\"")
    [(Ok tokens)
      (match (reader.spanned-result tokens)
        [(Err _)
          (unless
            (and (= (reader.sp-node-pool-len) 1) (retained-reader-row? 0))
            (io.panic "retained reader: failed read lost the retained prefix"))]
        [_ (io.panic "retained reader: accepted an unterminated list")])]
    [_ (io.panic "retained reader: lexer rejected the malformed reader input")])
  (match (lex.spanned-result "(9 10)")
    [(Ok tokens)
      (match (reader.spanned-result tokens)
        [(Ok form)
          (match form
            [(List start length _)
              (unless
                (and (= start 1) (= length 2))
                (io.panic "retained reader: failed read left a live builder"))]
            [_ (io.panic "retained reader: expected a list after failed read")])]
        [_ (io.panic "retained reader: valid reuse failed")])]
    [_ (io.panic "retained reader: valid reuse failed to lex")])
  (reader.sp-node-pool-reset!)
  (let
    [caller : i64 (arena.tl_arena_current)]
    (unsafe
      ;; lint-allow: raw-arena-op
      (arena.tl_arena_set (reader.sp-node-pool-base-arena-handle-value)))
    (reader.sp-node-pool-compact-retained!)
    (unless
      (and
        (= (arena.tl_arena_current) 0)
        (= (reader.sp-node-pool-base-arena-handle-value) 0))
      (io.panic "retained reader: empty compaction left a retired owner active"))
    (unsafe
      ;; lint-allow: raw-arena-op
      (arena.tl_arena_set caller))))

(define (scan-doubled-source [text : String] [times : i64]) : String
  (let
    [out : String text]
    (for [index (iterator.range 0 times)]
      (set! out (str_cat.str-cat (string.copy out) out)))
    out))

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
          (and (= position 2) (= value 123) (string.eq text "0x7b"))]
        [(token.Token.Char value) (and (= position 3) (= value 'q'))]
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
    (lex.spanned-token-buffer-release!)
    (let
      [source : String
        (scan-doubled-source "(atom 0x7b 'q' \"bytes\" 1.5)\n" 9)]
      [caller : i64 (arena.tl_arena_current)]
      [valid : bool
        (match (lex.spanned-result (& source))
          [(Err _) false]
          [(Ok tokens)
            (let
              [index : i64 0]
              [ok : bool true]
              (while (and ok (< index 3584))
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
                (+= index 1))
              (and
                ok
                (=
                  (token.tag-ref
                    (token.spanned-token-token-ref (& (array-ref tokens 3584))))
                  (token.tag-end))
                (= (token.spanned-token-line (array-ref tokens 3584)) 513)
                (= (token.spanned-token-col (array-ref tokens 3584)) 1)
                (= (arena.tl_arena_current) caller)
                (<=
                  (allocation_profile.compiler-allocation-profile-arena-bump-bytes
                    (lex.spanned-token-buffer-arena-handle-value))
                  (* 160 1024))))])]
      (lex.spanned-token-buffer-release!)
      (and
        valid
        (= (lex.spanned-token-buffer-arena-handle-value) 0)
        (= (arena.tl_arena_current) caller)))))

(define (scan-reader-int? [node : reader.SpannedSexpr] [expected : i64]) : bool
  (match node
    [(Int value _ _) (= value expected)]
    [_ false]))

(define (scan-reader-group? [node : reader.SpannedSexpr] [position : i64]) : bool
  (match node
    [(Int value _ _) (and (= position 0) (= value 1))]
    [(List start length _)
      (and
        (= position 1)
        (= length 2)
        (scan-reader-int? (reader.sp-node-get start) 2)
        (scan-reader-int? (reader.sp-node-get (+ start 1)) 3))]
    [(Str text _)
      (and
        (= position 2)
        (string.eq (ci.intern-str (ci.intern-id-value text)) "bytes"))]
    [_ false]))

(define (scan-reader-wide-ok? [source : String]) : bool
  (match (reader.data-result source)
    [(Err _) false]
    [(Ok form)
      (match form
        [(List start length _)
          (let
            [index : i64 1]
            [ok : bool true]
            (while (and ok (< index (- length 1)))
              (unless
                (scan-reader-group?
                  (reader.sp-node-get (+ start index))
                  (% (- index 1) 3))
                (set! ok false))
              (+= index 1))
            (and
              ok
              (= length 1538)
              (scan-reader-int? (reader.sp-node-get start) 0)
              (scan-reader-int? (reader.sp-node-get (+ start (- length 1))) 4)))]
        [_ false])]))

(cfg
  test
  (define (scan-reader-growth-ok?) : bool
    (reader.sp-node-pool-reset!)
    (let
      [body : String (scan-doubled-source "1 (2 3) \"bytes\" " 9)]
      [source : String (str_cat.str-cat "(0 " body " 4)")]
      [caller : i64 (arena.tl_arena_current)]
      [wide-ok : bool (scan-reader-wide-ok? (string.copy source))]
      [_reset-wide : unit (reader.sp-node-pool-reset!)]
      [error-ok : bool
        (match (reader.data-result (str_cat.str-cat "(" source))
          [(Ok _) false]
          [(Err message)
            (and
              (string.eq message "reader: unterminated list (missing ')')")
              (= (reader.sp-node-pool-len) 0))])]
      [reuse-ok : bool
        (match (reader.data-result "(8)")
          [(Err _) false]
          [(Ok form)
            (match form
              [(List start length _)
                (and
                  (= length 1)
                  (scan-reader-int? (reader.sp-node-get start) 8))]
              [_ false])])]
      (reader.sp-node-pool-reset!)
      (and wide-ok error-ok reuse-ok (= (arena.tl_arena_current) caller)))))

(test
  lexer-growth-preserves-records-with-bounded-storage
  (unless
    (scan-lexer-growth-ok?)
    (io.panic "scan storage: lexer growth changed records or exceeded 160 KiB")))

(test
  reader-growth-preserves-nested-builders-and-error-reuse
  (unless
    (scan-reader-growth-ok?)
    (io.panic "scan storage: reader growth or error reuse failed")))

(test
  scan-storage-restores-transient-caller-and-regrows-after-retirement
  (let
    [scratch : arena.Arena (arena.make)]
    [ok : bool
      (in-arena scratch (and (scan-lexer-growth-ok?) (scan-reader-growth-ok?)))]
    (arena.destroy-safe! scratch)
    (unless
      (and ok (scan-lexer-growth-ok?) (scan-reader-growth-ok?))
      (io.panic "scan storage: transient caller or retirement/regrowth failed"))))

(test
  lexer-growth-failure-preserves-diagnostic-and-empty-reuse
  (lex.spanned-token-buffer-release!)
  (let
    [source : String
      (str_cat.str-cat
        (scan-doubled-source "(atom 0x7b 'q' \"bytes\" 1.5)\n" 9)
        "\"unterminated")]
    [caller : i64 (arena.tl_arena_current)]
    [error-ok : bool
      (match (lex.spanned-result (& source))
        [(Ok _) false]
        [(Err err)
          (and
            (string.eq err.message "lexer: unterminated string literal")
            (= err.span.start-line 513)
            (= err.span.start-col 1))])]
    [empty-ok : bool
      (match (lex.spanned-result "")
        [(Err _) false]
        [(Ok tokens)
          (and
            (=
              (token.tag-ref
                (token.spanned-token-token-ref (& (array-ref tokens 0))))
              (token.tag-end))
            (= (token.spanned-token-line (array-ref tokens 0)) 1)
            (= (token.spanned-token-col (array-ref tokens 0)) 1))])]
    (lex.spanned-token-buffer-release!)
    (unless
      (and error-ok empty-ok (= (arena.tl_arena_current) caller))
      (io.panic
        "scan storage: post-growth lexer diagnostic or empty reuse failed"))))