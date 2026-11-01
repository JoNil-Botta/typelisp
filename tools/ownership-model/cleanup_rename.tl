;; Test representation transform, not an ownership decision procedure.
;; mapping[old obligation index] = new obligation index. All identities belong
;; to this one caller-owned body; nothing survives or is cached across bodies.
;; Validate the complete mapping and every remapped reference before mutation.
(import compiler_ownership_core as core)
(import stdlib.string)

(define (has-owner? [operation : (& operation core.OwnershipOperation)]) : bool
  ;; Exhaustive so a new operation requires an explicit identity-map decision.
  (match operation
    [(core.OwnershipOperation.BindFresh _) true]
    [(core.OwnershipOperation.BeginConstruction _) true]
    [(core.OwnershipOperation.BindComplete _) true]
    [(core.OwnershipOperation.BindMove _ _) true]
    [(core.OwnershipOperation.Leave _) true]
    [(core.OwnershipOperation.Cleanup _ _) true]
    [(core.OwnershipOperation.Read _) false]
    [(core.OwnershipOperation.Initialize _) false]
    [(core.OwnershipOperation.Assign _) false]
    [(core.OwnershipOperation.RequireEmpty _) false]
    [(core.OwnershipOperation.CleanupFailure _) false]
    [(core.OwnershipOperation.CleanupPlace _ _) false]
    [(core.OwnershipOperation.Consume _) false]
    [(core.OwnershipOperation.Copy _ _) false]
    [(core.OwnershipOperation.Move _ _) false]
    [(core.OwnershipOperation.Invalidate _) false]
    [(core.OwnershipOperation.Borrow _) false]
    [(core.OwnershipOperation.Reborrow _) false]
    [(core.OwnershipOperation.UseLoan _) false]
    [(core.OwnershipOperation.MayUseLoan _ _) false]
    [(core.OwnershipOperation.AccessThrough _ _ _) false]
    [(core.OwnershipOperation.EndLoan _) false]
    [(core.OwnershipOperation.Unsupported _) false]))

(define (owner-valid?
  [body : (& body core.OwnershipBody)]
  [operation : (& operation core.OwnershipOperation)]) : bool
  (match operation
    [(core.OwnershipOperation.BindFresh id)
      (core.ownership-obligation-id? body id)]
    [(core.OwnershipOperation.BeginConstruction id)
      (core.ownership-obligation-id? body id)]
    [(core.OwnershipOperation.BindComplete id)
      (core.ownership-obligation-id? body id)]
    [(core.OwnershipOperation.BindMove _ id)
      (core.ownership-obligation-id? body id)]
    [(core.OwnershipOperation.Leave id) (core.ownership-obligation-id? body id)]
    [(core.OwnershipOperation.Cleanup id _)
      (core.ownership-obligation-id? body id)]
    [_ false]))

(define (renamed-id
  [id : (& id core.OwnershipObligationId)]
  [mapping : (& mapping (__tl_dyn-array i64))]) : core.OwnershipObligationId
  (core.OwnershipObligationId
    (core.ownership-body-id-copy (& id.body))
    (array-ref mapping id.index)))

(define (renamed-operation
  [operation : (& operation core.OwnershipOperation)]
  [mapping : (& mapping (__tl_dyn-array i64))]) : core.OwnershipOperation
  (match operation
    [(core.OwnershipOperation.BindFresh id)
      (core.OwnershipOperation.BindFresh (renamed-id id mapping))]
    [(core.OwnershipOperation.BeginConstruction id)
      (core.OwnershipOperation.BeginConstruction (renamed-id id mapping))]
    [(core.OwnershipOperation.BindComplete id)
      (core.OwnershipOperation.BindComplete (renamed-id id mapping))]
    [(core.OwnershipOperation.BindMove place id)
      (core.OwnershipOperation.BindMove
        (core.ownership-place-id-copy place)
        (renamed-id id mapping))]
    [(core.OwnershipOperation.Leave id)
      (core.OwnershipOperation.Leave (renamed-id id mapping))]
    [(core.OwnershipOperation.Cleanup id cleanup)
      (core.OwnershipOperation.Cleanup
        (renamed-id id mapping)
        (core.ownership-cleanup-id-copy cleanup))]
    ;; Called only after has-owner? and owner-valid? succeeded.
    [_ (core.OwnershipOperation.CleanupFailure 0)]))

(define (renamed-obligation
  [owner : (& owner core.OwnershipObligation)]
  [mapping : (& mapping (__tl_dyn-array i64))]) : core.OwnershipObligation
  (let
    [retained : (__tl_dyn-array core.OwnershipCleanupUse)
      (__tl_make-array core.OwnershipCleanupUse (array-length owner.retained))]
    [index : i64 0]
    (begin
      (while (< index (array-length retained))
        (begin
          (set!
            (array-ref retained index)
            (match (& (array-ref owner.retained index))
              [(core.OwnershipCleanupUse.Read place)
                (core.OwnershipCleanupUse.Read
                  (core.ownership-place-id-copy place))]
              [(core.OwnershipCleanupUse.Through loan place)
                (core.OwnershipCleanupUse.Through
                  (core.ownership-loan-id-copy loan)
                  (core.ownership-place-id-copy place))]))
          (set! index (+ index 1))))
      (core.OwnershipObligation
        (match (& owner.parent)
          [(core.OwnershipObligationParent.Root)
            core.OwnershipObligationParent.Root]
          [(core.OwnershipObligationParent.Parent id)
            (core.OwnershipObligationParent.Parent (renamed-id id mapping))])
        (core.ownership-place-id-copy (& owner.place))
        (match (& owner.mode)
          [(core.OwnershipObligationMode.AutomaticRequired)
            core.OwnershipObligationMode.AutomaticRequired]
          [(core.OwnershipObligationMode.Discharge)
            core.OwnershipObligationMode.Discharge])
        (core.ownership-cleanup-id-copy (& owner.cleanup))
        retained
        (core.ownership-source-copy (& owner.source))))))

(define (mapping-valid?
  [body : (& body core.OwnershipBody)]
  [mapping : (& mapping (__tl_dyn-array i64))]) : bool
  (let
    [count : i64 (array-length body.obligations)]
    [index : i64 0]
    [work : i64 0]
    [bytes : i64 0]
    (begin
      ;; These explicit small-fixture caps precede every output allocation.
      (when
        (or
          (> count 128)
          (!= count (array-length mapping))
          (> (array-length body.blocks) 256))
        (return false))
      (let
        [seen : (__tl_dyn-array bool) (__tl_make-array bool count)]
        (begin
          (while (< index count)
            (begin
              (set! (array-ref seen index) false)
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index count)
            (let
              [into : i64 (array-ref mapping index)]
              [owner : (& body core.OwnershipObligation)
                (& (array-ref body.obligations index))]
              (begin
                (when (or (< into 0) (>= into count)) (return false))
                (when (array-ref seen into) (return false))
                (set! (array-ref seen into) true)
                (unless
                  (match (& owner.parent)
                    [(core.OwnershipObligationParent.Root) true]
                    [(core.OwnershipObligationParent.Parent id)
                      (core.ownership-obligation-id? (& body) id)])
                  (return false))
                (unless
                  (and
                    (core.ownership-charge!
                      (&mut work)
                      4096
                      (array-length owner.retained))
                    (core.ownership-charge!
                      (&mut bytes)
                      65536
                      (string.string-length (& owner.source.path)))
                    (core.ownership-charge!
                      (&mut bytes)
                      65536
                      (string.string-length (& owner.source.expansion))))
                  (return false))
                (set! index (+ index 1)))))))
      (set! index 0)
      (while (< index (array-length body.blocks))
        (let
          [instructions : (& body (__tl_dyn-array core.OwnershipInstruction))
            (& (array-ref body.blocks index).instructions)]
          [instruction : i64 0]
          (begin
            (unless
              (core.ownership-charge!
                (&mut work)
                4096
                (array-length instructions))
              (return false))
            (while (< instruction (array-length instructions))
              (let
                [operation : (& body core.OwnershipOperation)
                  (& (array-ref instructions instruction).operation)]
                (begin
                  (when
                    (and
                      (has-owner? operation)
                      (not (owner-valid? (& body) operation)))
                    (return false))
                  (set! instruction (+ instruction 1)))))
            (set! index (+ index 1)))))
      true)))

(define (rename!
  [body : (&mut body core.OwnershipBody)]
  [mapping : (& mapping (__tl_dyn-array i64))]) : bool
  (let
    [count : i64 (array-length body.obligations)]
    [index : i64 0]
    (begin
      (unless (mapping-valid? (& body) mapping) (return false))
      (let
        [owners : (__tl_dyn-array core.OwnershipObligation)
          (__tl_make-array core.OwnershipObligation count)]
        (begin
          (set! index 0)
          (while (< index count)
            (begin
              (set!
                (array-ref owners (array-ref mapping index))
                (renamed-obligation
                  (& (array-ref body.obligations index))
                  mapping))
              (set! index (+ index 1))))
          (set! body.obligations owners)))
      (set! index 0)
      (while (< index (array-length body.blocks))
        (let
          [instruction : i64 0]
          (begin
            (while (<
              instruction
              (array-length (array-ref body.blocks index).instructions))
              (begin
                (when
                  (has-owner?
                    (&
                      (array-ref
                        (array-ref body.blocks index).instructions
                        instruction).operation))
                  (let
                    [operation : core.OwnershipOperation
                      (renamed-operation
                        (&
                          (array-ref
                            (array-ref body.blocks index).instructions
                            instruction).operation)
                        mapping)]
                    (set!
                      (array-ref
                        (array-ref body.blocks index).instructions
                        instruction).operation
                      operation)))
                (set! instruction (+ instruction 1))))
            (set! index (+ index 1)))))
      true)))

;; mode0 identity, mode1 reverse, mode2 rotate by one. Fresh maps are body-local.
(define (apply-mode! [body : (&mut body core.OwnershipBody)] [mode : i64]) : bool
  (let
    [count : i64 (array-length body.obligations)]
    (if (or (< mode 0) (> mode 2) (> count 128))
      false
      (let
        [mapping : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [index : i64 0]
        (begin
          (while (< index count)
            (begin
              (set!
                (array-ref mapping index)
                (match mode
                  [0 index]
                  [1 (- (- count index) 1)]
                  [_
                    (if (= (+ index 1) count)
                      0
                      (+ index 1))]))
              (set! index (+ index 1))))
          (rename! body (& mapping)))))))