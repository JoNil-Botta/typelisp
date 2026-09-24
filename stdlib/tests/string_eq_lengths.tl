;; `string.eq` compares by length class -- whole words plus one overlapping
;; final word from 8 bytes up, first and last 4 (or 2) bytes below that, one
;; byte at length 1. For every length 0..40 this checks a string against an
;; equal copy (a different buffer), against itself (the same buffer), against a
;; copy with one byte flipped at EACH position -- so every overlap region is
;; exercised -- and against its own one-shorter prefix, all against a
;; byte-by-byte reference.
(import stdlib.string)
(import stdlib.text_buf)

(define (ref-eq [a : (& a str)] [b : (& b str)]) : bool
  (if (not (= (string.string-length a) (string.string-length b)))
    false
    (let
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and ok (< i (string.string-length a)))
          (begin
            (when
              (not (= (string.string-ref a i) (string.string-ref b i)))
              (set! ok false))
            (set! i (+ i 1))))
        ok))))

(define (make [len : i64] [seed : i64]) : String
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    [st : i64 seed]
    (begin
      (while (< i len)
        (begin
          (set! st (+ (* st 6364136223846793005) 1442695040888963407))
          (set!
            out
            (text_buf.append
              out
              (if (= (bit-and (shr st 40) 1) 0)
                "a"
                "b")))
          (set! i (+ i 1))))
      (text_buf.render out))))

(define (flip [s : (& s str)] [at : i64]) : String
  (text_buf.render
    (text_buf.append
      (text_buf.append
        (text_buf.append (text_buf.empty) (string.substring s 0 at))
        (if (= (string.string-ref s at) 'a')
          "b"
          "a"))
      (string.substring s (+ at 1) (- (- (string.string-length s) at) 1)))))

(define (main) : i64
  (let
    [len : i64 0]
    [bad : i64 0]
    (begin
      (while (<= len 40)
        (let
          [a : String (make len (+ len 17))]
          [b : String (make len (+ len 17))]
          [pos : i64 0]
          (begin
            (when (not (string.eq (& a) (& b))) (set! bad (+ bad 1)))
            (when (not (string.eq (& a) (& a))) (set! bad (+ bad 1)))
            (while (< pos len)
              (let
                [c : String (flip (& a) pos)]
                (begin
                  (when
                    (not (= (string.eq (& a) (& c)) (ref-eq (& a) (& c))))
                    (set! bad (+ bad 1)))
                  (when (string.eq (& c) (& a)) (set! bad (+ bad 1)))
                  (set! pos (+ pos 1)))))
            (when
              (> len 0)
              (let
                [d : String (make (- len 1) (+ len 17))]
                (when (string.eq (& a) (& d)) (set! bad (+ bad 1)))))
            (set! len (+ len 1)))))
      (if (= bad 0)
        42
        1))))