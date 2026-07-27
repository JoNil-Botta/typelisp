(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

;; #5927: opt2 register allocation used to miscompile this byte-copy builder.
;;
;; The loop-split rescue homes a spilled loop invariant in a register across a
;; loop region, one var per round. When no candidate register is free over the
;; region it may EVICT the register's single region occupant (re-spill it) --
;; and the occupant can be an EARLIER round's own region var. The round results
;; were merged in recursion-unwind order, so the earlier round's
;; `region var -> register` assignment overwrote the later round's eviction of
;; that same var: both region vars kept the same physical register across the
;; same loop. The second one's preheader copy then clobbered the first one's
;; only def.
;;
;; In this shape the clobbered value is the byte tail loop's BOUND `n` (its
;; reload is coalesced into the guard block, its only later use is the
;; back-edge compare) and the clobberer is the loop-invariant destination
;; offset `off`, so the tail loop ran `off` iterations instead of `n` --
;; silently copying the wrong number of bytes. The exposed shape is the
;; compiler's own `compiler-backend-asm-copy-part!`; it is latent for any user
;; code with a spilled bound plus a spilled invariant over one loop.
;;
;; Behavioral fixture: every copied byte and the untouched tail of the
;; destination are checked, so a wrong iteration count fails the run rather
;; than only changing the assembly. Run at opt0/opt1 by the manifest and
;; explicitly at opt2 by verify-integration.sh (the level that miscompiled).
(defstruct Buf
  (data (MutPtr u8))
  (cap i64)
  (len i64))

;; Copy `n` bytes of `src` into `dst` at byte offset `off`, INLINE: one word
;; loop plus a byte tail loop, both bounded by `n` and both addressing through
;; the loop-invariant `off`.
(defmacro (copy-part! [dst : (MutPtr u8)] [off : i64] [src : String] [n : i64]) : unit
  `(let
    [cp-src : (Ptr u8)
      (unsafe
        (string-data (& ,src)))]
    [cp-words : i64 (/ ,n 8)]
    [cp-src64 : (Ptr i64)
      (unsafe
        (ptr-cast cp-src : (Ptr i64)))]
    [cp-dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset ,dst ,off) : (MutPtr i64)))]
    [cp-w : i64 0]
    [cp-b : i64 (* cp-words 8)]
    (begin
      (while (< cp-w cp-words)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset cp-dst64 cp-w)
              (ptr-read (ptr-offset cp-src64 cp-w))))
          (set! cp-w (+ cp-w 1))))
      (while (< cp-b ,n)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset ,dst (+ ,off cp-b))
              (ptr-read (ptr-offset cp-src cp-b))))
          (set! cp-b (+ cp-b 1))))
      unit)))

(define buf-reserve-calls : i64
  0)

(define (buf-reserve! [buf : (&mut buf Buf)] [total : i64]) : unit
  (begin
    (set! buf-reserve-calls (+ buf-reserve-calls 1))
    (if (> total (struct-get buf cap))
      (io.panic "buf overflow")
      unit)))

(define (buf-append5
  [buf : (&mut buf Buf)]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : unit
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [nc : i64 (string.string-length c)]
    [nd : i64 (string.string-length d)]
    [ne : i64 (string.string-length e)]
    [total : i64 (+ na (+ nb (+ nc (+ nd ne))))]
    [off : i64 (struct-get buf len)]
    (begin
      (buf-reserve! buf (+ off total))
      (let
        [dst : (MutPtr u8) (struct-get buf data)]
        [ob : i64 (+ off na)]
        [oc : i64 (+ ob nb)]
        [od : i64 (+ oc nc)]
        [oe : i64 (+ od nd)]
        (begin
          (copy-part! dst off a na)
          (copy-part! dst ob b nb)
          (copy-part! dst oc c nc)
          (copy-part! dst od d nd)
          (copy-part! dst oe e ne)))
      (set! (struct-get buf len) (+ off total)))))

(define (byte-at [p : (MutPtr u8)] [i : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset p i)))
    : i64))

(define (str-byte-at [s : String] [i : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset (string-data (& s)) i)))
    : i64))

(define (check-part [p : (MutPtr u8)] [off : i64] [s : String]) : i64
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (= (byte-at p (+ off i)) (str-byte-at s i))
            unit
            (set! bad (+ bad 1)))
          (set! i (+ i 1))))
      bad)))

(define (main) : i64
  (let
    ;; Runtime-derived so nothing is constant-folded into the copies.
    [pad : i64 (io.arg-count)]
    [items : (Array u8) (array.make-array u8 512)]
    [buf : Buf
      (Buf
        (unsafe
          (array-data items))
        512
        0)]
    [p : (MutPtr u8)
      (unsafe
        (array-data items))]
    ;; Every part has a non-empty byte TAIL (length % 8 >= 2), so the tail loop
    ;; must run more than one iteration.
    [a : String
      (if (> pad 100)
        "AAAAAAAAAAAAA"
        "abcdefghijklm")]
    [b : String
      (if (> pad 100)
        "BBBBBBBBBB"
        "nopqrstuvw")]
    [c : String
      (if (> pad 100)
        "CCCCCCCCCCCCCCC"
        "xyz0123456789AB")]
    [d : String
      (if (> pad 100)
        "DDDDDDDDDD"
        "CDEFGHIJKL")]
    [e : String
      (if (> pad 100)
        "EEEEEEEEEEEE"
        "MNOPQRSTUVWX")]
    [i : i64 0]
    [bad : i64 0]
    [total : i64 0]
    (begin
      (while (< i 512)
        (begin
          (unsafe
            (ptr-write! (ptr-offset p i) (cast 170 : u8)))
          (set! i (+ i 1))))
      ;; Two appends: the first runs with off == 0, the second with off > 0.
      (buf-append5 (&mut buf) a b c d e)
      (buf-append5 (&mut buf) a b c d e)
      (set!
        total
        (*
          2
          (+
            (string.string-length a)
            (+
              (string.string-length b)
              (+
                (string.string-length c)
                (+ (string.string-length d) (string.string-length e)))))))
      (if (= (struct-get buf len) total)
        unit
        (set! bad (+ bad 1000)))
      (set! i 0)
      (while (< i 2)
        (let
          [base : i64
            (*
              i
              (+
                (string.string-length a)
                (+
                  (string.string-length b)
                  (+
                    (string.string-length c)
                    (+ (string.string-length d) (string.string-length e))))))]
          (begin
            (set! bad (+ bad (check-part p base a)))
            (set!
              bad
              (+ bad (check-part p (+ base (string.string-length a)) b)))
            (set!
              bad
              (+
                bad
                (check-part
                  p
                  (+ base (+ (string.string-length a) (string.string-length b)))
                  c)))
            (set!
              bad
              (+
                bad
                (check-part
                  p
                  (+
                    base
                    (+
                      (string.string-length a)
                      (+ (string.string-length b) (string.string-length c))))
                  d)))
            (set!
              bad
              (+
                bad
                (check-part
                  p
                  (+
                    base
                    (+
                      (string.string-length a)
                      (+
                        (string.string-length b)
                        (+ (string.string-length c) (string.string-length d)))))
                  e)))
            (set! i (+ i 1)))))
      ;; Nothing past the appended text may have been written.
      (set! i total)
      (while (< i 512)
        (begin
          (if (= (byte-at p i) 170)
            unit
            (set! bad (+ bad 1)))
          (set! i (+ i 1))))
      (if (and (= bad 0) (= buf-reserve-calls 2))
        42
        1))))