;; Bounded exact-name VERSION maps for #8263, #8293 and #7042. The shared
;; linker-script scanner owns comments, quotes, byte limits and provenance.
(import stdlib.iterator)
(import linker_script_subset as script)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.vector)
(import (vector.vector script.Token) as token_vec)

(defstruct VersionMapLimits
  ;; max-bytes also caps the source label copied into a diagnostic.
  (lex script.LinkerScriptLimits)
  (max-nodes i64)
  (max-symbols i64)
  (max-work i64))

(define (default-limits) : VersionMapLimits
  (VersionMapLimits (script.default-limits) 256 4096 1048576))

(defstruct VersionSymbol
  (name String)
  (global bool)
  (line i64)
  (column i64))

(import (vector.vector VersionSymbol core) as symbol_vec)

;; parent=-1 means no inheritance; an empty name denotes the anonymous node.
;; Symbol order includes both scopes. The catch-all is not a bound exact name.
(defstruct VersionNode
  (name String)
  (parent i64)
  (symbols symbol_vec.Vec)
  (local-all bool)
  (line i64)
  (column i64))

(import (vector.vector VersionNode core) as node_vec)

(defstruct VersionMapError
  (line i64)
  (column i64)
  (message String))

(defenum VersionMapResult
  (Ok node_vec.Vec)
  (Err VersionMapError))

(defstruct VersionMapParser
  (:lifetimes source)
  (source (& source str))
  (tokens token_vec.Vec)
  (index i64)
  (eof-line i64)
  (eof-column i64)
  (left i64)
  (ok bool)
  (error VersionMapError))

(define (fail! [parser : (&mut p (VersionMapParser s))] [detail : String]) : unit
  (when
    parser.ok
    (let
      [line : i64 parser.eof-line]
      [column : i64 parser.eof-column]
      (when
        (< parser.index parser.tokens.len)
        (set! line (array-ref parser.tokens.slots parser.index).line)
        (set! column (array-ref parser.tokens.slots parser.index).column))
      (set! parser.ok false)
      (set!
        parser.error
        (VersionMapError
          line
          column
          (cat.str-cat
            (string.copy parser.source)
            ":"
            (string.int->string line)
            ":"
            (string.int->string column)
            ": "
            detail))))))

(define (charge! [parser : (&mut p (VersionMapParser s))] [work : i64]) : unit
  (if (> work parser.left)
    (fail! parser "version-map work limit exceeded")
    (-= parser.left work)))

(define (is? [parser : (& p (VersionMapParser s))] [text : (& t str)]) : bool
  (and
    (< parser.index parser.tokens.len)
    (match (array-ref parser.tokens.slots parser.index).kind
      [(Quoted) false]
      [_ true])
    (string.eq (array-ref parser.tokens.slots parser.index).text text)))

(define (expect! [parser : (&mut p (VersionMapParser s))] [text : (& t str)]) : unit
  (if (is? parser text)
    (+= parser.index 1)
    (fail!
      parser
      (if (< parser.index parser.tokens.len)
        (cat.str-cat
          "unsupported construct '"
          (string.copy (array-ref parser.tokens.slots parser.index).text)
          "'; expected '"
          (string.copy text)
          "'")
        (cat.str-cat "expected '" (string.copy text) "'")))))

;; Exact names admit the assembler/C-export spelling characters. Glob and
;; expression operators are rejected even inside quotes; quotes only delimit.
(define (name! [parser : (&mut p (VersionMapParser s))]) : String
  (let
    [name : String ""]
    (cond
      [(>= parser.index parser.tokens.len) (fail! parser "expected exact name")]
      [(is? parser "extern") (fail! parser "unsupported extern language block")]
      [else
        (let
          [token : (& p script.Token)
            (& (array-ref parser.tokens.slots parser.index))]
          [valid : bool
            (match token.kind
              [(Word) true]
              [(Quoted) true]
              [_ false])]
          [i : i64 0]
          [glob : bool false]
          (while (and valid (< i (string.string-length token.text)))
            (let
              [b : i64 (cast (string.string-ref token.text i) : i64)]
              (set! glob (or glob (= b 42) (= b 63) (= b 91) (= b 93)))
              (set!
                valid
                (or
                  (and (>= b 65) (<= b 90))
                  (and (>= b 97) (<= b 122))
                  (and (>= b 48) (<= b 57))
                  (= b 95)
                  (= b 46)
                  (= b 36)
                  (= b 45))))
            (+= i 1))
          (cond
            [(and valid (> (string.string-length token.text) 0))
              (set! name (string.copy token.text))]
            [glob
              (fail!
                parser
                "unsupported glob pattern (only local: * is supported)")]
            [else
              (fail!
                parser
                "unsupported expression or construct; expected exact name")]))])
    (when parser.ok (+= parser.index 1))
    name))

(define (same-name?
  [parser : (&mut p (VersionMapParser s))]
  [a : (& a str)]
  [b : (& b str)]) : bool
  (charge! parser (+ (string.string-length a) (string.string-length b)))
  (and parser.ok (string.eq a b)))

(define (check-symbols!
  [parser : (&mut p (VersionMapParser s))]
  [symbols : (& q symbol_vec.Vec)]
  [name : (& a str)]) : unit
  (let
    [j : i64 0]
    (while (and parser.ok (< j symbols.len))
      (when
        (same-name? parser name (array-ref symbols.slots j).name)
        (fail!
          parser
          (cat.str-cat "duplicate bound name '" (string.copy name) "'")))
      (+= j 1))))

(define (check-symbol!
  [parser : (&mut p (VersionMapParser s))]
  [nodes : (& n node_vec.Vec)]
  [node : (& v VersionNode)]
  [name : (& a str)]) : unit
  (let
    [i : i64 0]
    (while (and parser.ok (< i nodes.len))
      (check-symbols! parser (& (array-ref nodes.slots i).symbols) name)
      (+= i 1)))
  (check-symbols! parser (& node.symbols) name))

(define (parse-node!
  [parser : (&mut p (VersionMapParser s))]
  [nodes : (& n node_vec.Vec)]
  [limits : (& l VersionMapLimits)]
  [total : (&mut t i64)]) : VersionNode
  (let
    [line : i64 (array-ref parser.tokens.slots parser.index).line]
    [column : i64 (array-ref parser.tokens.slots parser.index).column]
    [anonymous : bool (is? parser "{")]
    [node : VersionNode
      (VersionNode
        (if anonymous
          ""
          (name! parser))
        -1
        (symbol_vec.new)
        false
        line
        column)]
    [scope : i64 0]
    [seen-global : bool false]
    [seen-local : bool false]
    (when
      (and anonymous (> nodes.len 0))
      (fail! parser "anonymous version node must be the only node"))
    (expect! parser "{")
    (while (and parser.ok (not (is? parser "}")))
      (cond
        [(and
            (or (is? parser "global") (is? parser "local"))
            (< (+ parser.index 1) parser.tokens.len)
            (string.eq
              (array-ref parser.tokens.slots (+ parser.index 1)).text
              ":"))
          (let
            [global : bool (is? parser "global")]
            (when
              (if global
                seen-global
                seen-local)
              (fail! parser "duplicate global/local scope"))
            (set! seen-global (or seen-global global))
            (set! seen-local (or seen-local (not global)))
            (set!
              scope
              (if global
                1
                2))
            (+= parser.index 1)
            (expect! parser ":"))]
        [(is? parser "*")
          (cond
            [(not (= scope 2))
              (fail! parser "unsupported glob '*' outside local scope")]
            [node.local-all (fail! parser "duplicate local catch-all")]
            [else (set! node.local-all true)])
          (+= parser.index 1)
          (expect! parser ";")]
        [else
          (when
            (is? parser "extern")
            (fail! parser "unsupported extern language block"))
          (when (= scope 0) (fail! parser "expected global: or local: scope"))
          (when
            (>= (deref total) limits.max-symbols)
            (fail! parser "version-map symbol limit exceeded"))
          (when
            parser.ok
            (let
              [symbol-line : i64 parser.eof-line]
              [symbol-column : i64 parser.eof-column]
              (when
                (< parser.index parser.tokens.len)
                (set!
                  symbol-line
                  (array-ref parser.tokens.slots parser.index).line)
                (set!
                  symbol-column
                  (array-ref parser.tokens.slots parser.index).column))
              (let
                [start : i64 parser.index]
                [name : String (name! parser)]
                [after : i64 parser.index]
                (set! parser.index start)
                (check-symbol! parser nodes (& node) name)
                (when parser.ok (set! parser.index after))
                (when
                  parser.ok
                  (symbol_vec.push-ref!
                    (&mut node.symbols)
                    (VersionSymbol name (= scope 1) symbol-line symbol-column))
                  (set! (deref total) (+ (deref total) 1))))
              (expect! parser ";")))]))
    (expect! parser "}")
    (when
      (and parser.ok (not (is? parser ";")))
      (let
        [start : i64 parser.index]
        [parent : String (name! parser)]
        [i : i64 0]
        (when anonymous (fail! parser "anonymous version node cannot inherit"))
        (while (and parser.ok (< i nodes.len))
          (when
            (same-name? parser parent (array-ref nodes.slots i).name)
            (set! node.parent i))
          (+= i 1))
        (when
          (and parser.ok (= node.parent -1))
          (set! parser.index start)
          (fail! parser (cat.str-cat "unknown or forward parent '" parent "'")))))
    (expect! parser ";")
    node))

(define (parse
  [source : (& s str)]
  [data : (& d (__tl_dyn-array u8))]
  [limits : (& l VersionMapLimits)]) : VersionMapResult
  (cond
    [(or
        (<= limits.lex.max-bytes 0)
        (<= limits.lex.max-tokens 0)
        (<= limits.lex.max-token-bytes 0)
        (<= limits.lex.max-depth 0)
        (< limits.max-nodes 0)
        (< limits.max-symbols 0)
        (< limits.max-work 0))
      (Err (VersionMapError 1 1 "invalid version-map limits"))]
    [(> (array-length data) limits.lex.max-bytes)
      (Err (VersionMapError 1 1 "version-map byte limit exceeded"))]
    [(> (string.string-length source) limits.lex.max-bytes)
      (Err (VersionMapError 1 1 "version-map source-label limit exceeded"))]
    [(> (array-length data) (/ limits.max-work 3))
      (Err (VersionMapError 1 1 "version-map work limit exceeded"))]
    [else
      (let
        [request : (script.ScriptTokenRequest s d l)
          (script.ScriptTokenRequest source data (& limits.lex) true)]
        (match (script.tokenize (& request))
          [(Err error)
            (Err
              (VersionMapError
                error.line
                error.column
                (string.copy error.message)))]
          [(Ok tokens)
            (let
              [line : i64 1]
              [column : i64 1]
              [nodes : node_vec.Vec (node_vec.new)]
              [total : i64 0]
              (for [i (iterator.range 0 (array-length data))]
                (if (= (array-ref data i) (cast 10 : u8))
                  (begin
                    (+= line 1)
                    (set! column 1))
                  (+= column 1)))
              (let
                [parser : (VersionMapParser s)
                  (VersionMapParser
                    source
                    tokens
                    0
                    line
                    column
                    (- limits.max-work (* (array-length data) 3))
                    true
                    (VersionMapError 0 0 ""))]
                (while (and parser.ok (< parser.index parser.tokens.len))
                  (cond
                    [(>= nodes.len limits.max-nodes)
                      (fail! (&mut parser) "version-map node limit exceeded")]
                    [(and
                        (> nodes.len 0)
                        (string.eq (array-ref nodes.slots 0).name ""))
                      (fail!
                        (&mut parser)
                        "anonymous version node must be the only node")]
                    [else
                      (let
                        [start : i64 parser.index]
                        [node : VersionNode
                          (parse-node!
                            (&mut parser)
                            (& nodes)
                            limits
                            (&mut total))]
                        [j : i64 0]
                        (while (and parser.ok (< j nodes.len))
                          (when
                            (same-name?
                              (&mut parser)
                              node.name
                              (array-ref nodes.slots j).name)
                            (set! parser.index start)
                            (fail!
                              (&mut parser)
                              (cat.str-cat
                                "duplicate version node '"
                                (string.copy node.name)
                                "'")))
                          (+= j 1))
                        (when parser.ok (node_vec.push-ref! (&mut nodes) node)))]))
                (when
                  (= nodes.len 0)
                  (fail! (&mut parser) "expected version node"))
                (if parser.ok
                  (Ok nodes)
                  (Err parser.error))))]))]))