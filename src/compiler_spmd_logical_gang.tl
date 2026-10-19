;; Logical gang geometry shared by lowering, numeric conversions (#7163), and
;; tiled coordinates (#7192). No IR values or target register halves belong here.
(import compiler_spmd_numeric_policy as numeric)

(defstruct CompilerSpmdGangPlan
  (backend numeric.CompilerSpmdNumericBackend)
  (lane numeric.CompilerSpmdNumericLane)
  (logical-width i64)
  (physical-width i64)
  (piece-count i64))

;; Copy logical [start, start + count) into physical [0, count), then clear
;; every other physical lane. This recipe does not assume an active prefix.
(defstruct CompilerSpmdMaskProjection
  (start i64)
  (count i64))

(defstruct CompilerSpmdGangPiece
  (logical-start i64)
  (occupied-count i64)
  (physical-width i64)
  (mask CompilerSpmdMaskProjection))

(defenum CompilerSpmdGangError
  (UnsupportedLane)
  (LogicalWidth)
  (ScalarWidth)
  (PhysicalWidth)
  (PieceCount)
  (PieceIndex)
  (PieceCoverage)
  (MaskSpan)
  (MaskWidth))

(defenum ResultCompilerSpmdGangPlan
  (Ok CompilerSpmdGangPlan)
  (Err CompilerSpmdGangError))

(defenum ResultCompilerSpmdGangPiece
  (Ok CompilerSpmdGangPiece)
  (Err CompilerSpmdGangError))

(defenum ResultCompilerSpmdGangValidation
  (Ok)
  (Err CompilerSpmdGangError))

(defenum ResultCompilerSpmdGangMask
  (Ok u64)
  (Err CompilerSpmdGangError))

;; Backend is a closed enum: unsupported modes cannot enter the planner. ABI
;; selection stays in the lowerer, so Linux/Windows share this exact table.
(define (compiler-spmd-native-lanes
  [backend : numeric.CompilerSpmdNumericBackend]
  [lane : numeric.CompilerSpmdNumericLane]) : i64
  (let
    [bytes : i64
      (match lane
        [(or (I8) (U8)) 1]
        [(or (I16) (U16)) 2]
        [(or (I32) (U32) (F32)) 4]
        [(or (I64) (U64) (F64)) 8]
        [(or (Bool) (Char) (Other)) 0])]
    (if (= bytes 0)
      0
      (match backend
        [(Scalar) 1]
        [(Avx2) (/ 32 bytes)]
        [(Avx512) (/ 64 bytes)]))))

(define (compiler-spmd-gang-plan
  [backend : numeric.CompilerSpmdNumericBackend]
  [width : i64]
  [lane : numeric.CompilerSpmdNumericLane]) : ResultCompilerSpmdGangPlan
  (let
    [physical : i64 (compiler-spmd-native-lanes backend lane)]
    (cond
      [(= physical 0) (Err (UnsupportedLane))]
      [(not
          (or
            (= width 1)
            (= width 4)
            (= width 8)
            (= width 16)
            (= width 32)
            (= width 64)))
        (Err (LogicalWidth))]
      [(and (= physical 1) (!= width 1)) (Err (ScalarWidth))]
      [else
        ;; Admission bounds both operands to 1..64 before division/arithmetic.
        ;; The indexed sequence needs no mutable storage or allocation history.
        (Ok
          (CompilerSpmdGangPlan
            backend
            lane
            width
            physical
            (+ 1 (/ (- width 1) physical))))])))

(define (compiler-spmd-gang-validate [plan : CompilerSpmdGangPlan]) : ResultCompilerSpmdGangValidation
  (match (compiler-spmd-gang-plan plan.backend plan.logical-width plan.lane)
    [(Err error) (Err error)]
    [(Ok expected)
      (cond
        [(!= plan.physical-width expected.physical-width) (Err (PhysicalWidth))]
        [(!= plan.piece-count expected.piece-count) (Err (PieceCount))]
        [else (Ok)])]))

;; A plan is a value descriptor, never mutated by this API. Its ordered pieces
;; are accessed at indices 0..piece-count; validation also protects consumers
;; from manually constructed or corrupted internal descriptors.
(define (compiler-spmd-gang-piece [plan : CompilerSpmdGangPlan] [index : i64]) : ResultCompilerSpmdGangPiece
  (match (compiler-spmd-gang-validate plan)
    [(Err error) (Err error)]
    [(Ok)
      (if (or (< index 0) (>= index plan.piece-count))
        (Err (PieceIndex))
        (let
          [start : i64 (* index plan.physical-width)]
          [remaining : i64 (- plan.logical-width start)]
          [occupied : i64
            (if (< remaining plan.physical-width)
              remaining
              plan.physical-width)]
          (Ok
            (CompilerSpmdGangPiece
              start
              occupied
              plan.physical-width
              (CompilerSpmdMaskProjection start occupied)))))]))

(define (compiler-spmd-gang-validate-piece
  [plan : CompilerSpmdGangPlan]
  [piece : CompilerSpmdGangPiece]) : ResultCompilerSpmdGangValidation
  (match (compiler-spmd-gang-validate plan)
    [(Err error) (Err error)]
    [(Ok)
      (cond
        [(or
            (< piece.logical-start 0)
            (>= piece.logical-start plan.logical-width))
          (Err (PieceCoverage))]
        [(!= (% piece.logical-start plan.physical-width) 0)
          (Err (PieceCoverage))]
        [else
          (match (compiler-spmd-gang-piece
            plan
            (/ piece.logical-start plan.physical-width))
            [(Err error) (Err error)]
            [(Ok expected)
              (cond
                [(or
                    (!= piece.occupied-count expected.occupied-count)
                    (!= piece.physical-width expected.physical-width))
                  (Err (PieceCoverage))]
                [(or
                    (!= piece.mask.start expected.mask.start)
                    (!= piece.mask.count expected.mask.count))
                  (Err (MaskSpan))]
                [else (Ok)])])])]))

(define (compiler-spmd-gang-project-mask
  [plan : CompilerSpmdGangPlan]
  [piece : CompilerSpmdGangPiece]
  [active : u64]) : ResultCompilerSpmdGangMask
  (match (compiler-spmd-gang-validate-piece plan piece)
    [(Err error) (Err error)]
    [(Ok)
      ;; Never shift by 64: width 64 admits all u64 masks, while every piece
      ;; starts below 64. Validation bounds the span before either shift.
      (if (and
        (< plan.logical-width 64)
        (!= (shr active plan.logical-width) (cast 0 : u64)))
        (Err (MaskWidth))
        (let
          [occupied : u64
            (if (= piece.mask.count 64)
              (cast -1 : u64)
              (- (shl (cast 1 : u64) piece.mask.count) (cast 1 : u64)))]
          (Ok (bit-and (shr active piece.mask.start) occupied))))]))

(define (compiler-spmd-gang-error-message [error : CompilerSpmdGangError]) : String
  (match error
    [(UnsupportedLane) "SPMD gang: expected a numeric lane type"]
    [(LogicalWidth) "SPMD gang: logical width must be 1, 4, 8, 16, 32, or 64"]
    [(ScalarWidth) "SPMD gang: scalar backend requires logical width 1"]
    [(PhysicalWidth)
      "SPMD gang: physical width disagrees with backend and lane type"]
    [(PieceCount) "SPMD gang: piece count does not cover the logical width"]
    [(PieceIndex) "SPMD gang: piece index is out of range"]
    [(PieceCoverage) "SPMD gang: piece does not match ordered logical coverage"]
    [(MaskSpan) "SPMD gang: mask span does not match occupied lanes"]
    [(MaskWidth) "SPMD gang: active mask exceeds logical width"]))