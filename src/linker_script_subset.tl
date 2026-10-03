;; The implicit GNU linker-script subset (#8303, the parser half of #7038's
;; leaf 4).
;;
;; Linux runtime profiles ship some `lib*.so` link inputs as tiny GNU ld scripts
;; rather than ELF files, glibc's `libc.so` among them:
;;
;;   /* GNU ld script ... */
;;   OUTPUT_FORMAT(elf64-x86-64)
;;   GROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a  AS_NEEDED ( /usr/lib/ld-linux-x86-64.so.2 ) )
;;
;; This module reads exactly that subset into ordered commands with line and
;; column provenance and rejects every other construct by name; no part of a
;; script is ever acted on here. Reading is pure: it touches no filesystem,
;; environment or network, and every allocation is bounded by
;; `LinkerScriptLimits`. Resolving the names against profile roots and emitting
;; the link manifest is #8304's.
;;
;; Grammar (tokens are separated by whitespace and `/* */` comments):
;;
;;   script  := command*
;;   command := "OUTPUT_FORMAT" "(" name ["," name "," name] ")"
;;            | ("INPUT" | "GROUP") "(" files ")"
;;            | "SEARCH_DIR" "(" name ")"
;;   files   := file ([","] file)*
;;   file    := "AS_NEEDED" "(" files ")" | name
;;   name    := word | quoted
;;   word    := printable ASCII except space ( ) , " ; { }, ending before "/*"
;;   quoted  := `"` (any byte except NUL, newline and `"`)* `"`
;;
;; Keywords are case-sensitive, as in GNU ld. An unquoted word `-lNAME` names a
;; library; every other name, and every quoted one, is a path. Commas and
;; whitespace both separate files, and order is kept exactly. Outside quotes a
;; byte must be printable ASCII or whitespace.
(import stdlib.byte_buf_core as bytes)
(import stdlib.str_cat_runtime as cat)
(import stdlib.string)
(import stdlib.vector)

;: Every bound the reader enforces. `max-depth` counts parentheses: a command's
;: own are depth 1, so the default admits AS_NEEDED nested three deep.
(defstruct LinkerScriptLimits
  (max-bytes i64)
  (max-tokens i64)
  (max-token-bytes i64)
  (max-depth i64))

;: Real profile scripts are a few hundred bytes; a token may be a full path.
(define (default-limits) : LinkerScriptLimits
  (LinkerScriptLimits 65536 4096 4096 4))

(defenum LinkerScriptInputKind
  (Path)
  (Library))

;: One file of an INPUT or GROUP list. `name` is the path as written (quotes
;: dropped), or NAME for an unquoted `-lNAME`. `as-needed` is set inside
;: AS_NEEDED at any depth. `line` and `column` are 1-based and locate the
;: token's first byte; columns count bytes.
(defstruct LinkerScriptInput
  (kind LinkerScriptInputKind)
  (name String)
  (quoted bool)
  (as-needed bool)
  (line i64)
  (column i64))

(import (vector.vector LinkerScriptInput) as input_vec)

;: OUTPUT_FORMAT names one BFD target, or three: the default, big-endian and
;: little-endian targets.
(defenum LinkerScriptCommand
  (OutputFormat String)
  (OutputFormatEndian String String String)
  ;; `first` and `count` select the command's files in `LinkerScript.inputs`.
  (Input i64 i64)
  (Group i64 i64)
  (SearchDir String))

;: A command with the line and column of its keyword.
(defstruct LinkerScriptItem
  (command LinkerScriptCommand)
  (line i64)
  (column i64))

(import (vector.vector LinkerScriptItem) as item_vec)

;: A read script: its commands in order, and every INPUT and GROUP file in
;: order, which the commands index.
(defstruct LinkerScript
  (items item_vec.Vec)
  (inputs input_vec.Vec))

;: Stable failure classes; the message adds the source, line, column and the
;: offending construct.
(defenum LinkerScriptErrorKind
  (InvalidLimits)
  (TooLarge)
  (TooManyTokens)
  (TokenTooLong)
  (TooDeep)
  (NulByte)
  (NonAscii)
  (ControlByte)
  (UnterminatedComment)
  (UnterminatedQuote)
  (UnbalancedParen)
  (UnsupportedCommand)
  (Assignment)
  (Expression)
  (UnknownCommand)
  (UnexpectedToken)
  (MissingParen)
  (EmptyArgument)
  (ArgumentCount)
  (EmptyLibrary)
  (Option))

(defstruct LinkerScriptError
  (kind LinkerScriptErrorKind)
  (line i64)
  (column i64)
  (message String))

(defenum ResultLinkerScript
  (Ok LinkerScript)
  (Err LinkerScriptError))

(define (script-error
  [source : (& s str)]
  [kind : LinkerScriptErrorKind]
  [line : i64]
  [column : i64]
  [detail : String]) : LinkerScriptError
  (LinkerScriptError
    kind
    line
    column
    (cat.str-cat
      (string.copy source)
      ":"
      (string.int->string line)
      ":"
      (string.int->string column)
      ": "
      detail)))

;; --- tokens -----------------------------------------------------------------
(defenum TokenKind
  (Word)
  (Quoted)
  (Open)
  (Close)
  (Comma)
  ;; `;`, `{` or `}`: the start of an expression, assignment or block.
  (Punct))

(defstruct Token
  (kind TokenKind)
  (text String)
  (line i64)
  (column i64))

(import (vector.vector Token) as token_vec)

(defenum ResultTokens
  (Ok token_vec.Vec)
  (Err LinkerScriptError))

(define (byte-at [data : (& d (__tl_dyn-array u8))] [index : i64]) : i64
  (cast (array-ref data index) : i64))

(define (space? [byte : i64]) : bool
  (or (= byte 32) (and (>= byte 9) (<= byte 13))))

;; A byte that ends a word without belonging to it.
(define (delimiter? [byte : i64]) : bool
  (or
    (space? byte)
    (= byte (cast '(' : i64))
    (= byte (cast ')' : i64))
    (= byte (cast ',' : i64))
    (= byte (cast '"' : i64))
    (= byte (cast ';' : i64))
    (= byte (cast '{' : i64))
    (= byte (cast '}' : i64))))

(define (comment-start?
  [data : (& d (__tl_dyn-array u8))]
  [index : i64]
  [size : i64]) : bool
  (and
    (< (+ index 1) size)
    (= (byte-at data index) (cast '/' : i64))
    (= (byte-at data (+ index 1)) (cast '*' : i64))))

;; The spelling of a single-byte token.
(define (punct-text [byte : i64]) : String
  (cond
    [(= byte (cast '(' : i64)) "("]
    [(= byte (cast ')' : i64)) ")"]
    [(= byte (cast ',' : i64)) ","]
    [(= byte (cast ';' : i64)) ";"]
    [(= byte (cast '{' : i64)) "{"]
    [else "}"]))

;; The scanner's position: byte offset, 1-based line and column.
(defstruct Cursor
  (pos i64)
  (line i64)
  (column i64))

(define (advance [cursor : Cursor] [byte : i64]) : Cursor
  (if (= byte 10)
    (Cursor (+ cursor.pos 1) (+ cursor.line 1) 1)
    (Cursor (+ cursor.pos 1) cursor.line (+ cursor.column 1))))

;; A check or parse step: nothing to return, or the error that stops reading.
(defenum Step
  (Ok)
  (Err LinkerScriptError))

(define (check-plain-byte [source : (& s str)] [byte : i64] [cursor : Cursor]) : Step
  (cond
    [(= byte 0)
      (Err (script-error source (NulByte) cursor.line cursor.column "NUL byte"))]
    [(>= byte 128)
      (Err
        (script-error
          source
          (NonAscii)
          cursor.line
          cursor.column
          "non-ASCII byte outside a quoted path"))]
    [(or (= byte 127) (and (< byte 32) (not (space? byte))))
      (Err
        (script-error
          source
          (ControlByte)
          cursor.line
          cursor.column
          (cat.str-cat "control byte " (string.int->string byte))))]
    [else (Ok)]))

(define (tokenize
  [source : (& s str)]
  [data : (& d (__tl_dyn-array u8))]
  [limits : (& l LinkerScriptLimits)]) : ResultTokens
  (let
    [size : i64 (array-length data)]
    [tokens : token_vec.Vec (token_vec.new)]
    [cursor : Cursor (Cursor 0 1 1)]
    [failure : LinkerScriptError (LinkerScriptError (InvalidLimits) 0 0 "")]
    [failed : bool false]
    (while (and (not failed) (< cursor.pos size))
      (let
        [byte : i64 (byte-at data cursor.pos)]
        (cond
          [(space? byte) (set! cursor (advance cursor byte))]
          [(comment-start? data cursor.pos size)
            (let
              [start : Cursor cursor]
              [closed : bool false]
              (set! cursor (advance (advance cursor byte) 42))
              (while (and (not closed) (not failed) (< cursor.pos size))
                (let
                  [inner : i64 (byte-at data cursor.pos)]
                  (cond
                    [(and
                      (= inner (cast '*' : i64))
                      (< (+ cursor.pos 1) size)
                      (= (byte-at data (+ cursor.pos 1)) (cast '/' : i64)))
                      (set! cursor (advance (advance cursor inner) 47))
                      (set! closed true)]
                    [else
                      (match (check-plain-byte source inner cursor)
                        [(Err error)
                          (set! failed true)
                          (set! failure error)]
                        [(Ok) (set! cursor (advance cursor inner))])])))
              (when
                (and (not failed) (not closed))
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (UnterminatedComment)
                    start.line
                    start.column
                    "unterminated comment"))))]
          [else
            (if (>= (token_vec.len (& tokens)) limits.max-tokens)
              (begin
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (TooManyTokens)
                    cursor.line
                    cursor.column
                    (cat.str-cat
                      "more than "
                      (string.int->string limits.max-tokens)
                      " tokens"))))
              (let
                [start : Cursor cursor]
                (cond
                  [(= byte (cast '"' : i64))
                    (let
                      [text : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
                      [closed : bool false]
                      (set! cursor (advance cursor byte))
                      (while (and (not closed) (not failed) (< cursor.pos size))
                        (let
                          [inner : i64 (byte-at data cursor.pos)]
                          (cond
                            [(= inner (cast '"' : i64))
                              (set! cursor (advance cursor inner))
                              (set! closed true)]
                            [(= inner 0)
                              (set! failed true)
                              (set!
                                failure
                                (script-error
                                  source
                                  (NulByte)
                                  cursor.line
                                  cursor.column
                                  "NUL byte"))]
                            [(= inner 10) (set! cursor (Cursor size 0 0))]
                            [(>=
                              (bytes.byte-buf-builder-len (& text))
                              limits.max-token-bytes)
                              (set! failed true)
                              (set!
                                failure
                                (script-error
                                  source
                                  (TokenTooLong)
                                  start.line
                                  start.column
                                  (cat.str-cat
                                    "quoted name exceeds "
                                    (string.int->string limits.max-token-bytes)
                                    " bytes")))]
                            [else
                              (bytes.byte-buf-builder-push
                                (&mut text)
                                (cast inner : u8))
                              (set! cursor (advance cursor inner))])))
                      (cond
                        [failed unit]
                        [closed
                          (token_vec.push-ref!
                            (&mut tokens)
                            (Token
                              (Quoted)
                              (bytes.byte-buf-builder-to-string (& text))
                              start.line
                              start.column))]
                        [else
                          (set! failed true)
                          (set!
                            failure
                            (script-error
                              source
                              (UnterminatedQuote)
                              start.line
                              start.column
                              "unterminated quote"))]))]
                  [(or
                    (= byte (cast '(' : i64))
                    (= byte (cast ')' : i64))
                    (= byte (cast ',' : i64))
                    (= byte (cast ';' : i64))
                    (= byte (cast '{' : i64))
                    (= byte (cast '}' : i64)))
                    (token_vec.push-ref!
                      (&mut tokens)
                      (Token
                        (cond
                          [(= byte (cast '(' : i64)) (Open)]
                          [(= byte (cast ')' : i64)) (Close)]
                          [(= byte (cast ',' : i64)) (Comma)]
                          [else (Punct)])
                        (punct-text byte)
                        start.line
                        start.column))
                    (set! cursor (advance cursor byte))]
                  [else
                    (let
                      [text : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
                      [done : bool false]
                      (while (and (not done) (not failed) (< cursor.pos size))
                        (let
                          [inner : i64 (byte-at data cursor.pos)]
                          (if (or
                            (delimiter? inner)
                            (comment-start? data cursor.pos size))
                            (set! done true)
                            (match (check-plain-byte source inner cursor)
                              [(Err error)
                                (set! failed true)
                                (set! failure error)]
                              [(Ok)
                                (if (>=
                                  (bytes.byte-buf-builder-len (& text))
                                  limits.max-token-bytes)
                                  (begin
                                    (set! failed true)
                                    (set!
                                      failure
                                      (script-error
                                        source
                                        (TokenTooLong)
                                        start.line
                                        start.column
                                        (cat.str-cat
                                          "name exceeds "
                                          (string.int->string
                                            limits.max-token-bytes)
                                          " bytes"))))
                                  (begin
                                    (bytes.byte-buf-builder-push
                                      (&mut text)
                                      (cast inner : u8))
                                    (set! cursor (advance cursor inner))))]))))
                      (unless
                        failed
                        (token_vec.push-ref!
                          (&mut tokens)
                          (Token
                            (Word)
                            (bytes.byte-buf-builder-to-string (& text))
                            start.line
                            start.column))))])))])))
    (if failed
      (Err failure)
      (Ok tokens))))

;; --- commands ---------------------------------------------------------------
;; GNU ld commands and constructs outside the subset, named in the diagnostic so
;; a reader sees which part of the script was refused.
(define (unsupported-command? [word : (& w str)]) : bool
  (or
    (string.eq word "SECTIONS")
    (string.eq word "MEMORY")
    (string.eq word "PHDRS")
    (string.eq word "INCLUDE")
    (string.eq word "INSERT")
    (string.eq word "PROVIDE")
    (string.eq word "PROVIDE_HIDDEN")
    (string.eq word "HIDDEN")
    (string.eq word "ENTRY")
    (string.eq word "OUTPUT")
    (string.eq word "OUTPUT_ARCH")
    (string.eq word "TARGET")
    (string.eq word "STARTUP")
    (string.eq word "EXTERN")
    (string.eq word "ASSERT")
    (string.eq word "VERSION")
    (string.eq word "NOCROSSREFS")
    (string.eq word "NOCROSSREFS_TO")
    (string.eq word "REGION_ALIAS")
    (string.eq word "FORCE_COMMON_ALLOCATION")
    (string.eq word "INHIBIT_COMMON_ALLOCATION")
    (string.eq word "FORCE_GROUP_ALLOCATION")
    (string.eq word "LD_FEATURE")))

;; A word that can only begin an expression: a GNU ld builtin function, a
;; number, the location counter or an operator.
(define (expression-word? [word : (& w str)]) : bool
  (let
    [first : i64 (cast (string.string-ref word 0) : i64)]
    (or
      (and (>= first (cast '0' : i64)) (<= first (cast '9' : i64)))
      (contains-byte? ".+-*/%<>&|!~?:" first)
      (string.eq word "ABSOLUTE")
      (string.eq word "ADDR")
      (string.eq word "ALIGN")
      (string.eq word "ALIGNOF")
      (string.eq word "BLOCK")
      (string.eq word "CONSTANT")
      (string.eq word "DATA_SEGMENT_ALIGN")
      (string.eq word "DATA_SEGMENT_END")
      (string.eq word "DATA_SEGMENT_RELRO_END")
      (string.eq word "DEFINED")
      (string.eq word "LENGTH")
      (string.eq word "LOADADDR")
      (string.eq word "LOG2CEIL")
      (string.eq word "MAX")
      (string.eq word "MIN")
      (string.eq word "NEXT")
      (string.eq word "ORIGIN")
      (string.eq word "SEGMENT_START")
      (string.eq word "SIZEOF")
      (string.eq word "SIZEOF_HEADERS"))))

(define (contains-byte? [text : (& t str)] [byte : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index (string.string-length text)))
      (when
        (= (cast (string.string-ref text index) : i64) byte)
        (set! found true))
      (set! index (+ index 1)))
    found))

(define (starts-with? [text : (& t str)] [prefix : (& p str)]) : bool
  (and
    (>= (string.string-length text) (string.string-length prefix))
    (string.eq (string.substring text 0 (string.string-length prefix)) prefix)))

;; The parser's state: the token stream, the next index and the files read.
(defstruct Parser
  (tokens token_vec.Vec)
  (index i64)
  (inputs input_vec.Vec))

(define (token-count [parser : (& p Parser)]) : i64
  (token_vec.len (& parser.tokens)))

(define (token-at [parser : (& p Parser)] [index : i64]) : (& p Token)
  (& (array-ref parser.tokens.slots index)))

(define (token-kind-at [parser : (& p Parser)] [index : i64]) : TokenKind
  (let
    [token : (& p Token) (token-at parser index)]
    (match token.kind
      [(Word) (Word)]
      [(Quoted) (Quoted)]
      [(Open) (Open)]
      [(Close) (Close)]
      [(Comma) (Comma)]
      [(Punct) (Punct)])))

(define (token-has-byte? [parser : (& p Parser)] [index : i64] [byte : i64]) : bool
  (let
    [token : (& p Token) (token-at parser index)]
    (contains-byte? token.text byte)))

(define (token-copy-at [parser : (& p Parser)] [index : i64]) : Token
  (let
    [token : (& p Token) (token-at parser index)]
    (Token
      (token-kind-at parser index)
      (string.copy token.text)
      token.line
      token.column)))

(defenum ResultName
  (Ok String)
  (Err LinkerScriptError))

(define (end-of-script-error
  [source : (& s str)]
  [parser : (& p Parser)]
  [kind : LinkerScriptErrorKind]
  [detail : String]) : LinkerScriptError
  (if (> (token-count parser) 0)
    (let
      [last : (& p Token) (token-at parser (- (token-count parser) 1))]
      (script-error source kind last.line last.column detail))
    (script-error source kind 1 1 detail)))

;; Expect `(` after the keyword `keyword`.
(define (expect-open
  [source : (& s str)]
  [parser : (&mut p Parser)]
  [keyword : (& k Token)]) : Step
  (if (and
    (< parser.index (token-count parser))
    (match (token-kind-at parser parser.index)
      [(Open) true]
      [_ false]))
    (begin
      (set! parser.index (+ parser.index 1))
      (Ok))
    (Err
      (script-error
        source
        (MissingParen)
        keyword.line
        keyword.column
        (cat.str-cat (string.copy keyword.text) " without its `(`")))))

;; The files of an INPUT, GROUP or AS_NEEDED list up to its `)`, which is
;; consumed. `depth` is the list's own parenthesis depth.
(define (parse-files
  [source : (& s str)]
  [parser : (&mut p Parser)]
  [limits : (& l LinkerScriptLimits)]
  [depth : i64]
  [as-needed : bool]) : Step
  (let
    [listed : i64 0]
    [separated : bool true]
    [closed : bool false]
    [failure : LinkerScriptError (LinkerScriptError (InvalidLimits) 0 0 "")]
    [failed : bool false]
    (while (and (not closed) (not failed) (< parser.index (token-count parser)))
      (let
        [token : Token (token-copy-at parser parser.index)]
        (set! parser.index (+ parser.index 1))
        (match token.kind
          [(Close)
            (if (and (= listed 0) separated)
              (begin
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (EmptyArgument)
                    token.line
                    token.column
                    "empty file list")))
              (set! closed true))]
          [(Comma)
            (if separated
              (begin
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (EmptyArgument)
                    token.line
                    token.column
                    "empty entry before `,`")))
              (set! separated true))]
          [(Quoted)
            (if (= (string.string-length token.text) 0)
              (begin
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (EmptyArgument)
                    token.line
                    token.column
                    "empty quoted name")))
              (begin
                (input_vec.push-ref!
                  (&mut parser.inputs)
                  (LinkerScriptInput
                    (Path)
                    (string.copy token.text)
                    true
                    as-needed
                    token.line
                    token.column))
                (set! listed (+ listed 1))
                (set! separated false)))]
          [(Word)
            (cond
              [(string.eq token.text "AS_NEEDED")
                (cond
                  [(>= depth limits.max-depth)
                    (set! failed true)
                    (set!
                      failure
                      (script-error
                        source
                        (TooDeep)
                        token.line
                        token.column
                        (cat.str-cat
                          "AS_NEEDED nests deeper than "
                          (string.int->string limits.max-depth)
                          " parentheses")))]
                  [else
                    (match (expect-open source parser (& token))
                      [(Err error)
                        (set! failed true)
                        (set! failure error)]
                      [(Ok)
                        (match (parse-files
                          source
                          parser
                          limits
                          (+ depth 1)
                          true)
                          [(Err error)
                            (set! failed true)
                            (set! failure error)]
                          [(Ok)
                            (set! listed (+ listed 1))
                            (set! separated false)])])])]
              [(starts-with? token.text "-l")
                (if (= (string.string-length token.text) 2)
                  (begin
                    (set! failed true)
                    (set!
                      failure
                      (script-error
                        source
                        (EmptyLibrary)
                        token.line
                        token.column
                        "`-l` without a library name")))
                  (begin
                    (input_vec.push-ref!
                      (&mut parser.inputs)
                      (LinkerScriptInput
                        (Library)
                        (string.substring
                          token.text
                          2
                          (- (string.string-length token.text) 2))
                        false
                        as-needed
                        token.line
                        token.column))
                    (set! listed (+ listed 1))
                    (set! separated false)))]
              [(starts-with? token.text "-")
                (set! failed true)
                (set!
                  failure
                  (script-error
                    source
                    (Option)
                    token.line
                    token.column
                    (cat.str-cat
                      "option `"
                      (string.copy token.text)
                      "` in a file list; only `-lNAME` is admitted")))]
              [else
                (input_vec.push-ref!
                  (&mut parser.inputs)
                  (LinkerScriptInput
                    (Path)
                    (string.copy token.text)
                    false
                    as-needed
                    token.line
                    token.column))
                (set! listed (+ listed 1))
                (set! separated false)])]
          [(Open)
            (set! failed true)
            (set!
              failure
              (script-error
                source
                (UnbalancedParen)
                token.line
                token.column
                "`(` without AS_NEEDED before it"))]
          [(Punct)
            (set! failed true)
            (set!
              failure
              (script-error
                source
                (UnexpectedToken)
                token.line
                token.column
                (cat.str-cat "`" (string.copy token.text) "` in a file list")))])))
    (cond
      [failed (Err failure)]
      [closed (Ok)]
      [else
        (Err
          (end-of-script-error
            source
            parser
            (UnbalancedParen)
            "file list without its `)`"))])))

;; One name for OUTPUT_FORMAT or SEARCH_DIR.
(define (parse-name
  [source : (& s str)]
  [parser : (&mut p Parser)]
  [keyword : (& k Token)]) : ResultName
  (if (>= parser.index (token-count parser))
    (Err
      (end-of-script-error
        source
        parser
        (UnbalancedParen)
        (cat.str-cat (string.copy keyword.text) " without its `)`")))
    (let
      [token : Token (token-copy-at parser parser.index)]
      (match token.kind
        [(Word)
          (set! parser.index (+ parser.index 1))
          (Ok (string.copy token.text))]
        [(Quoted)
          (if (= (string.string-length token.text) 0)
            (Err
              (script-error
                source
                (EmptyArgument)
                token.line
                token.column
                "empty quoted name"))
            (begin
              (set! parser.index (+ parser.index 1))
              (Ok (string.copy token.text))))]
        [_
          (Err
            (script-error
              source
              (ArgumentCount)
              token.line
              token.column
              (cat.str-cat
                (string.copy keyword.text)
                " expects a name, not `"
                (string.copy token.text)
                "`")))]))))

;; Consume the token at the cursor when it has `kind`.
(define (accept? [parser : (&mut p Parser)] [comma? : bool]) : bool
  (if (and
    (< parser.index (token-count parser))
    (match (token-kind-at parser parser.index)
      [(Comma) comma?]
      [(Close) (not comma?)]
      [_ false]))
    (begin
      (set! parser.index (+ parser.index 1))
      true)
    false))

(defenum ResultCommand
  (Ok LinkerScriptCommand)
  (Err LinkerScriptError))

(define (close-error
  [source : (& s str)]
  [parser : (& p Parser)]
  [keyword : (& k Token)]) : LinkerScriptError
  (if (< parser.index (token-count parser))
    (let
      [token : (& p Token) (token-at parser parser.index)]
      (script-error
        source
        (ArgumentCount)
        token.line
        token.column
        (cat.str-cat
          (string.copy keyword.text)
          " takes "
          (if (string.eq keyword.text "OUTPUT_FORMAT")
            "one or three names"
            "one name")
          "; found `"
          (string.copy token.text)
          "`")))
    (end-of-script-error
      source
      parser
      (UnbalancedParen)
      (cat.str-cat (string.copy keyword.text) " without its `)`"))))

(define (parse-output-format
  [source : (& s str)]
  [parser : (&mut p Parser)]
  [keyword : (& k Token)]) : ResultCommand
  (let
    [names : (__tl_dyn-array String) (__tl_make-array String 3)]
    [count : i64 0]
    [failure : LinkerScriptError (LinkerScriptError (InvalidLimits) 0 0 "")]
    [failed : bool false]
    [done : bool false]
    (while (and (not failed) (not done))
      (match (parse-name source parser keyword)
        [(Err error)
          (set! failed true)
          (set! failure error)]
        [(Ok name)
          (set! (array-ref names count) name)
          (set! count (+ count 1))
          (cond
            [(accept? parser false) (set! done true)]
            [(and (< count 3) (accept? parser true)) unit]
            [else
              (set! failed true)
              (set! failure (close-error source parser keyword))])]))
    (cond
      [failed (Err failure)]
      [(= count 2)
        (Err
          (script-error
            source
            (ArgumentCount)
            keyword.line
            keyword.column
            "OUTPUT_FORMAT takes one or three names, not two"))]
      [(= count 1) (Ok (OutputFormat (string.copy (array-ref names 0))))]
      [else
        (Ok
          (OutputFormatEndian
            (string.copy (array-ref names 0))
            (string.copy (array-ref names 1))
            (string.copy (array-ref names 2))))])))

(define (parse-search-dir
  [source : (& s str)]
  [parser : (&mut p Parser)]
  [keyword : (& k Token)]) : ResultCommand
  (let
    [name (try (parse-name source parser keyword))]
    (if (accept? parser false)
      (Ok (SearchDir name))
      (Err (close-error source parser keyword)))))

;; The diagnostic for a top-level word that is not one of the subset's commands.
(define (refused-word-error
  [source : (& s str)]
  [parser : (& p Parser)]
  [word : (& w Token)]) : LinkerScriptError
  (cond
    [(string.eq word.text "AS_NEEDED")
      (script-error
        source
        (UnexpectedToken)
        word.line
        word.column
        "AS_NEEDED outside INPUT or GROUP")]
    [(or
        (contains-byte? word.text (cast '=' : i64))
        (and
          (< parser.index (token-count parser))
          (match (token-kind-at parser parser.index)
            [(Word) (token-has-byte? parser parser.index 61)]
            [_ false])))
      (script-error
        source
        (Assignment)
        word.line
        word.column
        (cat.str-cat
          "assignment to `"
          (string.copy word.text)
          "` is not part of the admitted subset"))]
    [(expression-word? word.text)
      (script-error
        source
        (Expression)
        word.line
        word.column
        (cat.str-cat
          "expression `"
          (string.copy word.text)
          "` is not part of the admitted subset"))]
    [(unsupported-command? word.text)
      (script-error
        source
        (UnsupportedCommand)
        word.line
        word.column
        (cat.str-cat
          (string.copy word.text)
          " is not part of the admitted subset (OUTPUT_FORMAT, INPUT, GROUP, AS_NEEDED, SEARCH_DIR)"))]
    [else
      (script-error
        source
        (UnknownCommand)
        word.line
        word.column
        (cat.str-cat "unknown command `" (string.copy word.text) "`"))]))

(define (parse-tokens
  [source : (& s str)]
  [tokens : token_vec.Vec]
  [limits : (& l LinkerScriptLimits)]) : ResultLinkerScript
  (let
    [parser : Parser (Parser tokens 0 (input_vec.new))]
    [items : item_vec.Vec (item_vec.new)]
    [failure : LinkerScriptError (LinkerScriptError (InvalidLimits) 0 0 "")]
    [failed : bool false]
    (while (and (not failed) (< parser.index (token-count (& parser))))
      (let
        [token : Token (token-copy-at (& parser) parser.index)]
        (set! parser.index (+ parser.index 1))
        (let
          [result : ResultCommand
            (match token.kind
              [(Word)
                (cond
                  [(or
                      (string.eq token.text "OUTPUT_FORMAT")
                      (string.eq token.text "INPUT")
                      (string.eq token.text "GROUP")
                      (string.eq token.text "SEARCH_DIR"))
                    (match (expect-open source (&mut parser) (& token))
                      [(Err error) (Err error)]
                      [(Ok)
                        (cond
                          [(string.eq token.text "OUTPUT_FORMAT")
                            (parse-output-format source (&mut parser) (& token))]
                          [(string.eq token.text "SEARCH_DIR")
                            (parse-search-dir source (&mut parser) (& token))]
                          [else
                            (let
                              [first : i64 (input_vec.len (& parser.inputs))]
                              (match (parse-files
                                source
                                (&mut parser)
                                limits
                                1
                                false)
                                [(Err error) (Err error)]
                                [(Ok)
                                  (let
                                    [count : i64
                                      (-
                                        (input_vec.len (& parser.inputs))
                                        first)]
                                    (Ok
                                      (if (string.eq token.text "INPUT")
                                        (Input first count)
                                        (Group first count))))]))])])]
                  [else (Err (refused-word-error source (& parser) (& token)))])]
              [(Close)
                (Err
                  (script-error
                    source
                    (UnbalancedParen)
                    token.line
                    token.column
                    "`)` without its `(`"))]
              [_
                (Err
                  (script-error
                    source
                    (UnexpectedToken)
                    token.line
                    token.column
                    (cat.str-cat
                      "`"
                      (string.copy token.text)
                      "` where a command is expected")))])]
          (match result
            [(Err error)
              (set! failed true)
              (set! failure error)]
            [(Ok command)
              (item_vec.push-ref!
                (&mut items)
                (LinkerScriptItem command token.line token.column))]))))
    (if failed
      (Err failure)
      (Ok (LinkerScript items parser.inputs)))))

;: Read `data`, the bytes of a linker-script input named `source` in
;: diagnostics, into its ordered commands. Every limit must be positive.
(define (read-linker-script
  [source : (& s str)]
  [data : (& d (__tl_dyn-array u8))]
  [limits : (& l LinkerScriptLimits)]) : ResultLinkerScript
  (cond
    [(or
        (<= limits.max-bytes 0)
        (<= limits.max-tokens 0)
        (<= limits.max-token-bytes 0)
        (<= limits.max-depth 0))
      (Err
        (script-error
          source
          (InvalidLimits)
          0
          0
          "every linker-script limit must be positive"))]
    [(> (array-length data) limits.max-bytes)
      (Err
        (script-error
          source
          (TooLarge)
          1
          1
          (cat.str-cat
            "script of "
            (string.int->string (array-length data))
            " bytes exceeds "
            (string.int->string limits.max-bytes))))]
    [else
      (let
        [tokens (try (tokenize source data limits))]
        (parse-tokens source tokens limits))]))