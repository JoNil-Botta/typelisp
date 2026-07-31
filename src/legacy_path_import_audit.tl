;# Count executable legacy string-path imports without evaluating `cfg`.
;#
;# The repository ratchet needs to see declarations in every conditional branch,
;# while the compiler AST intentionally retains only the active branch. Walk the
;# reader forms at declaration positions instead: top level, module bodies,
;# `unsafe`, and recursively nested `cfg`. Reader strings and lexer comments are
;# atoms/non-tokens, so import-looking fixture text is not counted.
;#
;# A second, exemption-only pass descends quoted/generated forms to prove named
;# compatibility exemptions are still live. The shell gate removes those paths
;# before comparing ordinary executable counts.
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.test)
(import compiler_intern as ci)
(import lex as lexer)
(import read as reader)
(import token)

(defenum LegacyPathImportAuditResult
  (Ok i64)
  (Err String))

(define (legacy-path-import-audit-symbol?
  [form : reader.SpannedSexpr]
  [expected : String]) : bool
  (match (reader.spanned-sexpr-view form)
    [(reader.SpannedSexprView.Sym name _)
      (string.eq (ci.intern-str name) expected)]
    [_ false]))

(define (legacy-path-import-audit-decl-list [forms : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view forms)
    [(reader.SpannedSexprView.Nil _) 0]
    [(reader.SpannedSexprView.Cons form rest _)
      (+
        (legacy-path-import-audit-decl form)
        (legacy-path-import-audit-decl-list rest))]
    [_ 0]))

(define (legacy-path-import-audit-import [rest : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons path _ _)
      (match (reader.spanned-sexpr-view path)
        [(reader.SpannedSexprView.Str _ _) 1]
        [_ 0])]
    [_ 0]))

(define (legacy-path-import-audit-cfg [rest : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons _ after-predicate _)
      (match (reader.spanned-sexpr-view after-predicate)
        [(reader.SpannedSexprView.Cons decl _ _)
          (legacy-path-import-audit-decl decl)]
        [_ 0])]
    [_ 0]))

(define (legacy-path-import-audit-unsafe [rest : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons decl _ _)
      (legacy-path-import-audit-decl decl)]
    [_ 0]))

(define (legacy-path-import-audit-module [rest : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons _ body _)
      (legacy-path-import-audit-decl-list body)]
    [_ 0]))

(define (legacy-path-import-audit-decl [form : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view form)
    [(reader.SpannedSexprView.Cons head rest _)
      (cond
        [(legacy-path-import-audit-symbol? head "import")
          (legacy-path-import-audit-import rest)]
        [(legacy-path-import-audit-symbol? head "cfg")
          (legacy-path-import-audit-cfg rest)]
        [(legacy-path-import-audit-symbol? head "unsafe")
          (legacy-path-import-audit-unsafe rest)]
        [(legacy-path-import-audit-symbol? head "module")
          (legacy-path-import-audit-module rest)]
        [else 0])]
    [_ 0]))

(define (legacy-path-import-audit-any-form [form : reader.SpannedSexpr]) : i64
  (match (reader.spanned-sexpr-view form)
    [(reader.SpannedSexprView.Cons head rest _)
      (if (legacy-path-import-audit-symbol? head "import")
        (legacy-path-import-audit-import rest)
        (+
          (legacy-path-import-audit-any-form head)
          (legacy-path-import-audit-any-form rest)))]
    [(reader.SpannedSexprView.BracketList items _)
      (legacy-path-import-audit-any-form items)]
    [_ 0]))

(define (legacy-path-import-audit-forms
  [tokens : (__tl_dyn-array token.SpannedToken)]
  [cursor : (__tl_dyn-array i64)]
  [count : i64]
  [all-forms : bool]) : LegacyPathImportAuditResult
  (if (= (reader.peek-spanned-tag tokens cursor) (token.tag-end))
    (LegacyPathImportAuditResult.Ok count)
    (let
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.form-spanned-result tokens cursor)
        [(reader.ResultSpannedSexpr.Ok form)
          (let
            [next-count : i64
              (+
                count
                (if all-forms
                  (legacy-path-import-audit-any-form form)
                  (legacy-path-import-audit-decl form)))]
            (begin
              (reader.sp-node-pool-truncate! mark)
              (legacy-path-import-audit-forms
                tokens
                cursor
                next-count
                all-forms)))]
        [(reader.ResultSpannedSexpr.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (LegacyPathImportAuditResult.Err (token.source-error-message err)))]))))

(define (legacy-path-import-audit-source-with-mode
  [source : String]
  [all-forms : bool]) : LegacyPathImportAuditResult
  (begin
    (reader.sp-node-pool-reset!)
    (match (lexer.spanned-result source)
      [(lexer.ResultSpannedTokens.Ok tokens)
        (let
          [cursor : (__tl_dyn-array i64) (array.make-array i64 1)]
          (begin
            (array-set! cursor 0 0)
            (legacy-path-import-audit-forms tokens cursor 0 all-forms)))]
      [(lexer.ResultSpannedTokens.Err err)
        (LegacyPathImportAuditResult.Err (token.source-error-message err))])))

(define (legacy-path-import-audit-source [source : String]) : LegacyPathImportAuditResult
  (legacy-path-import-audit-source-with-mode source false))

(test
  legacy-path-import-audit-counts-cfg-declarations-only
  (let
    [source : String
      "(import \"top.tl\")
(cfg one-line (import \"one-line.tl\"))
(cfg expanded
  (import \"expanded.tl\"))
(cfg outer
  (cfg inner
    (import
      \"nested.tl\")))
(module sample
  (import \"module.tl\"))
(unsafe (import \"unsafe.tl\"))
(define fixture : String \"(import \\\"string-fixture.tl\\\")\")
;; (import \"comment-fixture.tl\")
(quote (import \"quoted-data.tl\"))"]
    (match (legacy-path-import-audit-source source)
      [(LegacyPathImportAuditResult.Ok count)
        (test.assert-true
          (= count 6)
          "audit should count declaration imports across cfg wrappers only")]
      [(LegacyPathImportAuditResult.Err message) (io.panic message)])))

(test
  legacy-path-import-audit-all-forms-supports-named-generated-fixtures
  (let
    [source : String
      "(define fixture : String \"(import \\\"string-fixture.tl\\\")\")
`(begin
  (import \"generated-fixture.tl\"))"]
    (match (legacy-path-import-audit-source-with-mode source true)
      [(LegacyPathImportAuditResult.Ok count)
        (test.assert-true
          (= count 1)
          "all-forms audit should see generated forms but not source strings")]
      [(LegacyPathImportAuditResult.Err message) (io.panic message)])))

(define (legacy-path-import-audit-file [path : String] [all-forms : bool]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file path))]
    (match (legacy-path-import-audit-source-with-mode source all-forms)
      [(LegacyPathImportAuditResult.Ok count)
        (begin
          (if (> count 0)
            (begin
              (io.print-string path)
              (io.print-string "\t")
              (io.print-string (string.int->string count))
              (io.print-newline))
            unit)
          0)]
      [(LegacyPathImportAuditResult.Err message)
        (begin
          (io.print-error
            (string.append
              (string.append "legacy path import audit failed for " path)
              (string.append ": " message)))
          1)])))

(define (legacy-path-import-audit-line-end [text : String] [start : i64]) : i64
  (let
    [index : i64 start]
    [limit : i64 (string.string-length text)]
    (begin
      (while (and
        (< index limit)
        (not (string.char-eq (string.string-ref text index) '\n')))
        (set! index (+ index 1)))
      index)))

(define (legacy-path-import-audit-file-list-at
  [text : String]
  [start : i64]
  [all-forms : bool]) : i64
  (let
    [limit : i64 (string.string-length text)]
    (if (>= start limit)
      0
      (let
        [line-end : i64 (legacy-path-import-audit-line-end text start)]
        [path-end : i64
          (if (and
            (> line-end start)
            (string.char-eq (string.string-ref text (- line-end 1)) '\r'))
            (- line-end 1)
            line-end)]
        [path : String (string.substring text start (- path-end start))]
        [next-start : i64
          (if (< line-end limit)
            (+ line-end 1)
            line-end)]
        [status : i64
          (if (string.eq path "")
            0
            (legacy-path-import-audit-file path all-forms))]
        (if (= status 0)
          (legacy-path-import-audit-file-list-at text next-start all-forms)
          status)))))

(define (main) : i64
  (if (or (= (io.arg-count) 2) (= (io.arg-count) 3))
    (let
      [list-path : String (io.arg 1)]
      [text : String (byte_buf.to-string (io.read-file list-path))]
      [ordinary-status : i64
        (legacy-path-import-audit-file-list-at text 0 false)]
      (if (and (= ordinary-status 0) (= (io.arg-count) 3))
        (let
          [exempt-list-path : String (io.arg 2)]
          [exempt-text : String
            (byte_buf.to-string (io.read-file exempt-list-path))]
          (legacy-path-import-audit-file-list-at exempt-text 0 true))
        ordinary-status))
    (begin
      (io.print-error
        "usage: legacy-path-import-audit <candidate-list> [exempt-list]")
      1)))