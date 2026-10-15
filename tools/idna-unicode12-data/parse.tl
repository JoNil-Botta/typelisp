(import stdlib.io)
(import stdlib.string)

(defstruct Cursor
  (offset i64)
  (line i64))

(defstruct Fields
  (items (__tl_dyn-array String))
  (count i64))

(defstruct Range
  (first i64)
  (last i64))

(define (fail [file : (& file str)] [line : i64] [message : String]) : never
  (io.eprintln "{}:{}: {}" file line message)
  (io.platform-exit 1))

;; CSV records may contain quoted LF. The cursor always reports physical lines.
(define (record
  [text : (& text str)]
  [cursor : (&mut cursor Cursor)]
  [csv : bool]
  [file : (& file str)]) : String
  (let
    [start : i64 cursor.offset]
    [quoted : bool false]
    [length : i64 (string.string-length text)]
    (while (< cursor.offset length)
      (let
        [c : char (string.string-ref text cursor.offset)]
        (set! cursor.offset (+ cursor.offset 1))
        (when (and csv (= c '"')) (set! quoted (not quoted)))
        (when
          (= c '\n')
          (set! cursor.line (+ cursor.line 1))
          (when (not quoted) (break)))))
    (when quoted (fail file cursor.line "unterminated quoted record"))
    (string.trim (string.substring text start (- cursor.offset start)))))

(define (fields
  [text : (& text str)]
  [delimiter : char]
  [csv : bool]
  [file : (& file str)]
  [line : i64]) : Fields
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String 16)]
    [count : i64 0]
    [start : i64 0]
    [index : i64 0]
    [quoted : bool false]
    [length : i64 (string.string-length text)]
    (while (<= index length)
      (let
        [c : char
          (if (< index length)
            (string.string-ref text index)
            delimiter)]
        (when (and csv (= c '"')) (set! quoted (not quoted)))
        (when (and (not csv) (= c '#')) (set! length index) (set! c delimiter))
        (when
          (and (not quoted) (= c delimiter))
          (when (>= count 16) (fail file line "too many fields"))
          (set!
            (array-ref items count)
            (string.trim (string.substring text start (- index start))))
          (set! count (+ count 1))
          (set! start (+ index 1))))
      (set! index (+ index 1)))
    (when quoted (fail file line "unterminated quoted field"))
    (Fields items count)))

(define (field [row : (& row Fields)] [index : i64]) : String
  (string.copy (& (array-ref row.items index))))

(define (expect-fields
  [row : (& row Fields)]
  [count : i64]
  [file : (& file str)]
  [line : i64]) : unit
  (when (!= row.count count) (fail file line "wrong field count")))

(define (number
  [text : (& text str)]
  [radix : i64]
  [maximum : i64]
  [file : (& file str)]
  [line : i64]) : i64
  (let
    [value : i64 0]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (when (= length 0) (fail file line "empty integer"))
    (while (< index length)
      (let
        [c : i64 (cast (string.string-ref text index) : i64)]
        [digit : i64
          (cond
            [(and (>= c 48) (<= c 57)) (- c 48)]
            [(and (>= c 65) (<= c 70)) (- c 55)]
            [else -1])]
        (when
          (or
            (< digit 0)
            (> digit maximum)
            (>= digit radix)
            (> value (/ (- maximum digit) radix)))
          (fail file line "integer outside checked domain"))
        (set! value (+ (* value radix) digit)))
      (set! index (+ index 1)))
    value))

(define (range
  [text : (& text str)]
  [separator : char]
  [file : (& file str)]
  [line : i64]) : Range
  (let
    [split : i64 -1]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (while (< index length)
      (when
        (= (string.string-ref text index) separator)
        (set! split index)
        (break))
      (set! index (+ index 1)))
    (if (< split 0)
      (let
        [value : i64 (number text 16 1114111 file line)]
        (Range value value))
      (let
        [skip : i64
          (if (= separator '.')
            2
            1)]
        [first : i64
          (number (string.substring text 0 split) 16 1114111 file line)]
        [last : i64
          (number
            (string.substring text (+ split skip) (- length (+ split skip)))
            16
            1114111
            file
            line)]
        (when
          (and
            (= separator '.')
            (or
              (>= (+ split 1) length)
              (!= (string.string-ref text (+ split 1)) '.')))
          (fail file line "malformed range delimiter"))
        (when (> first last) (fail file line "reversed range"))
        (Range first last)))))

;; Return a closed vocabulary index; no unknown property silently becomes default.
(define (vocabulary
  [text : (& text str)]
  [names : (& names str)]
  [file : (& file str)]
  [line : i64]) : i64
  (let
    [start : i64 0]
    [index : i64 0]
    [value : i64 0]
    [length : i64 (string.string-length names)]
    (while (<= index length)
      (when
        (or (= index length) (= (string.string-ref names index) '|'))
        (when
          (string.eq text (string.substring names start (- index start)))
          (return value))
        (set! value (+ value 1))
        (set! start (+ index 1)))
      (set! index (+ index 1)))
    (fail file line "unknown property value")))