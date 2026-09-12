(defstruct Packet
  (:repr c)
  (:must-use)
  (count i64)
  (weight f64))

(defenum Choice
  (:must-use)
  (None)
  (Some Packet))

(define (make-packet [count : i64]) : Packet
  (Packet count 3.5))

(define (choose [count : i64]) : Choice
  (Some (make-packet count)))

(define (layout-ok?) : bool
  (and
    (= (comptime (size-of (type Packet))) 16)
    (= (comptime (align-of (type Packet))) 8)
    (= (comptime (offset-of (type Packet) weight)) 8)
    (= (comptime (size-of (type Choice))) 24)
    (= (comptime (align-of (type Choice))) 8)))

(define (main) : i64
  (if (layout-ok?)
    (match (choose 7)
      [(Some packet) packet.count]
      [None 0])
    1))