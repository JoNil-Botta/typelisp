;# Owned Vec storage for the liveness benchmark's native Slice kernel.
(module liveness_storage)

(import stdlib.array)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector u8) as u8vec)

(defstruct I64Buffer
  (values i64vec.Vec))

(define (string-to-u8-vec [source : String]) : u8vec.Vec
  (let
    [n : i64 (string-length source)]
    [out : u8vec.Vec (u8vec.Vec (array.make-array u8 n) n)]
    [slots (u8vec.slots-mut (&mut out))]
    [src : (Ptr u8)
      (unsafe
        (string-data (& source)))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set!
            slots
            i
            (unsafe
              (ptr-read (ptr-offset src i))))
          (set! i (+ i 1))))
      out)))

(define (zero-i64-vec [n : i64]) : I64Buffer
  (I64Buffer (i64vec.Vec (array.make-array i64 n) n)))

(define (u8-len [items : (& items u8vec.Vec)]) : i64
  (u8vec.len items))

(define (i64-get [items : (& items I64Buffer)] [index : i64]) : i64
  (array-ref (i64vec.slots (& (struct-get items values))) index))

(define (i64-get-mut [items : (&mut items I64Buffer)] [index : i64]) : i64
  (array-ref (i64vec.slots-mut (&mut (struct-get items values))) index))

(define (i64-set! [items : (&mut items I64Buffer)] [index : i64] [value : i64]) : unit
  (array-set! (i64vec.slots-mut (&mut (struct-get items values))) index value))

(define (i64-view-mut [items : (&mut source I64Buffer)]) : (&mut
    source
    (Slice i64))
  (i64vec.view-mut (&mut (struct-get items values))))

(define (u8-view-mut [items : (&mut source u8vec.Vec)]) : (&mut
    source
    (Slice u8))
  (u8vec.view-mut items))

(define (live-out-into!
  [scratch-buffer : (&mut scratch I64Buffer)]
  [words : i64]
  [g : i64]
  [succ-start-buffer : (&mut succ-start I64Buffer)]
  [succ-items-buffer : (&mut succ-items I64Buffer)]
  [live-in-buffer : (&mut live-in I64Buffer)]
  [word-base : i64]
  [block-base : i64]
  [phi-out-buffer : (&mut phi-out I64Buffer)]
  [with-phi-out : bool]) : unit
  (let
    [scratch (i64vec.slots-mut (&mut (struct-get scratch-buffer values)))]
    [succ-start (i64vec.slots-mut (&mut (struct-get succ-start-buffer values)))]
    [succ-items (i64vec.slots-mut (&mut (struct-get succ-items-buffer values)))]
    [live-in (i64vec.slots-mut (&mut (struct-get live-in-buffer values)))]
    [phi-out (i64vec.slots-mut (&mut (struct-get phi-out-buffer values)))]
    [k : i64 0]
    [stop : i64 (array-ref succ-start (+ g 1))]
    [slot : i64 (array-ref succ-start g)]
    (begin
      (while (< k words)
        (begin
          (array-set! scratch k 0)
          (set! k (+ k 1))))
      (while (< slot stop)
        (let
          [succ : i64 (array-ref succ-items slot)]
          [succ-base : i64 (+ word-base (* (- succ block-base) words))]
          [i : i64 0]
          (begin
            (while (< i words)
              (begin
                (array-set!
                  scratch
                  i
                  (bit-or
                    (array-ref scratch i)
                    (array-ref live-in (+ succ-base i))))
                (set! i (+ i 1))))
            (set! slot (+ slot 1)))))
      (when
        with-phi-out
        (let
          [self-base : i64 (+ word-base (* (- g block-base) words))]
          [i : i64 0]
          (while (< i words)
            (begin
              (array-set!
                scratch
                i
                (bit-or
                  (array-ref scratch i)
                  (array-ref phi-out (+ self-base i))))
              (set! i (+ i 1))))))
      unit)))

(define (recompute!
  [g : i64]
  [words : i64]
  [word-base : i64]
  [block-base : i64]
  [succ-start : (&mut succ-start I64Buffer)]
  [succ-items : (&mut succ-items I64Buffer)]
  [uses-buffer : (&mut uses I64Buffer)]
  [defs-buffer : (&mut defs I64Buffer)]
  [phi-out : (&mut phi-out I64Buffer)]
  [live-in-buffer : (&mut live-in I64Buffer)]
  [live-out-buffer : (&mut live-out I64Buffer)]
  [scratch-out-buffer : (&mut scratch-out I64Buffer)]
  [scratch-in-buffer : (&mut scratch-in I64Buffer)]
  [with-phi-out : bool]) : bool
  (let
    [self-base : i64 (+ word-base (* (- g block-base) words))]
    [i : i64 0]
    [changed : bool false]
    (begin
      (live-out-into!
        scratch-out-buffer
        words
        g
        succ-start
        succ-items
        live-in-buffer
        word-base
        block-base
        phi-out
        with-phi-out)
      (let
        [uses (i64vec.slots-mut (&mut (struct-get uses-buffer values)))]
        [defs (i64vec.slots-mut (&mut (struct-get defs-buffer values)))]
        [live-in (i64vec.slots-mut (&mut (struct-get live-in-buffer values)))]
        [live-out (i64vec.slots-mut (&mut (struct-get live-out-buffer values)))]
        [scratch-out
          (i64vec.slots-mut (&mut (struct-get scratch-out-buffer values)))]
        [scratch-in
          (i64vec.slots-mut (&mut (struct-get scratch-in-buffer values)))]
        (begin
          (while (< i words)
            (begin
              (array-set!
                scratch-in
                i
                (bit-or
                  (array-ref uses (+ self-base i))
                  (bit-and
                    (array-ref scratch-out i)
                    (bit-xor (array-ref defs (+ self-base i)) -1))))
              (set! i (+ i 1))))
          (set! i 0)
          (while (and (< i words) (not changed))
            (begin
              (when
                (or
                  (!=
                    (array-ref scratch-in i)
                    (array-ref live-in (+ self-base i)))
                  (!=
                    (array-ref scratch-out i)
                    (array-ref live-out (+ self-base i))))
                (set! changed true))
              (set! i (+ i 1))))
          (when
            changed
            (let
              [k : i64 0]
              (while (< k words)
                (begin
                  (array-set! live-in (+ self-base k) (array-ref scratch-in k))
                  (array-set!
                    live-out
                    (+ self-base k)
                    (array-ref scratch-out k))
                  (set! k (+ k 1))))))
          changed)))))

(define (fixpoint!
  [block-base : i64]
  [blocks : i64]
  [words : i64]
  [word-base : i64]
  [succ-start : (&mut succ-start I64Buffer)]
  [succ-items : (&mut succ-items I64Buffer)]
  [pred-start-buffer : (&mut pred-start I64Buffer)]
  [pred-items-buffer : (&mut pred-items I64Buffer)]
  [uses : (&mut uses I64Buffer)]
  [defs : (&mut defs I64Buffer)]
  [phi-out : (&mut phi-out I64Buffer)]
  [live-in-buffer : (&mut live-in I64Buffer)]
  [live-out-buffer : (&mut live-out I64Buffer)]
  [pending-buffer : (&mut pending I64Buffer)]
  [scratch-out : (&mut scratch-out I64Buffer)]
  [scratch-in : (&mut scratch-in I64Buffer)]
  [with-phi-out : bool]) : unit
  (let
    [b : i64 0]
    [done : bool false]
    (begin
      (let
        [live-in (i64vec.slots-mut (&mut (struct-get live-in-buffer values)))]
        [live-out (i64vec.slots-mut (&mut (struct-get live-out-buffer values)))]
        [pending (i64vec.slots-mut (&mut (struct-get pending-buffer values)))]
        (begin
          (while (< b blocks)
            (let
              [self-base : i64 (+ word-base (* b words))]
              [k : i64 0]
              (begin
                (array-set! pending (+ block-base b) 1)
                (while (< k words)
                  (begin
                    (array-set! live-in (+ self-base k) 0)
                    (array-set! live-out (+ self-base k) 0)
                    (set! k (+ k 1))))
                (set! b (+ b 1)))))
          0))
      (while (not done)
        (let
          [index : i64
            (let
              [pending
                (i64vec.slots-mut (&mut (struct-get pending-buffer values)))]
              [found : i64 -1]
              [i : i64 (- blocks 1)]
              (begin
                (while (and (>= i 0) (< found 0))
                  (begin
                    (when
                      (= (array-ref pending (+ block-base i)) 1)
                      (begin
                        (array-set! pending (+ block-base i) 0)
                        (set! found i)))
                    (set! i (- i 1))))
                found))]
          (if (< index 0)
            (set! done true)
            (when
              (recompute!
                (+ block-base index)
                words
                word-base
                block-base
                succ-start
                succ-items
                uses
                defs
                phi-out
                live-in-buffer
                live-out-buffer
                scratch-out
                scratch-in
                with-phi-out)
              (let
                [pred-start
                  (i64vec.slots-mut
                    (&mut (struct-get pred-start-buffer values)))]
                [pred-items
                  (i64vec.slots-mut
                    (&mut (struct-get pred-items-buffer values)))]
                [pending
                  (i64vec.slots-mut (&mut (struct-get pending-buffer values)))]
                [g : i64 (+ block-base index)]
                [slot : i64 (array-ref pred-start g)]
                [stop : i64 (array-ref pred-start (+ g 1))]
                (begin
                  (while (< slot stop)
                    (begin
                      (array-set! pending (array-ref pred-items slot) 1)
                      (set! slot (+ slot 1))))
                  unit))))))
      unit)))