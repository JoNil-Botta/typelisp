;; git_delta_core.tl - Bounded, pure Git pack delta reconstruction.
;;
;; This module intentionally starts after pack framing and inflation. Callers
;; provide complete base objects, complete delta instruction streams, and the
;; lookup tables used to resolve abstract OFS_DELTA/REF_DELTA dependencies.
;; Hashing, zlib, files, processes, and network I/O are outside this boundary.
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.string)

(defstruct GitDeltaLimits
  (max-object-bytes i64)
  (max-delta-bytes i64)
  (max-depth i64)
  (max-instructions i64)
  (max-copied-bytes i64)
  (max-lookups i64)
  (max-expansion-ratio i64)
  (max-total-work i64))

(defstruct GitDeltaBudget
  (instructions i64)
  (copied-bytes i64)
  (lookups i64)
  (total-work i64))

(defstruct GitDeltaVarint
  (value i64)
  (next i64))

(defenum ResultGitDeltaVarint
  (Err String)
  (Ok GitDeltaVarint))

(defstruct GitDeltaOfsBase
  (distance i64)
  (base-offset i64)
  (next i64))

(defenum ResultGitDeltaOfsBase
  (Err String)
  (Ok GitDeltaOfsBase))

(defenum ResultGitDeltaBytes
  (Err String)
  (Ok String))

(define (git-delta-limits-valid? [limits : (& limits GitDeltaLimits)]) : bool
  (and
    (>= limits.max-object-bytes 0)
    (>= limits.max-delta-bytes 0)
    (>= limits.max-depth 0)
    (>= limits.max-instructions 0)
    (>= limits.max-copied-bytes 0)
    (>= limits.max-lookups 0)
    (>= limits.max-expansion-ratio 1)
    (>= limits.max-total-work 0)))

(define (git-delta-budget-new) : GitDeltaBudget
  (GitDeltaBudget 0 0 0 0))

(define (git-delta-budget-valid?
  [budget : (& budget GitDeltaBudget)]
  [limits : (& limits GitDeltaLimits)]) : bool
  (and
    (>= budget.instructions 0)
    (<= budget.instructions limits.max-instructions)
    (>= budget.copied-bytes 0)
    (<= budget.copied-bytes limits.max-copied-bytes)
    (>= budget.lookups 0)
    (<= budget.lookups limits.max-lookups)
    (>= budget.total-work 0)
    (<= budget.total-work limits.max-total-work)))

(define (git-delta-budget-charge-work!
  [budget : (&mut budget GitDeltaBudget)]
  [limits : (& limits GitDeltaLimits)]
  [amount : i64]) : bool
  (if (or
    (< amount 0)
    (> budget.total-work limits.max-total-work)
    (> amount (- limits.max-total-work budget.total-work)))
    false
    (begin
      (set! budget.total-work (+ budget.total-work amount))
      true)))

(define (git-delta-budget-charge-instruction!
  [budget : (&mut budget GitDeltaBudget)]
  [limits : (& limits GitDeltaLimits)]) : bool
  (if (or
    (>= budget.instructions limits.max-instructions)
    (not (git-delta-budget-charge-work! budget limits 1)))
    false
    (begin
      (set! budget.instructions (+ budget.instructions 1))
      true)))

(define (git-delta-budget-charge-copy!
  [budget : (&mut budget GitDeltaBudget)]
  [limits : (& limits GitDeltaLimits)]
  [amount : i64]) : bool
  (if (or
    (< amount 0)
    (> budget.copied-bytes limits.max-copied-bytes)
    (> amount (- limits.max-copied-bytes budget.copied-bytes))
    (not (git-delta-budget-charge-work! budget limits amount)))
    false
    (begin
      (set! budget.copied-bytes (+ budget.copied-bytes amount))
      true)))

(define (git-delta-budget-charge-lookup!
  [budget : (&mut budget GitDeltaBudget)]
  [limits : (& limits GitDeltaLimits)]) : bool
  (if (or
    (>= budget.lookups limits.max-lookups)
    (not (git-delta-budget-charge-work! budget limits 1)))
    false
    (begin
      (set! budget.lookups (+ budget.lookups 1))
      true)))

(define (git-delta-byte [bytes : (& bytes str)] [index : i64]) : i64
  (cast (string.string-ref bytes index) : i64))

;: Decode Git's ordinary little-endian, seven-bit size varint.
;: The returned cursor points immediately after the terminating byte.
(define (git-delta-read-size-varint [bytes : (& bytes str)] [start : i64]) : ResultGitDeltaVarint
  (let
    [length : i64 (string.string-length bytes)]
    [index : i64 start]
    [shift : i64 0]
    [count : i64 0]
    [value : i64 0]
    (begin
      (when
        (or (< start 0) (> start length))
        (return (ResultGitDeltaVarint.Err "git delta: invalid varint start")))
      (while true
        (begin
          (when
            (>= index length)
            (return
              (ResultGitDeltaVarint.Err "git delta: truncated size varint")))
          (let
            [octet : i64 (git-delta-byte bytes index)]
            [chunk : i64 (bit-and octet 127)]
            (begin
              ;; Signed i64 is the module's size domain. At shift 63 even a
              ;; single payload bit would exceed that domain.
              (when
                (or (> shift 63) (> chunk (shr 9223372036854775807 shift)))
                (return
                  (ResultGitDeltaVarint.Err
                    "git delta: size varint overflows i64")))
              (set! value (bit-or value (shl chunk shift)))
              (set! index (+ index 1))
              (set! count (+ count 1))
              (when
                (= (bit-and octet 128) 0)
                (return (ResultGitDeltaVarint.Ok (GitDeltaVarint value index))))
              (when
                (>= count 9)
                (return
                  (ResultGitDeltaVarint.Err "git delta: excessive size varint")))
              (set! shift (+ shift 7))))))
      (ResultGitDeltaVarint.Err "git delta: unreachable size varint state"))))

;: Decode Git's biased, big-endian OFS_DELTA distance and check that it points
;: strictly backward from `object-offset` without crossing offset zero.
(define (git-delta-read-ofs-base
  [bytes : (& bytes str)]
  [start : i64]
  [object-offset : i64]) : ResultGitDeltaOfsBase
  (let
    [length : i64 (string.string-length bytes)]
    [index : i64 start]
    [count : i64 0]
    [value : i64 0]
    (begin
      (when
        (or (< start 0) (> start length))
        (return
          (ResultGitDeltaOfsBase.Err "git delta: invalid OFS_DELTA start")))
      (when
        (<= object-offset 0)
        (return (ResultGitDeltaOfsBase.Err "git delta: invalid object offset")))
      (when
        (>= index length)
        (return
          (ResultGitDeltaOfsBase.Err "git delta: truncated OFS_DELTA offset")))
      (let
        [first : i64 (git-delta-byte bytes index)]
        (begin
          (set! value (bit-and first 127))
          (set! index (+ index 1))
          (set! count 1)
          (while (!= (bit-and (git-delta-byte bytes (- index 1)) 128) 0)
            (begin
              (when
                (>= index length)
                (return
                  (ResultGitDeltaOfsBase.Err
                    "git delta: truncated OFS_DELTA offset")))
              (when
                (>= count 9)
                (return
                  (ResultGitDeltaOfsBase.Err
                    "git delta: excessive OFS_DELTA offset")))
              (let
                [next : i64 (git-delta-byte bytes index)]
                [chunk : i64 (bit-and next 127)]
                (begin
                  ;; value = ((value + 1) << 7) | chunk
                  (when
                    (or
                      (= value 9223372036854775807)
                      (> (+ value 1) (shr 9223372036854775807 7)))
                    (return
                      (ResultGitDeltaOfsBase.Err
                        "git delta: OFS_DELTA offset overflows i64")))
                  (set! value (bit-or (shl (+ value 1) 7) chunk))
                  (set! index (+ index 1))
                  (set! count (+ count 1)))))))
        (cond
          [(<= value 0)
            (ResultGitDeltaOfsBase.Err "git delta: zero OFS_DELTA distance")]
          [(> value object-offset)
            (ResultGitDeltaOfsBase.Err "git delta: OFS_DELTA offset underflow")]
          [else
            (ResultGitDeltaOfsBase.Ok
              (GitDeltaOfsBase value (- object-offset value) index))])))))

(define (git-delta-expansion-within-limit?
  [result-bytes : i64]
  [delta-bytes : i64]
  [ratio : i64]) : bool
  (if (= result-bytes 0)
    true
    (if (or (<= delta-bytes 0) (<= ratio 0))
      false
      (let
        [quotient : i64 (/ result-bytes ratio)]
        [remainder : i64 (% result-bytes ratio)]
        [required : i64
          (+
            quotient
            (if (= remainder 0)
              0
              1))]
        (<= required delta-bytes)))))

(define (git-delta-read-copy-byte
  [delta : (& delta str)]
  [index : (&mut index i64)]) : i64
  (let
    [value : i64 (git-delta-byte delta (deref index))]
    (begin
      (set! (deref index) (+ (deref index) 1))
      value)))

(define (git-delta-append-range!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [bytes : (& bytes str)]
  [start : i64]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (byte_buf.byte-buf-builder-push
          out
          (cast (git-delta-byte bytes (+ start index)) : u8))
        (set! index (+ index 1))))))

;: Apply one complete, already-inflated Git delta instruction stream.
;: `budget` is shared by a whole resolver run when aggregate limits matter.
(define (git-delta-apply-with-budget
  [base : (& base str)]
  [delta : (& delta str)]
  [limits : (& limits GitDeltaLimits)]
  [budget : (&mut budget GitDeltaBudget)]) : ResultGitDeltaBytes
  (let
    [base-length : i64 (string.string-length base)]
    [delta-length : i64 (string.string-length delta)]
    [index : i64 0]
    [declared-base : i64 0]
    [result-length : i64 0]
    (begin
      (unless
        (git-delta-limits-valid? limits)
        (return (ResultGitDeltaBytes.Err "git delta: invalid limits")))
      (unless
        (git-delta-budget-valid? budget limits)
        (return (ResultGitDeltaBytes.Err "git delta: invalid budget state")))
      (when
        (> base-length limits.max-object-bytes)
        (return
          (ResultGitDeltaBytes.Err "git delta: base exceeds object limit")))
      (when
        (> delta-length limits.max-delta-bytes)
        (return (ResultGitDeltaBytes.Err "git delta: delta exceeds byte limit")))
      (unless
        (git-delta-budget-charge-work! budget limits delta-length)
        (return
          (ResultGitDeltaBytes.Err "git delta: total work limit exceeded")))
      (match (git-delta-read-size-varint delta index)
        [(ResultGitDeltaVarint.Err message)
          (return (ResultGitDeltaBytes.Err message))]
        [(ResultGitDeltaVarint.Ok decoded)
          (begin
            (set! declared-base decoded.value)
            (set! index decoded.next))])
      (when
        (!= declared-base base-length)
        (return (ResultGitDeltaBytes.Err "git delta: base length mismatch")))
      (match (git-delta-read-size-varint delta index)
        [(ResultGitDeltaVarint.Err message)
          (return (ResultGitDeltaBytes.Err message))]
        [(ResultGitDeltaVarint.Ok decoded)
          (begin
            (set! result-length decoded.value)
            (set! index decoded.next))])
      (when
        (> result-length limits.max-object-bytes)
        (return
          (ResultGitDeltaBytes.Err "git delta: result exceeds object limit")))
      (unless
        (git-delta-expansion-within-limit?
          result-length
          delta-length
          limits.max-expansion-ratio)
        (return (ResultGitDeltaBytes.Err "git delta: expansion ratio exceeded")))
      ;; Allocation happens only after both length headers and all caller caps
      ;; have been checked.
      (let
        [out : byte_buf.ByteBufBuilder
          (byte_buf.byte-buf-builder-with-capacity result-length)]
        [valid : bool true]
        [error : String ""]
        (begin
          (while (and valid (< index delta-length))
            (let
              [opcode : i64 (git-delta-byte delta index)]
              [produced : i64 (byte_buf.byte-buf-builder-len (& out))]
              (begin
                (set! index (+ index 1))
                (if (not (git-delta-budget-charge-instruction! budget limits))
                  (begin
                    (set! valid false)
                    (set! error "git delta: instruction limit exceeded"))
                  (if (!= (bit-and opcode 128) 0)
                    (let
                      [needed : i64
                        (+
                          (+
                            (+
                              (if (!= (bit-and opcode 1) 0)
                                1
                                0)
                              (if (!= (bit-and opcode 2) 0)
                                1
                                0))
                            (+
                              (if (!= (bit-and opcode 4) 0)
                                1
                                0)
                              (if (!= (bit-and opcode 8) 0)
                                1
                                0)))
                          (+
                            (+
                              (if (!= (bit-and opcode 16) 0)
                                1
                                0)
                              (if (!= (bit-and opcode 32) 0)
                                1
                                0))
                            (if (!= (bit-and opcode 64) 0)
                              1
                              0)))]
                      [copy-offset : i64 0]
                      [copy-size : i64 0]
                      (if (> needed (- delta-length index))
                        (begin
                          (set! valid false)
                          (set! error "git delta: truncated copy instruction"))
                        (begin
                          (if (!= (bit-and opcode 1) 0)
                            (set!
                              copy-offset
                              (bit-or
                                copy-offset
                                (git-delta-read-copy-byte delta (&mut index))))
                            unit)
                          (if (!= (bit-and opcode 2) 0)
                            (set!
                              copy-offset
                              (bit-or
                                copy-offset
                                (shl
                                  (git-delta-read-copy-byte delta (&mut index))
                                  8)))
                            unit)
                          (if (!= (bit-and opcode 4) 0)
                            (set!
                              copy-offset
                              (bit-or
                                copy-offset
                                (shl
                                  (git-delta-read-copy-byte delta (&mut index))
                                  16)))
                            unit)
                          (if (!= (bit-and opcode 8) 0)
                            (set!
                              copy-offset
                              (bit-or
                                copy-offset
                                (shl
                                  (git-delta-read-copy-byte delta (&mut index))
                                  24)))
                            unit)
                          (if (!= (bit-and opcode 16) 0)
                            (set!
                              copy-size
                              (bit-or
                                copy-size
                                (git-delta-read-copy-byte delta (&mut index))))
                            unit)
                          (if (!= (bit-and opcode 32) 0)
                            (set!
                              copy-size
                              (bit-or
                                copy-size
                                (shl
                                  (git-delta-read-copy-byte delta (&mut index))
                                  8)))
                            unit)
                          (if (!= (bit-and opcode 64) 0)
                            (set!
                              copy-size
                              (bit-or
                                copy-size
                                (shl
                                  (git-delta-read-copy-byte delta (&mut index))
                                  16)))
                            unit)
                          (if (= copy-size 0)
                            (set! copy-size 65536)
                            unit)
                          (cond
                            [(or
                                (> copy-offset base-length)
                                (> copy-size (- base-length copy-offset)))
                              (begin
                                (set! valid false)
                                (set! error "git delta: copy outside base"))]
                            [(> copy-size (- result-length produced))
                              (begin
                                (set! valid false)
                                (set!
                                  error
                                  "git delta: copy exceeds result length"))]
                            [(not
                                (git-delta-budget-charge-copy!
                                  budget
                                  limits
                                  copy-size))
                              (begin
                                (set! valid false)
                                (set!
                                  error
                                  "git delta: copied-byte limit exceeded"))]
                            [else
                              (git-delta-append-range!
                                (&mut out)
                                base
                                copy-offset
                                copy-size)]))))
                    (let
                      [insert-size : i64 (bit-and opcode 127)]
                      (cond
                        [(= insert-size 0)
                          (begin
                            (set! valid false)
                            (set! error "git delta: reserved zero opcode"))]
                        [(> insert-size (- delta-length index))
                          (begin
                            (set! valid false)
                            (set!
                              error
                              "git delta: truncated insert instruction"))]
                        [(> insert-size (- result-length produced))
                          (begin
                            (set! valid false)
                            (set!
                              error
                              "git delta: insert exceeds result length"))]
                        [(not
                            (git-delta-budget-charge-work!
                              budget
                              limits
                              insert-size))
                          (begin
                            (set! valid false)
                            (set! error "git delta: total work limit exceeded"))]
                        [else
                          (begin
                            (git-delta-append-range!
                              (&mut out)
                              delta
                              index
                              insert-size)
                            (set! index (+ index insert-size)))])))))))
          (cond
            [(not valid) (ResultGitDeltaBytes.Err error)]
            [(!= (byte_buf.byte-buf-builder-len (& out)) result-length)
              (ResultGitDeltaBytes.Err "git delta: result length mismatch")]
            [(!= index delta-length)
              (ResultGitDeltaBytes.Err "git delta: trailing instruction bytes")]
            [else
              (ResultGitDeltaBytes.Ok
                (byte_buf.byte-buf-builder-finish-string (& out)))]))))))

;: Convenience boundary for one independent delta application.
(define (git-delta-apply
  [base : (& base str)]
  [delta : (& delta str)]
  [limits : (& limits GitDeltaLimits)]) : ResultGitDeltaBytes
  (let
    [budget : GitDeltaBudget (git-delta-budget-new)]
    (git-delta-apply-with-budget base delta limits (&mut budget))))

(defenum GitDeltaObjectKind
  (Blob)
  (Tree)
  (Commit)
  (Tag))

(defenum GitDeltaExpectedKind
  (Any)
  (Exact GitDeltaObjectKind))

(defenum GitDeltaEntryBody
  (Stored GitDeltaObjectKind String)
  ;; Absolute base offset after pack framing has decoded the OFS distance.
  (Ofs i64 GitDeltaExpectedKind String)
  (Ref String GitDeltaExpectedKind String))

(defstruct GitDeltaEntry
  (offset i64)
  ;; Opaque here. The pack/index layer may populate IDs for REF lookups.
  (object-id String)
  (body GitDeltaEntryBody))

;: Caller-injected mapping from an absolute pack offset to an entry slot.
(defstruct GitDeltaOffsetLookup
  (offset i64)
  (entry-index i64))

(defenum GitDeltaIdTarget
  (Entry i64)
  (Thin i64))

;: Caller-injected mapping from an opaque object ID to a pack or thin slot.
(defstruct GitDeltaIdLookup
  (object-id String)
  (target GitDeltaIdTarget))

(defstruct GitDeltaThinBase
  (object-id String)
  (kind GitDeltaObjectKind)
  (bytes String))

(defstruct GitDeltaLookupTables
  (offsets (__tl_dyn-array GitDeltaOffsetLookup))
  (ids (__tl_dyn-array GitDeltaIdLookup))
  (thin-bases (__tl_dyn-array GitDeltaThinBase)))

(defstruct GitDeltaResolvedSet
  (objects (__tl_dyn-array String))
  (kinds (__tl_dyn-array GitDeltaObjectKind))
  (budget GitDeltaBudget)
  (reconstructed i64))

(defenum ResultGitDeltaResolvedSet
  (Err String)
  (Ok GitDeltaResolvedSet))

;; Nonnegative dependency slots address `entries`; negative slots encode
;; caller-provided thin bases as `-thin-index - 1`.
(defenum ResultGitDeltaDependency
  (Err String)
  (Ok i64))

(define (git-delta-entry-at
  [entries : (& entries (__tl_dyn-array GitDeltaEntry))]
  [index : i64]) : (& entries GitDeltaEntry)
  (& (array-ref entries index)))

(define (git-delta-thin-at
  [thin-bases : (& thin_bases (__tl_dyn-array GitDeltaThinBase))]
  [index : i64]) : (& thin_bases GitDeltaThinBase)
  (& (array-ref thin-bases index)))

(define (git-delta-kind-eq?
  [left : (& left GitDeltaObjectKind)]
  [right : (& right GitDeltaObjectKind)]) : bool
  (match left
    [(GitDeltaObjectKind.Blob)
      (match right
        [(GitDeltaObjectKind.Blob) true]
        [_ false])]
    [(GitDeltaObjectKind.Tree)
      (match right
        [(GitDeltaObjectKind.Tree) true]
        [_ false])]
    [(GitDeltaObjectKind.Commit)
      (match right
        [(GitDeltaObjectKind.Commit) true]
        [_ false])]
    [(GitDeltaObjectKind.Tag)
      (match right
        [(GitDeltaObjectKind.Tag) true]
        [_ false])]))

(define (git-delta-kind-owned-copy [kind : (& kind GitDeltaObjectKind)]) : GitDeltaObjectKind
  (match kind
    [(GitDeltaObjectKind.Blob) (GitDeltaObjectKind.Blob)]
    [(GitDeltaObjectKind.Tree) (GitDeltaObjectKind.Tree)]
    [(GitDeltaObjectKind.Commit) (GitDeltaObjectKind.Commit)]
    [(GitDeltaObjectKind.Tag) (GitDeltaObjectKind.Tag)]))

(define (git-delta-expected-kind-matches?
  [expected : (& expected GitDeltaExpectedKind)]
  [actual : (& actual GitDeltaObjectKind)]) : bool
  (match expected
    [(GitDeltaExpectedKind.Any) true]
    [(GitDeltaExpectedKind.Exact required) (git-delta-kind-eq? required actual)]))

(define (git-delta-resolve-offset-lookup!
  [entries : (& entries (__tl_dyn-array GitDeltaEntry))]
  [lookups : (& lookups (__tl_dyn-array GitDeltaOffsetLookup))]
  [current-offset : i64]
  [base-offset : i64]
  [limits : (& limits GitDeltaLimits)]
  [budget : (&mut budget GitDeltaBudget)]) : ResultGitDeltaDependency
  (let
    [index : i64 0]
    [matches : i64 0]
    [target : i64 -1]
    (begin
      (when
        (or (< base-offset 0) (<= current-offset base-offset))
        (return
          (ResultGitDeltaDependency.Err
            "git delta: OFS dependency is not strictly backward")))
      (unless
        (git-delta-budget-charge-lookup! budget limits)
        (return
          (ResultGitDeltaDependency.Err "git delta: lookup limit exceeded")))
      (while (< index (array-length lookups))
        (begin
          (unless
            (git-delta-budget-charge-work! budget limits 1)
            (return
              (ResultGitDeltaDependency.Err
                "git delta: total work limit exceeded")))
          (let
            [candidate : (& lookups GitDeltaOffsetLookup)
              (& (array-ref lookups index))]
            (begin
              (if (= candidate.offset base-offset)
                (begin
                  (set! matches (+ matches 1))
                  (set! target candidate.entry-index))
                unit)
              (set! index (+ index 1))))))
      (cond
        [(= matches 0)
          (ResultGitDeltaDependency.Err "git delta: missing OFS base")]
        [(> matches 1)
          (ResultGitDeltaDependency.Err "git delta: ambiguous OFS base")]
        [(or (< target 0) (>= target (array-length entries)))
          (ResultGitDeltaDependency.Err "git delta: invalid OFS lookup target")]
        [(!= (git-delta-entry-at entries target).offset base-offset)
          (ResultGitDeltaDependency.Err "git delta: inconsistent OFS lookup")]
        [else (ResultGitDeltaDependency.Ok target)]))))

(define (git-delta-resolve-id-lookup!
  [entries : (& entries (__tl_dyn-array GitDeltaEntry))]
  [lookups : (& lookups (__tl_dyn-array GitDeltaIdLookup))]
  [thin-bases : (& thin_bases (__tl_dyn-array GitDeltaThinBase))]
  [object-id : (& object_id str)]
  [limits : (& limits GitDeltaLimits)]
  [budget : (&mut budget GitDeltaBudget)]) : ResultGitDeltaDependency
  (let
    [index : i64 0]
    [matches : i64 0]
    [target-kind : i64 -1]
    [target-index : i64 -1]
    (begin
      (when
        (= (string.string-length object-id) 0)
        (return (ResultGitDeltaDependency.Err "git delta: empty REF object id")))
      (unless
        (git-delta-budget-charge-lookup! budget limits)
        (return
          (ResultGitDeltaDependency.Err "git delta: lookup limit exceeded")))
      (while (< index (array-length lookups))
        (begin
          (unless
            (git-delta-budget-charge-work! budget limits 1)
            (return
              (ResultGitDeltaDependency.Err
                "git delta: total work limit exceeded")))
          (let
            [candidate : (& lookups GitDeltaIdLookup)
              (& (array-ref lookups index))]
            (begin
              (if (string.eq candidate.object-id object-id)
                (begin
                  (set! matches (+ matches 1))
                  (match (& candidate.target)
                    [(GitDeltaIdTarget.Entry entry-index)
                      (begin
                        (set! target-kind 0)
                        (set! target-index (deref entry-index)))]
                    [(GitDeltaIdTarget.Thin thin-index)
                      (begin
                        (set! target-kind 1)
                        (set! target-index (deref thin-index)))]))
                unit)
              (set! index (+ index 1))))))
      (cond
        [(= matches 0)
          (ResultGitDeltaDependency.Err "git delta: missing REF base")]
        [(> matches 1)
          (ResultGitDeltaDependency.Err "git delta: ambiguous REF base")]
        [(= target-kind 0)
          (if (or (< target-index 0) (>= target-index (array-length entries)))
            (ResultGitDeltaDependency.Err "git delta: invalid REF entry target")
            (if (string.eq
              (git-delta-entry-at entries target-index).object-id
              object-id)
              (ResultGitDeltaDependency.Ok target-index)
              (ResultGitDeltaDependency.Err
                "git delta: inconsistent REF entry lookup")))]
        [(= target-kind 1)
          (if (or
            (< target-index 0)
            (>= target-index (array-length thin-bases)))
            (ResultGitDeltaDependency.Err "git delta: invalid thin base target")
            (if (string.eq
              (git-delta-thin-at thin-bases target-index).object-id
              object-id)
              (ResultGitDeltaDependency.Ok (- 0 (+ target-index 1)))
              (ResultGitDeltaDependency.Err
                "git delta: inconsistent thin base lookup")))]
        [else
          (ResultGitDeltaDependency.Err "git delta: invalid REF lookup target")]))))

(define (git-delta-copy-owned [value : (& value str)]) : String
  (string.substring value 0 (string.string-length value)))

;: Resolve every entry with one iterative DFS state machine. Entry state 0 is
;: unseen, 1 is on the active dependency stack, and 2 is memoized/completed.
(define (git-delta-resolve
  [entries : (& entries (__tl_dyn-array GitDeltaEntry))]
  [tables : (& tables GitDeltaLookupTables)]
  [limits : (& limits GitDeltaLimits)]) : ResultGitDeltaResolvedSet
  (let
    [count : i64 (array-length entries)]
    [states : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [depths : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [dependencies : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [objects : (__tl_dyn-array String) (__tl_make-array String count)]
    [kinds : (__tl_dyn-array GitDeltaObjectKind)
      (__tl_make-array GitDeltaObjectKind count)]
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [budget : GitDeltaBudget (git-delta-budget-new)]
    [reconstructed : i64 0]
    [root : i64 0]
    (begin
      (unless
        (git-delta-limits-valid? limits)
        (return (ResultGitDeltaResolvedSet.Err "git delta: invalid limits")))
      (while (< root count)
        (begin
          (if (!= (array-ref states root) 2)
            (let
              [stack-count : i64 1]
              (begin
                (set! (array-ref stack 0) root)
                (while (> stack-count 0)
                  (let
                    [slot : i64 (array-ref stack (- stack-count 1))]
                    [entry : (& entries GitDeltaEntry)
                      (git-delta-entry-at entries slot)]
                    [state : i64 (array-ref states slot)]
                    (cond
                      [(= state 0)
                        (begin
                          (unless
                            (git-delta-budget-charge-work!
                              (&mut budget)
                              limits
                              1)
                            (return
                              (ResultGitDeltaResolvedSet.Err
                                "git delta: total work limit exceeded")))
                          (set! (array-ref states slot) 1)
                          (match (& entry.body)
                            [(GitDeltaEntryBody.Stored kind bytes)
                              (let
                                [length : i64 (string.string-length bytes)]
                                (begin
                                  (when
                                    (> length limits.max-object-bytes)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err
                                        "git delta: stored object exceeds limit")))
                                  (unless
                                    (git-delta-budget-charge-work!
                                      (&mut budget)
                                      limits
                                      length)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err
                                        "git delta: total work limit exceeded")))
                                  (set!
                                    (array-ref objects slot)
                                    (git-delta-copy-owned bytes))
                                  (set!
                                    (array-ref kinds slot)
                                    (git-delta-kind-owned-copy kind))
                                  (set! (array-ref states slot) 2)
                                  (set! stack-count (- stack-count 1))))]
                            [(GitDeltaEntryBody.Ofs base-offset _ _)
                              (begin
                                (when
                                  (> stack-count limits.max-depth)
                                  (return
                                    (ResultGitDeltaResolvedSet.Err
                                      "git delta: chain depth limit exceeded")))
                                (match (git-delta-resolve-offset-lookup!
                                  entries
                                  tables.offsets
                                  entry.offset
                                  (deref base-offset)
                                  limits
                                  (&mut budget))
                                  [(ResultGitDeltaDependency.Err message)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err message))]
                                  [(ResultGitDeltaDependency.Ok dependency)
                                    (begin
                                      (set!
                                        (array-ref dependencies slot)
                                        dependency)
                                      (cond
                                        [(= (array-ref states dependency) 1)
                                          (return
                                            (ResultGitDeltaResolvedSet.Err
                                              "git delta: dependency cycle"))]
                                        [(= (array-ref states dependency) 0)
                                          (begin
                                            (when
                                              (>= stack-count count)
                                              (return
                                                (ResultGitDeltaResolvedSet.Err
                                                  "git delta: dependency stack overflow")))
                                            (set!
                                              (array-ref stack stack-count)
                                              dependency)
                                            (set! stack-count (+ stack-count 1)))]
                                        [else unit]))]))]
                            [(GitDeltaEntryBody.Ref object-id _ _)
                              (begin
                                (when
                                  (> stack-count limits.max-depth)
                                  (return
                                    (ResultGitDeltaResolvedSet.Err
                                      "git delta: chain depth limit exceeded")))
                                (match (git-delta-resolve-id-lookup!
                                  entries
                                  tables.ids
                                  tables.thin-bases
                                  object-id
                                  limits
                                  (&mut budget))
                                  [(ResultGitDeltaDependency.Err message)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err message))]
                                  [(ResultGitDeltaDependency.Ok dependency)
                                    (begin
                                      (set!
                                        (array-ref dependencies slot)
                                        dependency)
                                      (if (>= dependency 0)
                                        (cond
                                          [(= (array-ref states dependency) 1)
                                            (return
                                              (ResultGitDeltaResolvedSet.Err
                                                "git delta: dependency cycle"))]
                                          [(= (array-ref states dependency) 0)
                                            (begin
                                              (when
                                                (>= stack-count count)
                                                (return
                                                  (ResultGitDeltaResolvedSet.Err
                                                    "git delta: dependency stack overflow")))
                                              (set!
                                                (array-ref stack stack-count)
                                                dependency)
                                              (set!
                                                stack-count
                                                (+ stack-count 1)))]
                                          [else unit])
                                        unit))]))]))]
                      [(= state 1)
                        (let
                          [dependency : i64 (array-ref dependencies slot)]
                          [base-kind : GitDeltaObjectKind
                            (GitDeltaObjectKind.Blob)]
                          [base-bytes : String ""]
                          [base-depth : i64 0]
                          (begin
                            (if (>= dependency 0)
                              (begin
                                (when
                                  (!= (array-ref states dependency) 2)
                                  (return
                                    (ResultGitDeltaResolvedSet.Err
                                      "git delta: unresolved dependency state")))
                                (unless
                                  (git-delta-budget-charge-work!
                                    (&mut budget)
                                    limits
                                    (string.string-length
                                      (& (array-ref objects dependency))))
                                  (return
                                    (ResultGitDeltaResolvedSet.Err
                                      "git delta: total work limit exceeded")))
                                (set!
                                  base-bytes
                                  (git-delta-copy-owned
                                    (& (array-ref objects dependency))))
                                (set! base-kind (array-ref kinds dependency))
                                (set! base-depth (array-ref depths dependency)))
                              (let
                                [thin-index : i64 (- (- 0 dependency) 1)]
                                (begin
                                  (when
                                    (or
                                      (< thin-index 0)
                                      (>=
                                        thin-index
                                        (array-length tables.thin-bases)))
                                    (return
                                      (ResultGitDeltaResolvedSet.Err
                                        "git delta: invalid thin dependency")))
                                  (let
                                    [thin : (& tables GitDeltaThinBase)
                                      (git-delta-thin-at
                                        tables.thin-bases
                                        thin-index)]
                                    [thin-length : i64
                                      (string.string-length thin.bytes)]
                                    (begin
                                      (when
                                        (> thin-length limits.max-object-bytes)
                                        (return
                                          (ResultGitDeltaResolvedSet.Err
                                            "git delta: thin base exceeds object limit")))
                                      (unless
                                        (git-delta-budget-charge-work!
                                          (&mut budget)
                                          limits
                                          thin-length)
                                        (return
                                          (ResultGitDeltaResolvedSet.Err
                                            "git delta: total work limit exceeded")))
                                      (set!
                                        base-bytes
                                        (git-delta-copy-owned thin.bytes))
                                      (set!
                                        base-kind
                                        (git-delta-kind-owned-copy thin.kind)))))))
                            (when
                              (>= base-depth limits.max-depth)
                              (return
                                (ResultGitDeltaResolvedSet.Err
                                  "git delta: chain depth limit exceeded")))
                            (match (& entry.body)
                              [(GitDeltaEntryBody.Stored _ _)
                                (return
                                  (ResultGitDeltaResolvedSet.Err
                                    "git delta: invalid stored entry state"))]
                              [(GitDeltaEntryBody.Ofs _ expected delta)
                                (begin
                                  (unless
                                    (git-delta-expected-kind-matches?
                                      expected
                                      base-kind)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err
                                        "git delta: object type mismatch")))
                                  (match (git-delta-apply-with-budget
                                    (& base-bytes)
                                    delta
                                    limits
                                    (&mut budget))
                                    [(ResultGitDeltaBytes.Err message)
                                      (return
                                        (ResultGitDeltaResolvedSet.Err message))]
                                    [(ResultGitDeltaBytes.Ok object)
                                      (set! (array-ref objects slot) object)]))]
                              [(GitDeltaEntryBody.Ref _ expected delta)
                                (begin
                                  (unless
                                    (git-delta-expected-kind-matches?
                                      expected
                                      base-kind)
                                    (return
                                      (ResultGitDeltaResolvedSet.Err
                                        "git delta: object type mismatch")))
                                  (match (git-delta-apply-with-budget
                                    (& base-bytes)
                                    delta
                                    limits
                                    (&mut budget))
                                    [(ResultGitDeltaBytes.Err message)
                                      (return
                                        (ResultGitDeltaResolvedSet.Err message))]
                                    [(ResultGitDeltaBytes.Ok object)
                                      (set! (array-ref objects slot) object)]))])
                            (set! (array-ref kinds slot) base-kind)
                            (set! (array-ref depths slot) (+ base-depth 1))
                            (set! (array-ref states slot) 2)
                            (set! reconstructed (+ reconstructed 1))
                            (set! stack-count (- stack-count 1))))]
                      [else (set! stack-count (- stack-count 1))])))
                unit))
            unit)
          (set! root (+ root 1))))
      (ResultGitDeltaResolvedSet.Ok
        (GitDeltaResolvedSet objects kinds budget reconstructed)))))