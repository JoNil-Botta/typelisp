(import compiler_spmd_logical_gang as gang)
(import compiler_spmd_numeric_policy as numeric)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.test)

(define (gang-test-plan
  [backend : numeric.CompilerSpmdNumericBackend]
  [width : i64]
  [lane : numeric.CompilerSpmdNumericLane]) : gang.CompilerSpmdGangPlan
  (match (gang.compiler-spmd-gang-plan backend width lane)
    [(Ok plan) plan]
    [(Err error) (io.panic (gang.compiler-spmd-gang-error-message error))]))

(define (gang-test-piece [plan : gang.CompilerSpmdGangPlan] [index : i64]) : gang.CompilerSpmdGangPiece
  (match (gang.compiler-spmd-gang-piece plan index)
    [(Ok piece) piece]
    [(Err error) (io.panic (gang.compiler-spmd-gang-error-message error))]))

(define (gang-test-bit [index : i64]) : u64
  (shl (cast 1 : u64) index))

;; Independent lane-by-lane oracle, including all unused physical lanes.
(define (gang-test-mask [plan : gang.CompilerSpmdGangPlan] [active : u64]) : unit
  (let
    [reconstructed : u64 (cast 0 : u64)]
    (for [index (iterator.range 0 plan.piece-count)]
      (let
        [piece : gang.CompilerSpmdGangPiece (gang-test-piece plan index)]
        [projected : u64
          (match (gang.compiler-spmd-gang-project-mask plan piece active)
            [(Ok bits) bits]
            [(Err error)
              (io.panic (gang.compiler-spmd-gang-error-message error))])]
        (for [physical (iterator.range 0 plan.physical-width)]
          (let
            [logical : i64 (+ piece.logical-start physical)]
            [expected : bool
              (and
                (< logical plan.logical-width)
                (!= (bit-and active (gang-test-bit logical)) (cast 0 : u64)))]
            (test.assert-bool-eq
              (!= (bit-and projected (gang-test-bit physical)) (cast 0 : u64))
              expected
              "mask projection preserves precisely the active logical lanes")))
        (set!
          reconstructed
          (bit-or reconstructed (shl projected piece.logical-start)))))
    (test.assert-true
      (= reconstructed active)
      "ordered pieces reconstruct the active set")))

(define (gang-test-geometry [plan : gang.CompilerSpmdGangPlan]) : unit
  (let
    [next : i64 0]
    (for [index (iterator.range 0 plan.piece-count)]
      (let
        [piece : gang.CompilerSpmdGangPiece (gang-test-piece plan index)]
        (test.assert-i64-eq
          piece.logical-start
          next
          "pieces are adjacent and ordered")
        (test.assert-i64-eq
          piece.physical-width
          plan.physical-width
          "native width is preserved")
        (test.assert-true (> piece.occupied-count 0) "no empty pieces")
        (test.assert-true
          (<= piece.occupied-count piece.physical-width)
          "occupied prefix fits")
        (for [_lane (iterator.range 0 piece.occupied-count)]
          (set! next (+ next 1)))
        (test.assert-i64-eq
          piece.mask.start
          piece.logical-start
          "mask begins at the logical origin")
        (test.assert-i64-eq
          piece.mask.count
          piece.occupied-count
          "mask covers occupied lanes")))
    (test.assert-i64-eq
      next
      plan.logical-width
      "each logical lane appears exactly once")))

(test
  spmd-gang-numeric-matrix-and-masks
  (let
    [lanes : (Array numeric.CompilerSpmdNumericLane 10)
      (array (I8) (U8) (I16) (U16) (I32) (U32) (I64) (U64) (F32) (F64))]
    [avx2-widths : (Array i64 10) (array 32 32 16 16 8 8 4 4 8 4)]
    [backends : (Array numeric.CompilerSpmdNumericBackend 3)
      (array (Scalar) (Avx2) (Avx512))]
    [widths : (Array i64 6) (array 1 4 8 16 32 64)]
    [rows : i64 0]
    (for [backend-index (iterator.range 0 3)]
      (for [lane-index (iterator.range 0 10)]
        (for [width-index
          (iterator.range
            0
            (if (= backend-index 0)
              1
              6))]
          (let
            [width : i64 (array-ref widths width-index)]
            [expected : i64
              (if (= backend-index 0)
                1
                (* backend-index (array-ref avx2-widths lane-index)))]
            [plan : gang.CompilerSpmdGangPlan
              (gang-test-plan
                (array-ref backends backend-index)
                width
                (array-ref lanes lane-index))]
            [prefix : u64 (cast 0 : u64)]
            [alternating : u64 (cast 0 : u64)]
            [edges : u64 (cast 0 : u64)]
            (set! rows (+ rows 1))
            (test.assert-i64-eq
              plan.physical-width
              expected
              "numeric native-width table")
            (gang-test-geometry plan)
            (gang-test-mask plan prefix)
            (for [logical (iterator.range 0 width)]
              (let
                [bit : u64 (gang-test-bit logical)]
                (gang-test-mask plan bit)
                (set! prefix (bit-or prefix bit))
                (gang-test-mask plan prefix)
                (when
                  (= (% logical 2) 0)
                  (set! alternating (bit-or alternating bit)))
                (when
                  (or (< logical 2) (= (% logical 7) 6) (= logical (- width 1)))
                  (set! edges (bit-or edges bit)))))
            (gang-test-mask plan alternating)
            (gang-test-mask plan (bit-xor alternating prefix))
            (gang-test-mask plan edges)))))
    (test.assert-i64-eq rows 130 "all admitted backend/type/width combinations")))

(test
  spmd-gang-coordinate-and-conversion-views
  (let
    [backends : (Array numeric.CompilerSpmdNumericBackend 2)
      (array (Avx2) (Avx512))]
    [widths : (Array i64 2) (array 32 64)]
    (for [index (iterator.range 0 2)]
      (let
        [backend : numeric.CompilerSpmdNumericBackend
          (array-ref backends index)]
        [width : i64 (array-ref widths index)]
        [body : gang.CompilerSpmdGangPlan (gang-test-plan backend width (I8))]
        [coordinate : gang.CompilerSpmdGangPlan
          (gang-test-plan backend width (I64))]
        [narrow : gang.CompilerSpmdGangPlan
          (gang-test-plan backend coordinate.physical-width (I8))]
        [first : gang.CompilerSpmdGangPiece (gang-test-piece narrow 0)]
        (test.assert-i64-eq body.piece-count 1 "one narrow body gang")
        (test.assert-i64-eq
          coordinate.piece-count
          8
          "eight ordered i64 coordinate pieces")
        (test.assert-i64-eq
          narrow.piece-count
          1
          "narrowing uses one partly occupied piece")
        (test.assert-i64-eq
          first.occupied-count
          coordinate.physical-width
          "narrowing retains logical width")
        (test.assert-i64-eq
          first.physical-width
          width
          "narrowing retains native physical width")))))

(define (gang-test-plan-error
  [result : gang.ResultCompilerSpmdGangPlan]
  [expected : gang.CompilerSpmdGangError]) : unit
  (test.assert-true
    (match result
      [(Err error) (= error expected)]
      [_ false])
    "invalid construction reports the focused error"))

(define (gang-test-validation-error
  [result : gang.ResultCompilerSpmdGangValidation]
  [expected : gang.CompilerSpmdGangError]) : unit
  (test.assert-true
    (match result
      [(Err error) (= error expected)]
      [_ false])
    "malformed descriptor reports the focused error"))

(test
  spmd-gang-invalid-input-and-overflow
  (let
    [widths : (Array i64 10)
      (array -9223372036854775808 -1 0 2 3 5 63 65 128 9223372036854775807)]
    [lanes : (Array numeric.CompilerSpmdNumericLane 3)
      (array (Bool) (Char) (Other))]
    [backends : (Array numeric.CompilerSpmdNumericBackend 3)
      (array (Scalar) (Avx2) (Avx512))]
    (for [backend-index (iterator.range 0 3)]
      (let
        [backend : numeric.CompilerSpmdNumericBackend
          (array-ref backends backend-index)]
        (for [index (iterator.range 0 (array-length widths))]
          (gang-test-plan-error
            (gang.compiler-spmd-gang-plan
              backend
              (array-ref widths index)
              (I64))
            (LogicalWidth)))
        (for [index (iterator.range 0 3)]
          (gang-test-plan-error
            (gang.compiler-spmd-gang-plan backend 1 (array-ref lanes index))
            (UnsupportedLane)))))
    (for [width (iterator.range 4 65)]
      (when
        (or (= width 4) (= width 8) (= width 16) (= width 32) (= width 64))
        (gang-test-plan-error
          (gang.compiler-spmd-gang-plan (Scalar) width (I8))
          (ScalarWidth)))))
  (let
    [valid : gang.CompilerSpmdGangPlan (gang-test-plan (Avx2) 32 (I64))]
    [bad-values : (Array i64 6)
      (array -9223372036854775808 -1 0 3 65 9223372036854775807)]
    (for [index (iterator.range 0 (array-length bad-values))]
      (let
        [value : i64 (array-ref bad-values index)]
        [bad-width : gang.CompilerSpmdGangPlan
          (gang.CompilerSpmdGangPlan (Avx2) (I64) 32 value 8)]
        [bad-count : gang.CompilerSpmdGangPlan
          (gang.CompilerSpmdGangPlan (Avx2) (I64) 32 4 value)]
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate bad-width)
          (PhysicalWidth))
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate bad-count)
          (PieceCount))
        (test.assert-true
          (match (gang.compiler-spmd-gang-piece bad-width value)
            [(Err (PhysicalWidth)) true]
            [_ false])
          "validate width before division or index multiplication")))
    (let
      [indices : (Array i64 4)
        (array -9223372036854775808 -1 8 9223372036854775807)]
      (for [index (iterator.range 0 4)]
        (test.assert-true
          (match (gang.compiler-spmd-gang-piece valid (array-ref indices index))
            [(Err (PieceIndex)) true]
            [_ false])
          "invalid piece indices never reach arithmetic")))))

(test
  spmd-gang-malformed-pieces-and-masks
  (let
    [plan : gang.CompilerSpmdGangPlan (gang-test-plan (Avx2) 8 (I64))]
    [values : (Array i64 8)
      (array -9223372036854775808 -1 0 1 3 5 8 9223372036854775807)]
    (for [index (iterator.range 0 (array-length values))]
      (let
        [value : i64 (array-ref values index)]
        [piece : gang.CompilerSpmdGangPiece (gang-test-piece plan 1)]
        (set! piece.logical-start value)
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate-piece plan piece)
          (if (= value 0)
            (MaskSpan)
            (PieceCoverage)))
        (set! piece (gang-test-piece plan 1))
        (set! piece.occupied-count value)
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate-piece plan piece)
          (PieceCoverage))
        (set! piece (gang-test-piece plan 1))
        (set! piece.physical-width value)
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate-piece plan piece)
          (PieceCoverage))
        (set! piece (gang-test-piece plan 1))
        (set! piece.mask.start value)
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate-piece plan piece)
          (MaskSpan))
        (test.assert-true
          (match (gang.compiler-spmd-gang-project-mask
            plan
            piece
            (cast 0 : u64))
            [(Err (MaskSpan)) true]
            [_ false])
          "invalid mask offsets cannot reach shifts")
        (set! piece (gang-test-piece plan 1))
        (set! piece.mask.count value)
        (gang-test-validation-error
          (gang.compiler-spmd-gang-validate-piece plan piece)
          (MaskSpan)))))
  (let
    [widths : (Array i64 5) (array 1 4 8 16 32)]
    (for [index (iterator.range 0 5)]
      (let
        [width : i64 (array-ref widths index)]
        [plan : gang.CompilerSpmdGangPlan (gang-test-plan (Avx512) width (I8))]
        [piece : gang.CompilerSpmdGangPiece (gang-test-piece plan 0)]
        (test.assert-true
          (match (gang.compiler-spmd-gang-project-mask
            plan
            piece
            (gang-test-bit width))
            [(Err (MaskWidth)) true]
            [_ false])
          "a bit just outside the logical gang is rejected")))))

(test
  spmd-gang-stable-diagnostics
  (let
    [errors : (Array gang.CompilerSpmdGangError 9)
      (array
        (UnsupportedLane)
        (LogicalWidth)
        (ScalarWidth)
        (PhysicalWidth)
        (PieceCount)
        (PieceIndex)
        (PieceCoverage)
        (MaskSpan)
        (MaskWidth))]
    [messages : (Array String 9)
      (array
        "SPMD gang: expected a numeric lane type"
        "SPMD gang: logical width must be 1, 4, 8, 16, 32, or 64"
        "SPMD gang: scalar backend requires logical width 1"
        "SPMD gang: physical width disagrees with backend and lane type"
        "SPMD gang: piece count does not cover the logical width"
        "SPMD gang: piece index is out of range"
        "SPMD gang: piece does not match ordered logical coverage"
        "SPMD gang: mask span does not match occupied lanes"
        "SPMD gang: active mask exceeds logical width")]
    (for [index (iterator.range 0 9)]
      (test.assert-owned-string-eq
        (gang.compiler-spmd-gang-error-message (array-ref errors index))
        (clone (array-ref messages index))
        "stable planner diagnostic"))))