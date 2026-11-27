;; Symbol names are interned as soon as an operand is read. Forward and
;; backward numeric references share the definition's occurrence counter.
(import compiler_x64_encode_operands as op)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf_core as buf)
(import stdlib.vector)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as name_map)

(defstruct Position
  (section i64)
  (fragment i64)
  (delta i64))

;; Expressions in compiler assembly are affine: A - B + constant. Minus one
;; denotes an absent term, minus two the location at which it was parsed.
(defstruct Expression
  (positive i64)
  (negative i64)
  (constant i64)
  (modifier String))

(defstruct Symbol
  (name String)
  (position Position)
  (is-alias bool)
  (alias Expression)
  (size Expression)
  (size-origin Position)
  (binding i64)
  (visibility i64)
  (kind i64)
  (common-align i64)
  (retain-name bool)
  (numeric-label bool))

(import (vector.vector Symbol core) as symbols)

(defstruct Table
  (names name_map.Map)
  (numeric name_map.Map)
  (entries symbols.Vec))

(define (new-table) : Table
  (Table (name_map.new) (name_map.new) (symbols.new)))

(define (constant [n : i64]) : Expression
  (Expression -1 -1 n ""))

(define (lookup [table : (& Table)] [name : (& name str)]) : i64
  (name_map.lookup-value-or (name_map.get-borrowed (& table.names) name) -1))

(define (intern! [table : (&mut Table)] [name : (& name str)]) : i64
  (let
    [id (lookup table name)]
    (when (>= id 0) (return id))
    (let
      [next table.entries.len]
      [owned (string.copy name)]
      [unset (Position -1 0 0)]
      (symbols.push-ref!
        (&mut table.entries)
        (Symbol
          (string.copy name)
          unset
          false
          (constant 0)
          (constant 0)
          unset
          -1
          0
          0
          0
          false
          false))
      (name_map.insert-ref! (&mut table.names) owned next)
      next)))

(define (digits? [s : (& str)]) : bool
  (let
    [i : i64 0]
    (while (< i (string.string-length s))
      (let
        [c (string.string-ref s i)]
        (unless (and (>= c '0') (<= c '9')) (return false)))
      (+= i 1))
    (> i 0)))

(define (numeric-name!
  [table : (&mut Table)]
  [digits : (& str)]
  [direction : char]) : String
  (let
    [count
      (name_map.lookup-value-or
        (name_map.get-borrowed (& table.numeric) digits)
        0)]
    (unless (= direction 'b') (+= count 1))
    (when
      (= direction ':')
      (name_map.insert-ref! (&mut table.numeric) (string.copy digits) count))
    ;; The separator cannot appear in source identifiers.
    (string.concat4-borrowed ".L" digits "@" (& (string.int->string count)))))

(define (identifier? [s : (& str)]) : bool
  (let
    [i : i64 0]
    (while (< i (string.string-length s))
      (let
        [c (string.string-ref s i)]
        (unless
          (or
            (and (>= c 'a') (<= c 'z'))
            (and (>= c 'A') (<= c 'Z'))
            (= c '.')
            (= c '_')
            (= c '$')
            (and (> i 0) (>= c '0') (<= c '9')))
          (return false)))
      (+= i 1))
    (> i 0)))

(define (named! [table : (&mut Table)] [name : (& str)]) : i64
  (let
    [n (string.string-length name)]
    (cond
      [(identifier? name) (intern! table name)]
      [(and
          (> n 2)
          (= (string.string-ref name 0) '"')
          (= (string.string-ref name (- n 1)) '"'))
        (intern! table (& (string.substring name 1 (- n 2))))]
      [else -1])))

(define (reference! [table : (&mut Table)] [name : (& name str)]) : i64
  (when (string.eq name ".") (return -2))
  (let
    [n (string.string-length name)]
    (when
      (> n 1)
      (let
        [dir (string.string-ref name (- n 1))]
        (when
          (or (= dir 'f') (= dir 'b'))
          (let
            [digits (string.substring name 0 (- n 1))]
            (when
              (digits? (& digits))
              (let
                [key (numeric-name! table (& digits) dir)]
                [id (intern! table (& key))]
                (set! (array-ref table.entries.slots id).numeric-label true)
                (return id))))))))
  (named! table name))

(defenum ResultExpression
  (Ok Expression)
  (Err String))

(define (modifier-name [text : (& str)] [start : i64]) : String
  (let
    [out (buf.byte-buf-builder-new)]
    [i start]
    (while (< i (string.string-length text))
      (let
        [v (cast (string.string-ref text i) : i64)]
        (buf.byte-buf-builder-push
          (&mut out)
          (cast
            (if (and (>= v 97) (<= v 122))
              (- v 32)
              v)
            : u8)))
      (+= i 1))
    (buf.byte-buf-builder-finish-string (& out))))

(define (parse-expression! [table : (&mut Table)] [source : (& src str)]) : ResultExpression
  (let
    [s : String (string.trim source)]
    [n (string.string-length (& s))]
    [i : i64 0]
    [expr (constant 0)]
    (when (= n 0) (return (Err "missing assembly expression")))
    (while (< i n)
      (let
        [first (string.string-ref (& s) i)]
        [minus (= first '-')]
        (when (or minus (= first '+')) (+= i 1))
        (let
          [start i]
          (let
            [quoted false]
            (while (and
              (< i n)
              (or
                quoted
                (and
                  (!= (string.string-ref (& s) i) '+')
                  (!= (string.string-ref (& s) i) '-'))))
              (when
                (= (string.string-ref (& s) i) '"')
                (set! quoted (not quoted)))
              (+= i 1))
            (when quoted (return (Err "unterminated quoted symbol"))))
          (let
            [term : String (op.range (& s) start i)]
            (when
              (= 0 (string.string-length (& term)))
              (return (Err "empty assembly expression term")))
            (match (op.integer-literal (& term))
              [(Integer value)
                (if minus
                  (-= expr.constant value)
                  (+= expr.constant value))]
              [(IntegerOverflow) (return (Err "assembly integer out of range"))]
              [(Symbolic)
                (let
                  [split (op.delimiter (& term) 0 '@')]
                  [at
                    (if (= split (string.string-length (& term)))
                      -1
                      split)]
                  [name : String
                    (if (< at 0)
                      ""
                      (op.range (& term) 0 at))]
                  [id
                    (if (< at 0)
                      (reference! table (& term))
                      (reference! table (& name)))]
                  (when
                    (= id -1)
                    (return
                      (Err
                        (str_cat.str-cat
                          "invalid assembly symbol "
                          (if (< at 0)
                            (string.copy (& term))
                            name)))))
                  (when
                    (>= at 0)
                    (when
                      (or
                        minus
                        (= id -2)
                        (= (+ at 1) (string.string-length (& term))))
                      (return (Err "invalid relocation modifier")))
                    (set! expr.modifier (modifier-name (& term) (+ at 1)))
                    (unless
                      (string.eq (& expr.modifier) "PLT")
                      (let
                        [_got (intern! table "_GLOBAL_OFFSET_TABLE_")]
                        unit)))
                  (if minus
                    (if (= expr.negative -1)
                      (set! expr.negative id)
                      (return (Err "multiple negative symbols")))
                    (if (= expr.positive -1)
                      (set! expr.positive id)
                      (return (Err "multiple positive symbols")))))])))))
    (Ok expr)))