(import stdlib.iterator)
(import linker_version_map as map)
(import stdlib.byte_buf_core as bytes)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)

(define (assert [ok : bool] [message : String]) : unit
  (unless ok (io.panic message)))

(define (bytes-of [text : (& t str)]) : (__tl_dyn-array u8)
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    (bytes.byte-buf-builder-append-string (&mut out) (string.copy text))
    (bytes.byte-buf-builder-to-array (& out))))

(define (read-map [text : (& t str)] [limits : (& l map.VersionMapLimits)]) : map.VersionMapResult
  (let
    [data : (__tl_dyn-array u8) (bytes-of text)]
    (map.parse "exports.map" (& data) limits)))

(define (render [text : (& t str)]) : String
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (match (read-map text (& limits))
      [(Err error) (io.panic error.message)]
      [(Ok nodes)
        (let
          [out : String ""]
          (for [i (iterator.range 0 nodes.len)]
            (let
              [node : (& nodes map.VersionNode) (& (array-ref nodes.slots i))]
              (set!
                out
                (cat.str-cat
                  out
                  (string.copy node.name)
                  ":"
                  (string.int->string node.parent)
                  "["))
              (for [j (iterator.range 0 node.symbols.len)]
                (let
                  [symbol : (& nodes map.VersionSymbol)
                    (& (array-ref node.symbols.slots j))]
                  (set!
                    out
                    (cat.str-cat
                      out
                      (if symbol.global
                        "+"
                        "-")
                      (string.copy symbol.name)
                      ";"))))
              (set!
                out
                (cat.str-cat
                  out
                  (if node.local-all
                    "-*;"
                    "")
                  "]"))))
          out)])))

(define (contains? [text : (& t str)] [needle : (& n str)]) : bool
  (let
    [found : bool false]
    [at : i64 0]
    (while (and
      (not found)
      (<= (+ at (string.string-length needle)) (string.string-length text)))
      (set!
        found
        (string.eq
          (string.substring text at (string.string-length needle))
          needle))
      (+= at 1))
    found))

(define (reject
  [text : (& t str)]
  [detail : (& d str)]
  [line : i64]
  [column : i64]
  [limits : (& l map.VersionMapLimits)]) : unit
  (match (read-map text limits)
    [(Ok _) (io.panic (cat.str-cat "accepted " (string.copy text)))]
    [(Err error)
      (assert
        (contains? error.message detail)
        (cat.str-cat
          "wanted "
          (string.copy detail)
          ", got "
          (string.copy error.message)))
      (when
        (> line 0)
        (assert
          (and (= error.line line) (= error.column column))
          (cat.str-cat "wrong location: " (string.copy error.message))))]))

(test
  version-map-accepted-grammar
  (assert
    (string.eq
      (render "NODE{global:api;beta;local:*;};")
      "NODE:-1[+api;+beta;-*;]")
    "compact grammar")
  (assert
    (string.eq
      (render
        "V1 {global: old_api; local: hidden;};\nV2{global:new_api;}V1;\nV3{}V2;")
      "V1:-1[+old_api;-hidden;]V2:0[+new_api;]V3:1[]")
    "inheritance and order")
  (assert
    (string.eq
      (render "/* exports */ { global: \"api\"; global; local; local: *; };")
      ":-1[+api;+global;+local;-*;]")
    "anonymous, quotes, keyword names")
  (assert
    (string.eq
      (render "pkg_1.0 {global: $api-v1;local:*;};")
      "pkg_1.0:-1[+$api-v1;-*;]")
    "package and exact names"))

(defstruct RejectedMap
  (source String)
  (detail String)
  (line i64)
  (column i64))

(test
  version-map-rejected-grammar
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    [cases : (__tl_dyn-array RejectedMap) (__tl_make-array RejectedMap 16)]
    (set!
      (array-ref cases 0)
      (RejectedMap "V{global:extern \"C++\" { x; };};" "extern language" 1 10))
    (set!
      (array-ref cases 1)
      (RejectedMap "V{global:foo*;};" "glob pattern" 1 10))
    (set!
      (array-ref cases 2)
      (RejectedMap "V{global:*;};" "outside local" 1 10))
    (set!
      (array-ref cases 3)
      (RejectedMap "V{local:foo?;};" "glob pattern" 1 9))
    (set!
      (array-ref cases 4)
      (RejectedMap "V{global:foo=bar;};" "expression" 1 10))
    (set!
      (array-ref cases 5)
      (RejectedMap "V{global:x;}MISSING;" "unknown or forward parent" 1 13))
    (set!
      (array-ref cases 6)
      (RejectedMap "V{global:x;};\nW{global:x;}V;" "duplicate bound name" 2 10))
    (set!
      (array-ref cases 7)
      (RejectedMap "V{}; V{};" "duplicate version node" 1 6))
    (set!
      (array-ref cases 8)
      (RejectedMap "{global:x;}; V{};" "only node" 1 14))
    (set! (array-ref cases 9) (RejectedMap "V{}; {local:*;};" "only node" 1 6))
    (set!
      (array-ref cases 10)
      (RejectedMap "V{global:x;local:x;};" "duplicate bound name" 1 18))
    (set!
      (array-ref cases 11)
      (RejectedMap "V{local:*;*;};" "duplicate local catch-all" 1 11))
    (set! (array-ref cases 12) (RejectedMap "V{global:x;\n" "exact name" 2 1))
    (set! (array-ref cases 13) (RejectedMap "V{global:x;}" "exact name" 1 13))
    (set!
      (array-ref cases 14)
      (RejectedMap "V{local:\"*\";};" "glob pattern" 1 9))
    (set!
      (array-ref cases 15)
      (RejectedMap "V{global:x();};" "construct '('" 1 11))
    (for [i (iterator.range 0 (array-length cases))]
      (let
        [case : (& cases RejectedMap) (& (array-ref cases i))]
        (reject case.source case.detail case.line case.column (& limits))))))

(test
  version-map-bounds-and-scanner
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (set! limits.max-nodes 0)
    (reject "V{};" "node limit" 1 1 (& limits)))
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (set! limits.max-symbols 1)
    (reject "V{global:x;y;};" "symbol limit" 1 12 (& limits)))
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (set! limits.max-work 0)
    (reject "V{};" "work limit" 1 1 (& limits)))
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (set! limits.lex.max-token-bytes 1)
    (reject "NODE{};" "exceeds" 1 1 (& limits)))
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    (reject "/* never closed" "unterminated comment" 1 1 (& limits))
    (reject "V{global:\"never closed" "unterminated quote" 1 10 (& limits))))

(test
  version-map-source-label-boundary
  (let
    [limits : map.VersionMapLimits (map.default-limits)]
    [data : (__tl_dyn-array u8) (bytes-of "V{};")]
    (set! limits.lex.max-bytes 4)
    (match (map.parse "five!" (& data) (& limits))
      [(Ok _) (io.panic "accepted source label over limit")]
      [(Err error)
        (assert
          (string.eq error.message "version-map source-label limit exceeded")
          "bounded diagnostic")])
    (match (map.parse "four" (& data) (& limits))
      [(Ok _) unit]
      [(Err error) (io.panic error.message)])))