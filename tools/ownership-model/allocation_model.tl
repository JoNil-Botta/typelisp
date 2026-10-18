;; Independent allocation/provenance model for sanitizer observability (#8449).
;; It imports no compiler or runtime implementation. Time intervals describe
;; concrete allocation lifetimes; page accessibility is a separate observation.
(import stdlib.io)

(defstruct Allocation
  (owner i64)
  (generation i64)
  (serial i64)
  (base i64)
  (length i64)
  (created i64)
  (retired i64))

(defstruct Pointer
  (owner i64)
  (generation i64)
  (serial i64)
  (offset i64))

;; A nonzero access belongs to one exact allocation, not merely a mapped page.
;; Subtraction avoids overflow when an adversarial width is near MAX_I64.
(define (allocation-allows?
  [allocation : Allocation]
  [pointer : Pointer]
  [time : i64]
  [width : i64]) : bool
  (and
    (= allocation.owner pointer.owner)
    (= allocation.generation pointer.generation)
    (= allocation.serial pointer.serial)
    (>= time allocation.created)
    (< time allocation.retired)
    (> width 0)
    (>= pointer.offset 0)
    (<= width allocation.length)
    (<= pointer.offset (- allocation.length width))))

;; This observation deliberately lacks authority. A neighboring allocation or
;; a later generation may keep the same hardware page readable.
(define (page-readable? [address : i64] [page-first : i64] [page-limit : i64]) : bool
  (and (>= address page-first) (< address page-limit)))

(define (allocation-cases) : i64
  (let
    [size : i64 1]
    [cases : i64 0]
    [mapped-invalid : i64 0]
    (begin
      (while (<= size 4)
        (let
          [offset : i64 -1]
          (while (<= offset 5)
            (let
              [width : i64 1]
              (while (<= width 3)
                (let
                  [old : Allocation (Allocation 1 1 1 8 size 0 2)]
                  [replacement : Allocation (Allocation 1 1 2 8 size 3 5)]
                  [next-owner : Allocation (Allocation 1 2 1 8 size 6 8)]
                  [neighbor : Allocation (Allocation 2 1 1 12 4 0 8)]
                  [pointer : Pointer (Pointer 1 1 1 offset)]
                  [time : i64 0]
                  [inside
                    : bool
                    ;; Enumerate the referenced bytes, independently of the
                    ;; constant-time subtraction used by allocation-allows?.
                    (let
                      [byte : i64 offset]
                      [valid : bool true]
                      (begin
                        (while (< byte (+ offset width))
                          (begin
                            (unless
                              (and (>= byte 0) (< byte size))
                              (set! valid false))
                            (set! byte (+ byte 1))))
                        valid))]
                  (begin
                    (while (< time 8)
                      (let
                        [expected : bool (and (< time 2) inside)]
                        [actual : bool
                          (allocation-allows? old pointer time width)]
                        (begin
                          (unless (= actual expected) (return -1))
                          ;; Rewind/reuse, owner retirement/reuse, and another
                          ;; live owner never restore this pointer's authority.
                          (when
                            (allocation-allows? replacement pointer time width)
                            (return -2))
                          (when
                            (allocation-allows? next-owner pointer time width)
                            (return -3))
                          (when
                            (allocation-allows? neighbor pointer time width)
                            (return -4))
                          (when
                            (and
                              (not expected)
                              (page-readable? (+ 8 offset) 0 16))
                            (set! mapped-invalid (+ mapped-invalid 1)))
                          (set! cases (+ cases 1))
                          (set! time (+ time 1)))))
                    (set! width (+ width 1)))))
              (set! offset (+ offset 1)))))
        (set! size (+ size 1)))
      (if (and (= cases 672) (> mapped-invalid 0))
        cases
        -5))))

(define (allocation-controls?) : bool
  (let
    [a : Allocation (Allocation 1 1 1 8 8 0 4)]
    [p : Pointer (Pointer 1 1 1 0)]
    (and
      (allocation-allows? a p 0 8)
      (not (allocation-allows? a p -1 1))
      (not (allocation-allows? a p 4 1))
      (not (allocation-allows? a p 0 0))
      (not (allocation-allows? a p 0 -1))
      (not (allocation-allows? a p 0 9223372036854775807))
      (not (allocation-allows? a (Pointer 1 1 1 9223372036854775807) 0 2))
      (not (allocation-allows? a (Pointer 1 1 1 -1) 0 1))
      (not (allocation-allows? a (Pointer 1 1 1 8) 0 1))
      (not (allocation-allows? a (Pointer 2 1 1 0) 0 1))
      (not (allocation-allows? a (Pointer 1 2 1 0) 0 1))
      (not (allocation-allows? a (Pointer 1 1 2 0) 0 1)))))

;; Rewind may share a page with live prefix bytes. Quarantine never makes an
;; accepted reference invalid; however page protection cannot distinguish two
;; suballocations on that shared page. Poison is also not a universal oracle:
;; the stale program could legitimately expect the poison byte itself.
(define (allocation-observability?) : bool
  (let
    [page-size : i64 1]
    [cases : i64 0]
    [invisible : i64 0]
    (begin
      (while (<= page-size 8)
        (let
          [mark : i64 0]
          (while (< mark (* 2 page-size))
            (let
              [byte : i64 0]
              (while (< byte (* 3 page-size))
                (let
                  [page-start : i64 (* (/ byte page-size) page-size)]
                  [live? : bool (< byte mark)]
                  [protected? : bool (>= page-start mark)]
                  (begin
                    (when (and live? protected?) (return false))
                    (when
                      (and (not live?) (not protected?))
                      (set! invisible (+ invisible 1)))
                    (set! cases (+ cases 1))
                    (set! byte (+ byte 1)))))
              (set! mark (+ mark 1)))))
        (set! page-size (+ page-size 1)))
      (and (= cases 1224) (> invisible 0)))))

(define (main) : i64
  (if (and
    (= (allocation-cases) 672)
    (allocation-controls?)
    (allocation-observability?))
    (begin
      (io.println
        "ownership-allocation-model-v1: lifetimes=672 controls=12 page-cases=1224 passed")
      0)
    1))