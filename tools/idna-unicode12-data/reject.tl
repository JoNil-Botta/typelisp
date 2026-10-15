;; Deliberately bypass byte pins only inside parser-negative fixtures. The
;; production generator exposes no hash-skip option.
(import parse)
(import read)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [mode : String (io.arg 1)]
    [data : read.Data (read.new)]
    (cond
      [(string.eq mode "empty-version")
        (read.version "" "fixture")
        0]
      [(string.eq mode "paint-range")
        (read.paint (&mut data) (parse.Range -1 0) 1 0 "fixture" 7)
        0]
      [(string.eq mode "integer")
        (parse.number "110000" 16 1114111 "fixture" 7)]
      [(string.eq mode "overflow")
        (parse.number "FFFFFFFFFFFFFFFFFFFFFFFF" 16 1114111 "fixture" 7)]
      [(string.eq mode "negative") (parse.number "-1" 16 1114111 "fixture" 7)]
      [(string.eq mode "digit") (parse.number "G0" 16 1114111 "fixture" 7)]
      [(string.eq mode "empty") (parse.number "" 16 1114111 "fixture" 7)]
      [(string.eq mode "reversed")
        (parse.range "10..0F" '.' "fixture" 7)
        0]
      [(string.eq mode "delimiter")
        (parse.range "10.FF" '.' "fixture" 7)
        0]
      [(string.eq mode "quoted")
        (let
          [cursor : parse.Cursor (parse.Cursor 0 7)]
          (parse.record "\"unterminated\n" (&mut cursor) true "fixture")
          0)]
      [(string.eq mode "fields")
        (let
          [row : parse.Fields (parse.fields "a;b" ';' false "fixture" 7)]
          (parse.expect-fields (& row) 3 "fixture" 7))
        0]
      [(string.eq mode "property")
        (parse.vocabulary "UNKNOWN" "L|R|AL" "fixture" 7)]
      [(string.eq mode "overlap")
        (read.paint (&mut data) (parse.Range 1 3) 1 0 "fixture" 7)
        (read.paint (&mut data) (parse.Range 3 4) 1 0 "fixture" 8)
        0]
      [(string.eq mode "version")
        (read.properties (&mut data) "# Scripts-17.0.0.txt\n0000 ; Latin\n" 5)
        0]
      [(string.eq mode "unsorted")
        (read.properties
          (&mut data)
          "# DerivedJoiningType-12.0.0.txt\n0002 ; L\n0001 ; L\n"
          6)
        0]
      [(string.eq mode "duplicate")
        (read.properties
          (&mut data)
          "# DerivedJoiningType-12.0.0.txt\n0002 ; L\n0002 ; L\n"
          6)
        0]
      [(string.eq mode "cross-group-overlap")
        (read.properties
          (&mut data)
          "# DerivedJoiningType-12.0.0.txt\n0002 ; L\n0002 ; R\n"
          6)
        0]
      [(string.eq mode "context")
        (read.context
          "Code Point,Lookup,Rule Set,Overview,Description\n200E,True,x,x,x\n")
        0]
      [(string.eq mode "idna-gap")
        (read.idna
          (&mut data)
          "Codepoint,Property,Status,Description\n0001,PVALID,,x\n")
        0]
      [(string.eq mode "idna-count")
        (read.idna
          (&mut data)
          "Codepoint,Property,Status,Description\n0000-10FFFF,DISALLOWED,,x\n")
        0]
      [(string.eq mode "unicode-order")
        (read.unicode-data
          (&mut data)
          "0041;A;Lu;0;L;;;;;N;;;;;\n0040;B;Lu;0;L;;;;;N;;;;;\n")
        0]
      [(string.eq mode "unicode-pair")
        (read.unicode-data
          (&mut data)
          "3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;\n")
        0]
      [(string.eq mode "unicode-surrogate")
        (read.unicode-data (&mut data) "0041;A;Lu;0;L;D800;;;;N;;;;;\n")
        0]
      [(string.eq mode "pool-overflow")
        (set! data.pool-count 8192)
        (read.unicode-data (&mut data) "0041;A;Lu;0;L;0042;;;;N;;;;;\n")
        0]
      [else
        (io.eprintln "unknown reject fixture")
        2])
    (io.eprintln "reject fixture unexpectedly succeeded")
    3))