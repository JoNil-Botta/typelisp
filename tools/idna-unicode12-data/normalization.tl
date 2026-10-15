;; Test-only canonical normalization consumer. Expected sequences come from
;; the pinned Unicode conformance oracle, independently of generated tables.
(import parse)
(import pins)
(import stdlib.idna_unicode12 as idna)
(import stdlib.string)

(defstruct Sequence
  (items (Array i64 256))
  (count i64))

(define (empty) : Sequence
  (Sequence (make-array i64 256) 0))

(define (ccc [cp : i64]) : i64
  (match (idna.lookup cp)
    [(idna.Scalar props) (cast props.ccc : i64)]
    [(idna.InvalidScalar) (parse.fail "normalization" 0 "invalid scalar")]))

(define (push [sequence : (&mut sequence Sequence)] [cp : i64]) : unit
  (when
    (>= sequence.count 256)
    (parse.fail "normalization" 0 "fixture sequence overflow"))
  (set! (array-ref sequence.items sequence.count) cp)
  (set! sequence.count (+ sequence.count 1)))

(define (sequence [text : (& text str)] [line : i64]) : Sequence
  (let
    [out : Sequence (empty)]
    [start : i64 0]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (while (<= index length)
      (when
        (or (= index length) (= (string.string-ref text index) ' '))
        (when
          (> index start)
          (let
            [cp : i64
              (parse.number
                (string.substring text start (- index start))
                16
                1114111
                (pins.name 4)
                line)]
            (when
              (not (idna.valid-scalar? cp))
              (parse.fail (pins.name 4) line "non-scalar conformance operand"))
            (push (&mut out) cp)))
        (set! start (+ index 1)))
      (set! index (+ index 1)))
    out))

(define (ordered-push [out : (&mut out Sequence)] [cp : i64]) : unit
  (let
    [index : i64 out.count]
    [class : i64 (ccc cp)]
    (push out cp)
    (while (and
      (> class 0)
      (> index 0)
      (> (ccc (array-ref out.items (- index 1))) class))
      (set! (array-ref out.items index) (array-ref out.items (- index 1)))
      (set! index (- index 1)))
    (set! (array-ref out.items index) cp)))

(define (decompose [out : (&mut out Sequence)] [cp : i64] [depth : i64]) : unit
  (when
    (> depth 32)
    (parse.fail "normalization" 0 "cyclic or excessive canonical decomposition"))
  (if (and (>= cp 44032) (< cp 55204))
    (let
      [syllable : i64 (- cp 44032)]
      [trailing : i64 (% syllable 28)]
      (ordered-push out (+ 4352 (/ syllable 588)))
      (ordered-push out (+ 4449 (/ (% syllable 588) 28)))
      (when (> trailing 0) (ordered-push out (+ 4519 trailing))))
    (let
      [span : idna.DecompositionSpan (idna.decomposition cp)]
      [index : i64 0]
      (if (= span.count 0)
        (ordered-push out cp)
        (while (< index (cast span.count : i64))
          (decompose out (idna.decomposition-at span index) (+ depth 1))
          (set! index (+ index 1)))))))

(define (pair [first : i64] [second : i64]) : i64
  (cond
    [(and (>= first 4352) (< first 4371) (>= second 4449) (< second 4470))
      (+ 44032 (* (+ (* (- first 4352) 21) (- second 4449)) 28))]
    [(and
        (>= first 44032)
        (< first 55204)
        (= (% (- first 44032) 28) 0)
        (> second 4519)
        (< second 4547))
      (+ first (- second 4519))]
    [else (idna.composition first second)]))

(define (normalize [input : (& input Sequence)] [compose : bool]) : Sequence
  (let
    [out : Sequence (empty)]
    [index : i64 0]
    (while (< index input.count)
      (decompose (&mut out) (array-ref input.items index) 0)
      (set! index (+ index 1)))
    (when
      (and compose (> out.count 0))
      (let
        [starter : i64 0]
        [write : i64 1]
        [previous-class : i64 (ccc (array-ref out.items 0))]
        (set! index 1)
        (while (< index out.count)
          (let
            [cp : i64 (array-ref out.items index)]
            [class : i64 (ccc cp)]
            [composite : i64
              (if (or (= previous-class 0) (< previous-class class))
                (pair (array-ref out.items starter) cp)
                -1)]
            (if (>= composite 0)
              (set! (array-ref out.items starter) composite)
              (begin
                (when (= class 0) (set! starter write))
                (set! (array-ref out.items write) cp)
                (set! write (+ write 1))
                (set! previous-class class))))
          (set! index (+ index 1)))
        (set! out.count write)))
    out))

(define (equal? [first : (& first Sequence)] [second : (& second Sequence)]) : bool
  (when (!= first.count second.count) (return false))
  (let
    [index : i64 0]
    (while (< index first.count)
      (when
        (!= (array-ref first.items index) (array-ref second.items index))
        (return false))
      (set! index (+ index 1)))
    true))

(define (vectors [text : (& text str)]) : i64
  (let
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [rows : i64 0]
    [file : String (pins.name 4)]
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) false file)]
        [row : parse.Fields (parse.fields record ';' false file line)]
        [first : String (parse.field (& row) 0)]
        (when
          (and
            (> (string.string-length first) 0)
            (!= (string.string-ref first 0) '@'))
          (parse.expect-fields (& row) 6 file line)
          (let
            [columns : (Array Sequence 5) (make-array Sequence 5)]
            [index : i64 0]
            (while (< index 5)
              (set!
                (array-ref columns index)
                (sequence (parse.field (& row) index) line))
              (set! index (+ index 1)))
            (set! index 0)
            (while (< index 5)
              (let
                [nfc : Sequence (normalize (& (array-ref columns index)) true)]
                [nfd : Sequence (normalize (& (array-ref columns index)) false)]
                (when
                  (or
                    (not
                      (equal?
                        (& nfc)
                        (&
                          (array-ref
                            columns
                            (if (< index 3)
                              1
                              3)))))
                    (not
                      (equal?
                        (& nfd)
                        (&
                          (array-ref
                            columns
                            (if (< index 3)
                              2
                              4))))))
                  (parse.fail
                    file
                    line
                    "canonical normalization conformance failure")))
              (set! index (+ index 1))))
          (set! rows (+ rows 1)))))
    (when
      (!= rows 18819)
      (parse.fail file cursor.line "expected 18819 conformance rows"))
    rows))

(define (hangul) : unit
  (when
    (or
      (!= (pair 4351 4449) -1)
      (!= (pair 4371 4449) -1)
      (!= (pair 4352 4448) -1)
      (!= (pair 4352 4470) -1)
      (!= (pair 44032 4519) -1)
      (!= (pair 44032 4547) -1)
      (!= (pair 55204 4520) -1)
      (!= (pair 44033 4520) -1))
    (parse.fail "Hangul" 0 "composition accepted an invalid boundary pair"))
  (when
    (or
      (!= (idna.hangul-s-base) 44032)
      (!= (idna.hangul-l-base) 4352)
      (!= (idna.hangul-v-base) 4449)
      (!= (idna.hangul-t-base) 4519)
      (!= (idna.hangul-l-count) 19)
      (!= (idna.hangul-v-count) 21)
      (!= (idna.hangul-t-count) 28)
      (!= (idna.hangul-n-count) 588)
      (!= (idna.hangul-s-count) 11172))
    (parse.fail "Hangul" 0 "incorrect algorithmic constants"))
  (let
    [cp : i64 44031]
    (while (<= cp 55204)
      (let
        [input : Sequence (empty)]
        [expected : Sequence (empty)]
        (push (&mut input) cp)
        (let
          [nfc : Sequence (normalize (& input) true)]
          [nfd : Sequence (normalize (& input) false)]
          (when
            (not (equal? (& nfc) (& input)))
            (parse.fail "Hangul" cp "NFC boundary or syllable mismatch"))
          (if (or (= cp 44031) (= cp 55204))
            (push (&mut expected) cp)
            (begin
              (push (&mut expected) (+ 4352 (/ (- cp 44032) 588)))
              (push (&mut expected) (+ 4449 (/ (% (- cp 44032) 588) 28)))
              (when
                (!= (% (- cp 44032) 28) 0)
                (push (&mut expected) (+ 4519 (% (- cp 44032) 28))))))
          (when
            (not (equal? (& nfd) (& expected)))
            (parse.fail "Hangul" cp "NFD boundary or syllable mismatch"))))
      (set! cp (+ cp 1)))))