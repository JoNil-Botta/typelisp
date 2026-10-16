;; Shared concrete inputs only. Expected cleanup semantics live in the oracle
;; and the separate closed truth table, never in this fixture constructor.
(import cleanup_model as model)

(defstruct Input
  (modes (Array model.Mode 2))
  (trace (__tl_dyn-array model.Event)))

(define (mode [mask : i64] [bit : i64]) : model.Mode
  (if (= (bit-and mask bit) 0)
    model.Mode.Automatic
    model.Mode.Discharge))

(define (operation [code : i64]) : model.Event
  (match code
    [0 (model.Event.Read model.Owner.Outer)]
    [1 (model.Event.Read model.Owner.Inner)]
    [2 (model.Event.Move model.Owner.Outer model.Owner.Inner)]
    [3 (model.Event.Move model.Owner.Inner model.Owner.Outer)]
    [4 (model.Event.Cleanup model.Owner.Outer)]
    [5 (model.Event.Cleanup model.Owner.Inner)]
    [6 (model.Event.Initialize model.Owner.Outer)]
    [7 (model.Event.Initialize model.Owner.Inner)]
    [8 (model.Event.Return model.Owner.Outer)]
    [9 (model.Event.Return model.Owner.Inner)]
    [10 model.Event.Abort]
    [_ model.Event.Exit]))

;; Caller enumerates manual and initial in 0..3, operation in 0..11.
(define (direct-input [manual : i64] [initial : i64] [code : i64]) : Input
  (let
    [outer : bool (!= (bit-and initial 1) 0)]
    [inner : bool (!= (bit-and initial 2) 0)]
    [setup : i64
      (+
        (if outer
          1
          0)
        (if inner
          1
          0))]
    [trace : (__tl_dyn-array model.Event)
      (__tl_make-array model.Event (+ setup 2))]
    [position : i64 0]
    (begin
      (when
        outer
        (begin
          (set!
            (array-ref trace position)
            (model.Event.Initialize model.Owner.Outer))
          (set! position (+ position 1))))
      (when
        inner
        (begin
          (set!
            (array-ref trace position)
            (model.Event.Initialize model.Owner.Inner))
          (set! position (+ position 1))))
      (set! (array-ref trace position) (operation code))
      (set! (array-ref trace (+ position 1)) model.Event.Exit)
      (Input (array (mode manual 1) (mode manual 2)) trace))))

;; Explicit construction/activation/lexical-order traces. No expected
;; acceptance, rejection index, or cleanup sequence is encoded here.
(define (control-count) : i64
  30)

(define (control-input [code : i64]) : Input
  (let
    [manual : bool (or (= code 6) (= code 9) (= code 10) (= code 16))]
    [modes : (Array model.Mode 2)
      (array
        (if (or manual (= code 8))
          model.Mode.Discharge
          model.Mode.Automatic)
        (if manual
          model.Mode.Discharge
          model.Mode.Automatic))]
    [trace : (__tl_dyn-array model.Event)
      (match code
        [0
          (__tl_make-array
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.Initialize model.Owner.Outer)
            model.Event.Exit)]
        [1
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.Cleanup model.Owner.Outer)
            (model.Event.Reinitialize model.Owner.Outer)
            model.Event.Exit)]
        [2
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.InitializeField model.Owner.Inner model.Field.Left)
            model.Event.Exit)]
        [3
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.Leave model.Owner.Inner)
            model.Event.Exit)]
        [4
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.BindComplete model.Owner.Outer)
            model.Event.Exit)]
        [5
          (__tl_make-array
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            model.Event.Exit
            model.Event.Exit)]
        [6
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Cleanup model.Owner.Outer)
            (model.Event.Initialize model.Owner.Outer)
            model.Event.Exit)]
        [7
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.Leave model.Owner.Outer)
            model.Event.Exit)]
        [8
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            (model.Event.InitializeField model.Owner.Inner model.Field.Right)
            (model.Event.BindComplete model.Owner.Inner)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.Cleanup model.Owner.Outer)
            model.Event.Exit)]
        [9
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Right
              model.Owner.Inner
              model.Field.Right)
            (model.Event.BindComplete model.Owner.Inner)
            (model.Event.Cleanup model.Owner.Inner)
            model.Event.Exit)]
        [10
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            model.Event.Abort)]
        [11
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.InitializeField model.Owner.Outer model.Field.Right)
            (model.Event.Cleanup model.Owner.Outer)
            (model.Event.Leave model.Owner.Outer)
            model.Event.Exit)]
        [12
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.CleanupField model.Owner.Outer model.Field.Left)
            (model.Event.Leave model.Owner.Outer)
            model.Event.Exit)]
        [13
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            model.Event.Abort)]
        [14
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.InitializeField model.Owner.Outer model.Field.Right)
            model.Event.Exit)]
        [15
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.CleanupField model.Owner.Outer model.Field.Left)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            model.Event.Exit)]
        [16
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.CleanupField model.Owner.Outer model.Field.Left)
            (model.Event.CleanupField model.Owner.Outer model.Field.Right)
            model.Event.Exit)]
        [17
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.BindComplete model.Owner.Outer)
            model.Event.Exit)]
        [18
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Leave model.Owner.Outer)
            (model.Event.Initialize model.Owner.Outer)
            model.Event.Exit)]
        [19
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.InitializeField model.Owner.Outer model.Field.Right)
            (model.Event.Move model.Owner.Outer model.Owner.Inner)
            (model.Event.Leave model.Owner.Inner)
            (model.Event.Leave model.Owner.Outer)
            model.Event.Exit)]
        [20
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.InitializeField model.Owner.Outer model.Field.Right)
            (model.Event.Return model.Owner.Outer))]
        [21
          (__tl_make-array
            (model.Event.BeginConstruction model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            (model.Event.Return model.Owner.Outer))]
        [22
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            (model.Event.InitializeField model.Owner.Inner model.Field.Right)
            (model.Event.BindComplete model.Owner.Inner)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            model.Event.Exit)]
        [23
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            (model.Event.InitializeField model.Owner.Inner model.Field.Right)
            (model.Event.BindComplete model.Owner.Inner)
            model.Event.Exit)]
        [24
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.BeginConstruction model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Right
              model.Owner.Inner
              model.Field.Right)
            (model.Event.BindComplete model.Owner.Inner)
            model.Event.Exit)]
        [25
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.AbortCleanup model.Owner.Inner))]
        [26
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.InitializeField model.Owner.Outer model.Field.Left)
            model.Event.Exit)]
        [27
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Reinitialize model.Owner.Outer)
            model.Event.Exit)]
        [28
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.MoveField
              model.Owner.Outer
              model.Field.Left
              model.Owner.Inner
              model.Field.Left)
            model.Event.Exit)]
        [_
          (__tl_make-array
            (model.Event.Initialize model.Owner.Outer)
            (model.Event.Initialize model.Owner.Inner)
            (model.Event.Leave model.Owner.Inner)
            (model.Event.Initialize model.Owner.Inner)
            model.Event.Exit)])]
    (Input modes trace)))