;; Focused valid/malformed fixtures for git_delta_core.
(import git_delta_core as git_delta)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (git-delta-test-limits) : git_delta.GitDeltaLimits
  (git_delta.GitDeltaLimits
    200000
    200000
    32
    10000
    10000000
    10000
    200000
    10000000))

(define (git-delta-test-push!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf.byte-buf-builder-push out (cast value : u8)))

(define (git-delta-test-append-size-varint!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [input : i64]) : unit
  (let
    [value : i64 input]
    [done : bool false]
    (while (not done)
      (let
        [next : i64 (shr value 7)]
        [octet : i64 (bit-and value 127)]
        (begin
          (git-delta-test-push!
            out
            (if (> next 0)
              (bit-or octet 128)
              octet))
          (set! value next)
          (if (= next 0)
            (set! done true)
            unit))))))

(define (git-delta-test-size-varint [value : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    (begin
      (git-delta-test-append-size-varint! (&mut out) value)
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-ofs-varint [input : i64]) : String
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 10)]
    [index : i64 9]
    [value : i64 input]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    (begin
      (set! (array-ref slots index) (cast (bit-and value 127) : u8))
      (set! value (shr value 7))
      (while (> value 0)
        (begin
          (set! value (- value 1))
          (set! index (- index 1))
          (set!
            (array-ref slots index)
            (cast (bit-or (bit-and value 127) 128) : u8))
          (set! value (shr value 7))))
      (byte_buf.byte-buf-builder-append-array-range
        (&mut out)
        (& slots)
        index
        (- 10 index))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-repeat-byte [value : i64] [count : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (git-delta-test-push! (&mut out) value)
          (set! index (+ index 1))))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-insert-delta
  [base-length : i64]
  [output : (& output str)]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [length : i64 (string.string-length output)]
    (begin
      (git-delta-test-append-size-varint! (&mut out) base-length)
      (git-delta-test-append-size-varint! (&mut out) length)
      (if (> length 0)
        (begin
          (git-delta-test-push! (&mut out) length)
          (let
            [index : i64 0]
            (while (< index length)
              (begin
                (git-delta-test-push!
                  (&mut out)
                  (cast (string.string-ref output index) : i64))
                (set! index (+ index 1))))))
        unit)
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-copy-delta
  [base-length : i64]
  [copy-offset : i64]
  [copy-size : i64]
  [mask : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [declared-size : i64
      (if (= copy-size 0)
        65536
        copy-size)]
    (begin
      (git-delta-test-append-size-varint! (&mut out) base-length)
      (git-delta-test-append-size-varint! (&mut out) declared-size)
      (git-delta-test-push! (&mut out) (bit-or 128 mask))
      (if (!= (bit-and mask 1) 0)
        (git-delta-test-push! (&mut out) (bit-and copy-offset 255))
        unit)
      (if (!= (bit-and mask 2) 0)
        (git-delta-test-push! (&mut out) (bit-and (shr copy-offset 8) 255))
        unit)
      (if (!= (bit-and mask 4) 0)
        (git-delta-test-push! (&mut out) (bit-and (shr copy-offset 16) 255))
        unit)
      (if (!= (bit-and mask 8) 0)
        (git-delta-test-push! (&mut out) (bit-and (shr copy-offset 24) 255))
        unit)
      (if (!= (bit-and mask 16) 0)
        (git-delta-test-push! (&mut out) (bit-and copy-size 255))
        unit)
      (if (!= (bit-and mask 32) 0)
        (git-delta-test-push! (&mut out) (bit-and (shr copy-size 8) 255))
        unit)
      (if (!= (bit-and mask 64) 0)
        (git-delta-test-push! (&mut out) (bit-and (shr copy-size 16) 255))
        unit)
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-bytes-error? [result : git_delta.ResultGitDeltaBytes]) : bool
  (match result
    [(git_delta.ResultGitDeltaBytes.Err _) true]
    [(git_delta.ResultGitDeltaBytes.Ok _) false]))

(define (git-delta-test-resolve-error?
  [result : git_delta.ResultGitDeltaResolvedSet]) : bool
  (match result
    [(git_delta.ResultGitDeltaResolvedSet.Err _) true]
    [(git_delta.ResultGitDeltaResolvedSet.Ok _) false]))

(define (git-delta-test-varint-value? [value : i64] [expected-length : i64]) : bool
  (let
    [encoded : String (git-delta-test-size-varint value)]
    (match (git_delta.git-delta-read-size-varint (& encoded) 0)
      [(git_delta.ResultGitDeltaVarint.Err _) false]
      [(git_delta.ResultGitDeltaVarint.Ok decoded)
        (and (= decoded.value value) (= decoded.next expected-length))])))

(define (git-delta-test-varints?) : bool
  (let
    [truncated : String (git-delta-test-repeat-byte 128 1)]
    [excessive : String (git-delta-test-repeat-byte 128 10)]
    [overflow-builder : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [index : i64 0]
    (begin
      (while (< index 9)
        (begin
          (git-delta-test-push! (&mut overflow-builder) 128)
          (set! index (+ index 1))))
      (git-delta-test-push! (&mut overflow-builder) 1)
      (let
        [overflow : String
          (byte_buf.byte-buf-builder-finish-string (& overflow-builder))]
        (and
          (git-delta-test-varint-value? 0 1)
          (git-delta-test-varint-value? 127 1)
          (git-delta-test-varint-value? 128 2)
          (git-delta-test-varint-value? 16383 2)
          (git-delta-test-varint-value? 16384 3)
          (git-delta-test-varint-value? 9223372036854775807 9)
          (match (git_delta.git-delta-read-size-varint (& truncated) 0)
            [(git_delta.ResultGitDeltaVarint.Err _) true]
            [_ false])
          (match (git_delta.git-delta-read-size-varint (& excessive) 0)
            [(git_delta.ResultGitDeltaVarint.Err _) true]
            [_ false])
          (match (git_delta.git-delta-read-size-varint (& overflow) 0)
            [(git_delta.ResultGitDeltaVarint.Err _) true]
            [_ false])
          (match (git_delta.git-delta-read-size-varint (& truncated) -1)
            [(git_delta.ResultGitDeltaVarint.Err _) true]
            [_ false]))))))

(define (git-delta-test-ofs-value? [distance : i64]) : bool
  (let
    [encoded : String (git-delta-test-ofs-varint distance)]
    [object-offset : i64
      (if (> distance 9223372036854775802)
        9223372036854775807
        (+ distance 5))]
    (match (git_delta.git-delta-read-ofs-base (& encoded) 0 object-offset)
      [(git_delta.ResultGitDeltaOfsBase.Err _) false]
      [(git_delta.ResultGitDeltaOfsBase.Ok decoded)
        (and
          (= decoded.distance distance)
          (= decoded.base-offset (- object-offset distance))
          (= decoded.next (string.string-length encoded)))])))

(define (git-delta-test-ofs?) : bool
  (let
    [zero : String (git-delta-test-repeat-byte 0 1)]
    [truncated : String (git-delta-test-repeat-byte 128 1)]
    [too-far : String (git-delta-test-ofs-varint 129)]
    [excessive : String (git-delta-test-repeat-byte 255 9)]
    (and
      (git-delta-test-ofs-value? 1)
      (git-delta-test-ofs-value? 127)
      (git-delta-test-ofs-value? 128)
      (git-delta-test-ofs-value? 129)
      (git-delta-test-ofs-value? 16384)
      (git-delta-test-ofs-value? 9223372036854775807)
      (match (git_delta.git-delta-read-ofs-base (& zero) 0 10)
        [(git_delta.ResultGitDeltaOfsBase.Err _) true]
        [_ false])
      (match (git_delta.git-delta-read-ofs-base (& truncated) 0 10)
        [(git_delta.ResultGitDeltaOfsBase.Err _) true]
        [_ false])
      (match (git_delta.git-delta-read-ofs-base (& too-far) 0 128)
        [(git_delta.ResultGitDeltaOfsBase.Err _) true]
        [_ false])
      (match (git_delta.git-delta-read-ofs-base (& excessive) 0 1000)
        [(git_delta.ResultGitDeltaOfsBase.Err _) true]
        [_ false]))))

(define (git-delta-test-copy-combinations?) : bool
  (let
    [base : String (git-delta-test-repeat-byte 120 132000)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [mask : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< mask 128))
        (let
          [offset : i64
            (+
              (+
                (if (!= (bit-and mask 1) 0)
                  1
                  0)
                (if (!= (bit-and mask 2) 0)
                  256
                  0))
              (if (!= (bit-and mask 4) 0)
                65536
                0))]
          [size : i64
            (+
              (+
                (if (!= (bit-and mask 16) 0)
                  1
                  0)
                (if (!= (bit-and mask 32) 0)
                  256
                  0))
              (if (!= (bit-and mask 64) 0)
                65536
                0))]
          [expected-size : i64
            (if (= size 0)
              65536
              size)]
          [delta : String (git-delta-test-copy-delta 132000 offset size mask)]
          (begin
            (match (git_delta.git-delta-apply (& base) (& delta) (& limits))
              [(git_delta.ResultGitDeltaBytes.Err _) (set! ok false)]
              [(git_delta.ResultGitDeltaBytes.Ok object)
                (if (or
                  (!= (string.string-length object) expected-size)
                  (!= (cast (string.string-ref object 0) : i64) 120))
                  (set! ok false)
                  unit)])
            (set! mask (+ mask 1)))))
      ok)))

(define (git-delta-test-raw-delta
  [base-length : i64]
  [result-length : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [count : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    (begin
      (git-delta-test-append-size-varint! (&mut out) base-length)
      (git-delta-test-append-size-varint! (&mut out) result-length)
      (if (> count 0)
        (git-delta-test-push! (&mut out) a)
        unit)
      (if (> count 1)
        (git-delta-test-push! (&mut out) b)
        unit)
      (if (> count 2)
        (git-delta-test-push! (&mut out) c)
        unit)
      (if (> count 3)
        (git-delta-test-push! (&mut out) d)
        unit)
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-delta-test-apply-errors?) : bool
  (let
    [base : String "A"]
    [empty : String ""]
    [valid : String (git-delta-test-raw-delta 1 2 2 65 66 0 3)]
    [base-mismatch : String (git-delta-test-raw-delta 2 1 1 65 0 0 2)]
    [reserved : String (git-delta-test-raw-delta 1 1 0 0 0 0 1)]
    [truncated-insert : String (git-delta-test-raw-delta 1 2 2 65 0 0 2)]
    [truncated-copy : String (git-delta-test-raw-delta 1 1 145 0 0 0 1)]
    [outside-copy : String (git-delta-test-raw-delta 1 1 145 1 1 0 3)]
    [long-insert : String (git-delta-test-raw-delta 1 1 2 65 66 0 3)]
    [short-output : String (git-delta-test-raw-delta 1 2 1 65 0 0 2)]
    [trailing : String (git-delta-test-raw-delta 1 1 1 65 0 0 3)]
    [copy-base : String (git-delta-test-repeat-byte 120 100)]
    [copy : String (git-delta-test-copy-delta 100 0 100 16)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [base-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [result-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [delta-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [ratio-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [instruction-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [copy-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [work-limit : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [invalid-limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set! base-limit.max-object-bytes 0)
      (set! result-limit.max-object-bytes 1)
      (set! delta-limit.max-delta-bytes (- (string.string-length valid) 1))
      (set! ratio-limit.max-expansion-ratio 10)
      (set! instruction-limit.max-instructions 0)
      (set! copy-limit.max-copied-bytes 99)
      (set! work-limit.max-total-work 104)
      (set! invalid-limits.max-expansion-ratio 0)
      (and
        (match (git_delta.git-delta-apply (& base) (& valid) (& limits))
          [(git_delta.ResultGitDeltaBytes.Ok object) (string.eq object "AB")]
          [_ false])
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& empty) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& base-mismatch) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& reserved) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& truncated-insert) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& truncated-copy) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& outside-copy) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& long-insert) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& short-output) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& trailing) (& limits)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& valid) (& base-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& valid) (& result-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& valid) (& delta-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& copy-base) (& copy) (& ratio-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply
            (& copy-base)
            (& copy)
            (& instruction-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& copy-base) (& copy) (& copy-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& copy-base) (& copy) (& work-limit)))
        (git-delta-test-bytes-error?
          (git_delta.git-delta-apply (& base) (& valid) (& invalid-limits)))))))

(define (git-delta-test-malformed-corpus?) : bool
  (let
    [base : String "x"]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    [opcode : i64 0]
    [ok : bool true]
    (begin
      ;; Every possible single trailing opcode is incomplete, reserved, or an
      ;; out-of-range default copy for this one-byte base. None may trap.
      (while (and ok (< opcode 256))
        (let
          [delta : String (git-delta-test-raw-delta 1 1 opcode 0 0 0 1)]
          (begin
            (if (not
              (git-delta-test-bytes-error?
                (git_delta.git-delta-apply (& base) (& delta) (& limits))))
              (set! ok false)
              unit)
            (set! opcode (+ opcode 1)))))
      (let
        [valid : String (git-delta-test-insert-delta 1 "xy")]
        [length : i64 (string.string-length valid)]
        [cut : i64 0]
        (begin
          (while (and ok (< cut length))
            (let
              [prefix : String (string.substring (& valid) 0 cut)]
              (begin
                (if (not
                  (git-delta-test-bytes-error?
                    (git_delta.git-delta-apply (& base) (& prefix) (& limits))))
                  (set! ok false)
                  unit)
                (set! cut (+ cut 1)))))
          ok)))))

(define (git-delta-test-empty-offsets) : (__tl_dyn-array
    git_delta.GitDeltaOffsetLookup)
  (__tl_make-array git_delta.GitDeltaOffsetLookup 0))

(define (git-delta-test-empty-ids) : (__tl_dyn-array git_delta.GitDeltaIdLookup)
  (__tl_make-array git_delta.GitDeltaIdLookup 0))

(define (git-delta-test-empty-thin) : (__tl_dyn-array
    git_delta.GitDeltaThinBase)
  (__tl_make-array git_delta.GitDeltaThinBase 0))

(define (git-delta-test-mixed-resolver?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 5)]
    [offsets : (__tl_dyn-array git_delta.GitDeltaOffsetLookup)
      (__tl_make-array git_delta.GitDeltaOffsetLookup 1)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 2)]
    [thin : (__tl_dyn-array git_delta.GitDeltaThinBase)
      (__tl_make-array git_delta.GitDeltaThinBase 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "id-a"
          (git_delta.GitDeltaEntryBody.Stored
            (git_delta.GitDeltaObjectKind.Blob)
            "A")))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "id-b"
          (git_delta.GitDeltaEntryBody.Ofs
            10
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "AB"))))
      (set!
        (array-ref entries 2)
        (git_delta.GitDeltaEntry
          30
          "id-c"
          (git_delta.GitDeltaEntryBody.Ref
            "id-b"
            (git_delta.GitDeltaExpectedKind.Exact
              (git_delta.GitDeltaObjectKind.Blob))
            (git-delta-test-insert-delta 2 "ABC"))))
      (set!
        (array-ref entries 3)
        (git_delta.GitDeltaEntry
          40
          "id-thin-child"
          (git_delta.GitDeltaEntryBody.Ref
            "id-thin"
            (git_delta.GitDeltaExpectedKind.Exact
              (git_delta.GitDeltaObjectKind.Tree))
            (git-delta-test-insert-delta 1 "TX"))))
      (set!
        (array-ref entries 4)
        (git_delta.GitDeltaEntry
          50
          "id-d"
          (git_delta.GitDeltaEntryBody.Ref
            "id-b"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 2 "ABD"))))
      (set! (array-ref offsets 0) (git_delta.GitDeltaOffsetLookup 10 0))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "id-b" (git_delta.GitDeltaIdTarget.Entry 1)))
      (set!
        (array-ref ids 1)
        (git_delta.GitDeltaIdLookup
          "id-thin"
          (git_delta.GitDeltaIdTarget.Thin 0)))
      (set!
        (array-ref thin 0)
        (git_delta.GitDeltaThinBase
          "id-thin"
          (git_delta.GitDeltaObjectKind.Tree)
          "T"))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables offsets ids thin)]
        (match (git_delta.git-delta-resolve (& entries) (& tables) (& limits))
          [(git_delta.ResultGitDeltaResolvedSet.Err _) false]
          [(git_delta.ResultGitDeltaResolvedSet.Ok resolved)
            (and
              (string.eq (array-ref resolved.objects 0) "A")
              (string.eq (array-ref resolved.objects 1) "AB")
              (string.eq (array-ref resolved.objects 2) "ABC")
              (string.eq (array-ref resolved.objects 3) "TX")
              (string.eq (array-ref resolved.objects 4) "ABD")
              (= resolved.reconstructed 4)
              (= resolved.budget.instructions 4)
              (= resolved.budget.lookups 4)
              (= resolved.budget.copied-bytes 0))])))))

(define (git-delta-test-forward-ref?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 2)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "child"
          (git_delta.GitDeltaEntryBody.Ref
            "base"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "B"))))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "base"
          (git_delta.GitDeltaEntryBody.Stored
            (git_delta.GitDeltaObjectKind.Blob)
            "A")))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "base" (git_delta.GitDeltaIdTarget.Entry 1)))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            (git-delta-test-empty-thin))]
        (match (git_delta.git-delta-resolve (& entries) (& tables) (& limits))
          [(git_delta.ResultGitDeltaResolvedSet.Err _) false]
          [(git_delta.ResultGitDeltaResolvedSet.Ok resolved)
            (and
              (string.eq (array-ref resolved.objects 0) "B")
              (= resolved.reconstructed 1))])))))

(define (git-delta-test-cycle-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 2)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 2)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "a"
          (git_delta.GitDeltaEntryBody.Ref
            "b"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "A"))))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "b"
          (git_delta.GitDeltaEntryBody.Ref
            "a"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "B"))))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "a" (git_delta.GitDeltaIdTarget.Entry 0)))
      (set!
        (array-ref ids 1)
        (git_delta.GitDeltaIdLookup "b" (git_delta.GitDeltaIdTarget.Entry 1)))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-missing-ref-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "child"
          (git_delta.GitDeltaEntryBody.Ref
            "missing"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "A"))))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            (git-delta-test-empty-ids)
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-ambiguous-ref-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 2)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 2)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "base"
          (git_delta.GitDeltaEntryBody.Stored
            (git_delta.GitDeltaObjectKind.Blob)
            "A")))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "child"
          (git_delta.GitDeltaEntryBody.Ref
            "base"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "B"))))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "base" (git_delta.GitDeltaIdTarget.Entry 0)))
      (set!
        (array-ref ids 1)
        (git_delta.GitDeltaIdLookup "base" (git_delta.GitDeltaIdTarget.Entry 0)))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-invalid-ofs-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 1)]
    [offsets : (__tl_dyn-array git_delta.GitDeltaOffsetLookup)
      (__tl_make-array git_delta.GitDeltaOffsetLookup 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "child"
          (git_delta.GitDeltaEntryBody.Ofs
            20
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "A"))))
      (set! (array-ref offsets 0) (git_delta.GitDeltaOffsetLookup 20 9))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            offsets
            (git-delta-test-empty-ids)
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-type-mismatch-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 1)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 1)]
    [thin : (__tl_dyn-array git_delta.GitDeltaThinBase)
      (__tl_make-array git_delta.GitDeltaThinBase 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "child"
          (git_delta.GitDeltaEntryBody.Ref
            "thin"
            (git_delta.GitDeltaExpectedKind.Exact
              (git_delta.GitDeltaObjectKind.Blob))
            (git-delta-test-insert-delta 1 "B"))))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "thin" (git_delta.GitDeltaIdTarget.Thin 0)))
      (set!
        (array-ref thin 0)
        (git_delta.GitDeltaThinBase
          "thin"
          (git_delta.GitDeltaObjectKind.Tree)
          "T"))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            thin)]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-depth-rejected?) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 3)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 2)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set! limits.max-depth 1)
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "a"
          (git_delta.GitDeltaEntryBody.Stored
            (git_delta.GitDeltaObjectKind.Blob)
            "A")))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "b"
          (git_delta.GitDeltaEntryBody.Ref
            "a"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "B"))))
      (set!
        (array-ref entries 2)
        (git_delta.GitDeltaEntry
          30
          "c"
          (git_delta.GitDeltaEntryBody.Ref
            "b"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-insert-delta 1 "C"))))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "a" (git_delta.GitDeltaIdTarget.Entry 0)))
      (set!
        (array-ref ids 1)
        (git_delta.GitDeltaIdLookup "b" (git_delta.GitDeltaIdTarget.Entry 1)))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-test-fanout-budget-error?
  [copied-limit : i64]
  [lookup-limit : i64]
  [instruction-limit : i64]) : bool
  (let
    [entries : (__tl_dyn-array git_delta.GitDeltaEntry)
      (__tl_make-array git_delta.GitDeltaEntry 3)]
    [ids : (__tl_dyn-array git_delta.GitDeltaIdLookup)
      (__tl_make-array git_delta.GitDeltaIdLookup 1)]
    [limits : git_delta.GitDeltaLimits (git-delta-test-limits)]
    (begin
      (set! limits.max-copied-bytes copied-limit)
      (set! limits.max-lookups lookup-limit)
      (set! limits.max-instructions instruction-limit)
      (set!
        (array-ref entries 0)
        (git_delta.GitDeltaEntry
          10
          "base"
          (git_delta.GitDeltaEntryBody.Stored
            (git_delta.GitDeltaObjectKind.Blob)
            "A")))
      (set!
        (array-ref entries 1)
        (git_delta.GitDeltaEntry
          20
          "one"
          (git_delta.GitDeltaEntryBody.Ref
            "base"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-copy-delta 1 0 1 16))))
      (set!
        (array-ref entries 2)
        (git_delta.GitDeltaEntry
          30
          "two"
          (git_delta.GitDeltaEntryBody.Ref
            "base"
            (git_delta.GitDeltaExpectedKind.Any)
            (git-delta-test-copy-delta 1 0 1 16))))
      (set!
        (array-ref ids 0)
        (git_delta.GitDeltaIdLookup "base" (git_delta.GitDeltaIdTarget.Entry 0)))
      (let
        [tables : git_delta.GitDeltaLookupTables
          (git_delta.GitDeltaLookupTables
            (git-delta-test-empty-offsets)
            ids
            (git-delta-test-empty-thin))]
        (git-delta-test-resolve-error?
          (git_delta.git-delta-resolve (& entries) (& tables) (& limits)))))))

(define (git-delta-self-test-ok?) : bool
  (and
    (git-delta-test-varints?)
    (git-delta-test-ofs?)
    (git-delta-test-copy-combinations?)
    (git-delta-test-apply-errors?)
    (git-delta-test-malformed-corpus?)
    (git-delta-test-mixed-resolver?)
    (git-delta-test-forward-ref?)
    (git-delta-test-cycle-rejected?)
    (git-delta-test-missing-ref-rejected?)
    (git-delta-test-ambiguous-ref-rejected?)
    (git-delta-test-invalid-ofs-rejected?)
    (git-delta-test-type-mismatch-rejected?)
    (git-delta-test-depth-rejected?)
    (git-delta-test-fanout-budget-error? 1 100 100)
    (git-delta-test-fanout-budget-error? 100 1 100)
    (git-delta-test-fanout-budget-error? 100 100 1)))

(define (git-delta-self-test) : i64
  (if (git-delta-self-test-ok?)
    42
    (io.panic "git delta: self-test mismatch")))

(define (git-delta-test-require [ok : bool] [message : String]) : unit
  (if ok
    unit
    (io.panic message)))

(test
  git-delta-size-varints
  (git-delta-test-require
    (git-delta-test-varints?)
    "git delta: size-varint fixture mismatch"))

(test
  git-delta-ofs-varints
  (begin
    (git-delta-test-require
      (git-delta-test-ofs-value? 1)
      "git delta: OFS distance 1 mismatch")
    (git-delta-test-require
      (git-delta-test-ofs-value? 127)
      "git delta: OFS distance 127 mismatch")
    (git-delta-test-require
      (git-delta-test-ofs-value? 128)
      "git delta: OFS distance 128 mismatch")
    (git-delta-test-require
      (git-delta-test-ofs-value? 129)
      "git delta: OFS distance 129 mismatch")
    (git-delta-test-require
      (git-delta-test-ofs-value? 16384)
      "git delta: OFS distance 16384 mismatch")
    (git-delta-test-require
      (git-delta-test-ofs-value? 9223372036854775807)
      "git delta: OFS maximum mismatch")
    (git-delta-test-require
      (git-delta-test-ofs?)
      "git delta: malformed OFS fixture mismatch")))

(test
  git-delta-copy-bit-matrix
  (git-delta-test-require
    (git-delta-test-copy-combinations?)
    "git delta: copy-bit fixture mismatch"))

(test
  git-delta-malformed-and-budgets
  (git-delta-test-require
    (and (git-delta-test-apply-errors?) (git-delta-test-malformed-corpus?))
    "git delta: malformed/budget fixture mismatch"))

(test
  git-delta-mixed-and-forward-resolution
  (git-delta-test-require
    (and (git-delta-test-mixed-resolver?) (git-delta-test-forward-ref?))
    "git delta: valid resolver fixture mismatch"))

(test
  git-delta-dependency-rejections
  (git-delta-test-require
    (and
      (git-delta-test-cycle-rejected?)
      (git-delta-test-missing-ref-rejected?)
      (git-delta-test-ambiguous-ref-rejected?)
      (git-delta-test-invalid-ofs-rejected?)
      (git-delta-test-type-mismatch-rejected?)
      (git-delta-test-depth-rejected?))
    "git delta: dependency rejection fixture mismatch"))

(test
  git-delta-aggregate-budgets
  (git-delta-test-require
    (and
      (git-delta-test-fanout-budget-error? 1 100 100)
      (git-delta-test-fanout-budget-error? 100 1 100)
      (git-delta-test-fanout-budget-error? 100 100 1))
    "git delta: aggregate budget fixture mismatch"))