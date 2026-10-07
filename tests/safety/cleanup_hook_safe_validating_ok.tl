;; A safe cleanup hook may discharge its own unsafety: it validates what it
;; touches and calls the unsafe primitive inside `unsafe` (#8267).
(define closed : i64
  0)

(unsafe
  (define (raw-close [fd : i64]) : unit
    (set! closed (+ closed fd))))

(define (checked-close [fd : i64]) : unit
  (if (> fd 0)
    (unsafe
      (raw-close fd))
    unit))

(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup checked-close)))

(define (main) : i64
  (begin
    (with ([h (Handle 40) close-handle]) unit)
    (+ closed 2)))