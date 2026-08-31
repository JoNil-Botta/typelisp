;# Explicit deep-clone declaration generation and the transitional compiler
;# handoff for compiler-checked `(clone value)` roots.
;#
;# `(gen-clone T)` is the public direction: an owning module requests one
;# ordinary `clone-<kebab-name>` function with signature `(& T) -> T`. The
;# generated body reconstructs the aggregate and uses only ordinary language
;# and stdlib operations. Nominal dependencies must have their own generated
;# clone function already available from their canonical owner module.
;#
;# `synthesize-helpers` remains temporarily while compiler and repository call
;# sites migrate away from the semantic `(clone value)` form.
(import stdlib.comptime)
(import stdlib.string as string)

;: Emit ordinary cloning for a fixed array whose source is a shared reference.
(defmacro (clone-fixed-array
  [T : type]
  [source : comptime.Expr]
  [root-key-expr : comptime.Expr]
  [path-expr : comptime.Expr]
  [index-expr : comptime.Expr]
  [items : comptime.Expr ...]) : comptime.Expr
  (match index-expr
    [(comptime.Expr.Int index)
      (if (>= index (array-length T))
        `(array ,@items)
        (let
          [element-type : comptime.Expr (array-element-type T)]
          [item-place : comptime.Expr
            (comptime.expr-array-ref `(deref ,source) (comptime.expr-int index))]
          [item-source : comptime.Expr (comptime.expr-borrow item-place)]
          [item-path : comptime.Expr
            (comptime.expr-string
              (comptime.string-append
                (comptime.expr-string-value path-expr)
                (comptime.string-append
                  "["
                  (comptime.string-append (comptime.int->string index) "]"))))]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [cloned-item : comptime.Expr
            (match (type-kind element-type)
              ["string" `(stdlib.string.copy ,item-source)]
              ["unit" `unit]
              ["bool" `(deref ,item-source)]
              ["char" `(deref ,item-source)]
              ["i64" `(deref ,item-source)]
              ["i32" `(deref ,item-source)]
              ["i16" `(deref ,item-source)]
              ["i8" `(deref ,item-source)]
              ["u64" `(deref ,item-source)]
              ["u32" `(deref ,item-source)]
              ["u16" `(deref ,item-source)]
              ["u8" `(deref ,item-source)]
              ["f64" `(deref ,item-source)]
              ["f32" `(deref ,item-source)]
              [_
                `(stdlib.clone.clone-value
                  ,element-type
                  ,item-source
                  ,root-key-expr
                  ,item-path)])]
          `(stdlib.clone.clone-fixed-array
            ,T
            ,source
            ,root-key-expr
            ,path-expr
            ,next-index
            ,@items
            ,cloned-item)))]
    [_
      (comptime.comptime-error
        "gen-clone: fixed-array index must be an integer literal")]))

;: Emit ordinary cloning for a tuple whose source is a shared reference.
(defmacro (clone-tuple
  [T : type]
  [source : comptime.Expr]
  [root-key-expr : comptime.Expr]
  [path-expr : comptime.Expr]
  [index-expr : comptime.Expr]
  [items : comptime.Expr ...]) : comptime.Expr
  (match index-expr
    [(comptime.Expr.Int index)
      (if (>= index (tuple-element-count T))
        `(tuple ,@items)
        (let
          [element-type : comptime.Expr (tuple-element-type T index)]
          [item-place : comptime.Expr
            (comptime.expr-tuple-ref `(deref ,source) index)]
          [item-source : comptime.Expr (comptime.expr-borrow item-place)]
          [item-path : comptime.Expr
            (comptime.expr-string
              (comptime.string-append
                (comptime.expr-string-value path-expr)
                (comptime.string-append
                  "["
                  (comptime.string-append (comptime.int->string index) "]"))))]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [cloned-item : comptime.Expr
            (match (type-kind element-type)
              ["string" `(stdlib.string.copy ,item-source)]
              ["unit" `unit]
              ["bool" `(deref ,item-source)]
              ["char" `(deref ,item-source)]
              ["i64" `(deref ,item-source)]
              ["i32" `(deref ,item-source)]
              ["i16" `(deref ,item-source)]
              ["i8" `(deref ,item-source)]
              ["u64" `(deref ,item-source)]
              ["u32" `(deref ,item-source)]
              ["u16" `(deref ,item-source)]
              ["u8" `(deref ,item-source)]
              ["f64" `(deref ,item-source)]
              ["f32" `(deref ,item-source)]
              [_
                `(stdlib.clone.clone-value
                  ,element-type
                  ,item-source
                  ,root-key-expr
                  ,item-path)])]
          `(stdlib.clone.clone-tuple
            ,T
            ,source
            ,root-key-expr
            ,path-expr
            ,next-index
            ,@items
            ,cloned-item)))]
    [_
      (comptime.comptime-error
        "gen-clone: tuple index must be an integer literal")]))

;; Name construction intentionally lives in macro CTFE rather than an ordinary
;; helper call: every operation below is part of the source/native TLCI macro
;; contract. Acronym boundaries follow `HTTPServer` -> `http-server`.
;: Resolve and call one explicitly generated nominal clone dependency.
(defmacro (clone-nominal-value
  [T : type (:kind struct enum)]
  [source : comptime.Expr]
  [root-key-expr : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [type-key-text : String (type-key T)]
    [path : String (comptime.expr-string-value path-expr)]
    [root-key : String (comptime.expr-string-value root-key-expr)]
    (if (type-cleanup-owning? T)
      (comptime.comptime-error
        (comptime.string-append
          "gen-clone: unsupported cleanup-owning type "
          (comptime.string-append
            type-key-text
            (comptime.string-append " at " path))))
      (if (string-eq type-key-text root-key)
        (comptime.comptime-error
          (comptime.string-append
            "gen-clone: cyclic clone dependency reaches "
            (comptime.string-append
              root-key
              (comptime.string-append " at " path))))
        (let
          [owner : String (type-nominal-module T)]
          [owner-display : String
            (if (string-eq owner "")
              "<root>"
              owner)]
          [type-name : String (type-nominal-name T)]
          [length : i64 (string.string-length type-name)]
          [index : i64 0]
          [lowercase-alphabet : String "abcdefghijklmnopqrstuvwxyz"]
          [decimal-digits : String "0123456789"]
          [function-name : String "clone-"]
          [last-was-separator : bool false]
          (begin
            (if (= length 0)
              (comptime.comptime-error
                "gen-clone: nominal dependency name is empty")
              unit)
            (while (< index length)
              (let
                [code : i64 (cast (string.string-ref type-name index) : i64)]
                [upper? : bool
                  (if (>= code 65)
                    (<= code 90)
                    false)]
                [lower? : bool
                  (if (>= code 97)
                    (<= code 122)
                    false)]
                [digit? : bool
                  (if (>= code 48)
                    (<= code 57)
                    false)]
                [separator? : bool
                  (if (= code 45)
                    true
                    (= code 95))]
                (begin
                  (if separator?
                    (if (if (= index 0)
                      true
                      last-was-separator)
                      (comptime.comptime-error
                        "gen-clone: nominal name has an ambiguous separator")
                      (begin
                        (set!
                          function-name
                          (comptime.string-append function-name "-"))
                        (set! last-was-separator true)))
                    (if upper?
                      (let
                        [previous-code : i64
                          (if (> index 0)
                            (cast
                              (string.string-ref type-name (- index 1))
                              : i64)
                            0)]
                        [next-code : i64
                          (if (< (+ index 1) length)
                            (cast
                              (string.string-ref type-name (+ index 1))
                              : i64)
                            0)]
                        [previous-lower? : bool
                          (if (>= previous-code 97)
                            (<= previous-code 122)
                            false)]
                        [previous-digit? : bool
                          (if (>= previous-code 48)
                            (<= previous-code 57)
                            false)]
                        [previous-upper? : bool
                          (if (>= previous-code 65)
                            (<= previous-code 90)
                            false)]
                        [next-lower? : bool
                          (if (>= next-code 97)
                            (<= next-code 122)
                            false)]
                        [word-boundary? : bool
                          (if (= index 0)
                            false
                            (if previous-lower?
                              true
                              (if previous-digit?
                                true
                                (if previous-upper?
                                  next-lower?
                                  false))))]
                        (begin
                          (if (if word-boundary?
                            (= last-was-separator false)
                            false)
                            (set!
                              function-name
                              (comptime.string-append function-name "-"))
                            unit)
                          (set!
                            function-name
                            (comptime.string-append
                              function-name
                              (comptime.string-slice
                                lowercase-alphabet
                                (- code 65)
                                1)))
                          (set! last-was-separator false)))
                      (if lower?
                        (begin
                          (set!
                            function-name
                            (comptime.string-append
                              function-name
                              (comptime.string-slice
                                lowercase-alphabet
                                (- code 97)
                                1)))
                          (set! last-was-separator false))
                        (if digit?
                          (begin
                            (set!
                              function-name
                              (comptime.string-append
                                function-name
                                (comptime.string-slice
                                  decimal-digits
                                  (- code 48)
                                  1)))
                            (set! last-was-separator false))
                          (comptime.comptime-error
                            "gen-clone: unsupported character in nominal name")))))
                  (set! index (+ index 1)))))
            (if last-was-separator
              (comptime.comptime-error
                "gen-clone: nominal name ends in a separator")
              unit)
            (let
              [present? : bool (comptime.module-value? owner function-name)]
              (if present?
                ;; The generated ordinary call deliberately leaves signature
                ;; validation to the normal typechecker. This keeps clone
                ;; dependencies subject to exactly the same borrow/return
                ;; rules as any other function call.
                (comptime.expr-call
                  (comptime.module-value-expr owner function-name)
                  (comptime.expr-list-cons source (comptime.expr-list-empty)))
                (comptime.comptime-error
                  (comptime.string-append
                    "gen-clone: missing explicit dependency "
                    (comptime.string-append
                      function-name
                      (comptime.string-append
                        " for "
                        (comptime.string-append
                          (type-key T)
                          (comptime.string-append
                            " at "
                            (comptime.string-append
                              path
                              (comptime.string-append
                                " from owner "
                                (comptime.string-append
                                  owner-display
                                  "; invoke gen-clone in its owner module first")))))))))))))))))

;: Emit an ordinary deep copy for one shared-reference source expression.
(defmacro (clone-value
  [T : type]
  [source : comptime.Expr]
  [root-key-expr : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [kind : String (type-kind T)]
    [path : String (comptime.expr-string-value path-expr)]
    [root-key : String (comptime.expr-string-value root-key-expr)]
    (match kind
      ["unit" `unit]
      ["never" `(deref ,source)]
      ["bool" `(deref ,source)]
      ["char" `(deref ,source)]
      ["i64" `(deref ,source)]
      ["i32" `(deref ,source)]
      ["i16" `(deref ,source)]
      ["i8" `(deref ,source)]
      ["u64" `(deref ,source)]
      ["u32" `(deref ,source)]
      ["u16" `(deref ,source)]
      ["u8" `(deref ,source)]
      ["f64" `(deref ,source)]
      ["f32" `(deref ,source)]
      ["string" `(stdlib.string.copy ,source)]
      ["tuple"
        `(let
          [__clone_tuple_source ,source]
          (stdlib.clone.clone-tuple
            ,T
            __clone_tuple_source
            ,root-key-expr
            ,path-expr
            0))]
      ["array"
        (if (array-dynamic? T)
          (comptime.comptime-error
            (comptime.string-append
              "gen-clone: unsupported dynamic array classified as fixed at "
              path))
          `(let
            [__clone_array_source ,source]
            (stdlib.clone.clone-fixed-array
              ,T
              __clone_array_source
              ,root-key-expr
              ,path-expr
              0)))]
      ["dyn-array"
        (let
          [element-type : comptime.Expr (array-element-type T)]
          [element-path : comptime.Expr
            (comptime.expr-string (comptime.string-append path "[]"))]
          `(let
            [__clone_source ,source]
            [__clone_len : i64 (array-length __clone_source)]
            [__clone_out : ,T (__tl_make-array ,element-type __clone_len)]
            [__clone_index : i64 0]
            (begin
              (while (< __clone_index __clone_len)
                (begin
                  (set!
                    (array-ref __clone_out __clone_index)
                    (stdlib.clone.clone-value
                      ,element-type
                      (& (array-ref __clone_source __clone_index))
                      ,root-key-expr
                      ,element-path))
                  (set! __clone_index (+ __clone_index 1))))
              __clone_out)))]
      ["box"
        (let
          [element-type : comptime.Expr (comptime.box-element-type T)]
          [element-path : comptime.Expr
            (comptime.expr-string (comptime.string-append path ".box"))]
          `(let
            [__clone_box_source ,source]
            (box
              (stdlib.clone.clone-value
                ,element-type
                (& (deref (deref __clone_box_source)))
                ,root-key-expr
                ,element-path))))]
      ["struct"
        `(stdlib.clone.clone-nominal-value ,T ,source ,root-key-expr ,path-expr)]
      ["enum"
        `(stdlib.clone.clone-nominal-value ,T ,source ,root-key-expr ,path-expr)]
      [_
        (comptime.comptime-error
          (comptime.string-append
            "gen-clone: unsupported type "
            (comptime.string-append
              (type-key T)
              (comptime.string-append " at " path))))])))

;: Generate the body of an ordinary clone function for a struct root.
(defmacro (clone-struct-root [T : type] [root-key-expr : comptime.Expr]) : comptime.Expr
  (let
    [type-name : String (type-nominal-name T)]
    [constructor : comptime.Expr (comptime.expr-var type-name)]
    [index : i64 (- (struct-field-count T) 1)]
    [args : comptime.ExprList (comptime.expr-list-empty)]
    (begin
      (while (>= index 0)
        (let
          [field-name : String (struct-field-name T index)]
          [field-type : comptime.Expr (struct-field-type T index)]
          [field-place : comptime.Expr
            (comptime.expr-struct-get (comptime.expr-var "value") field-name)]
          [field-source : comptime.Expr (comptime.expr-borrow field-place)]
          [field-path : comptime.Expr
            (comptime.expr-string
              (comptime.string-append
                type-name
                (comptime.string-append "." field-name)))]
          (begin
            (set!
              args
              (comptime.expr-list-cons
                `(stdlib.clone.clone-value
                  ,field-type
                  ,field-source
                  ,root-key-expr
                  ,field-path)
                args))
            (set! index (- index 1)))))
      (comptime.expr-call constructor args))))

;: Generate the body of an ordinary clone function for an enum root.
(defmacro (clone-enum-root [T : type] [root-key-expr : comptime.Expr]) : comptime.Expr
  (let
    [type-name : String (type-nominal-name T)]
    [variant-index : i64 (- (enum-variant-count T) 1)]
    [arms : comptime.MatchArmList (comptime.match-arm-list-empty)]
    (begin
      (while (>= variant-index 0)
        (let
          [variant-name : String (enum-variant-name T variant-index)]
          [qualified-variant : String
            (comptime.string-append
              type-name
              (comptime.string-append "." variant-name))]
          [payload-count : i64 (enum-variant-payload-count T variant-index)]
          [binding-prefix : String
            (comptime.string-append
              "__clone_payload_"
              (comptime.string-append (comptime.int->string variant-index) "_"))]
          [args : comptime.ExprList (comptime.expr-list-empty)]
          [payload-index : i64 (- payload-count 1)]
          (begin
            (while (>= payload-index 0)
              (let
                [payload-type : comptime.Expr
                  (enum-variant-payload-type T variant-index payload-index)]
                [binding : comptime.Expr
                  (comptime.expr-var
                    (comptime.string-append
                      binding-prefix
                      (comptime.int->string payload-index)))]
                [payload-path : comptime.Expr
                  (comptime.expr-string
                    (comptime.string-append
                      type-name
                      (comptime.string-append
                        "."
                        (comptime.string-append
                          variant-name
                          (comptime.string-append
                            "["
                            (comptime.string-append
                              (comptime.int->string payload-index)
                              "]"))))))]
                (begin
                  (set!
                    args
                    (comptime.expr-list-cons
                      `(stdlib.clone.clone-value
                        ,payload-type
                        ,binding
                        ,root-key-expr
                        ,payload-path)
                      args))
                  (set! payload-index (- payload-index 1)))))
            (let
              [pattern : comptime.Pattern
                (comptime.pattern-variant
                  qualified-variant
                  (comptime.pattern-list-bindings binding-prefix payload-count))]
              [body : comptime.Expr
                (comptime.expr-call (comptime.expr-var qualified-variant) args)]
              (begin
                (set!
                  arms
                  (comptime.match-arm-list-cons
                    (comptime.match-arm pattern body)
                    arms))
                (set! variant-index (- variant-index 1)))))))
      (comptime.expr-match (comptime.expr-var "value") arms))))

;: Generate a public ordinary `clone-<type>` function in a nominal type's owner.
;:
;: The source is a shared borrow so the function preserves its input. Every
;: nominal dependency must already expose its own generated clone function.
(defmacro (gen-clone [T : type (:kind struct enum)]) : Decls
  (let
    [kind : String (type-kind T)]
    [owner : String (type-nominal-module T)]
    [owner-display : String
      (if (string-eq owner "")
        "<root>"
        owner)]
    [type-name : String (type-nominal-name T)]
    [length : i64 (string.string-length type-name)]
    [index : i64 0]
    [lowercase-alphabet : String "abcdefghijklmnopqrstuvwxyz"]
    [decimal-digits : String "0123456789"]
    [function-name-text : String "clone-"]
    [last-was-separator : bool false]
    (begin
      (if (type-cleanup-owning? T)
        (comptime.comptime-error
          (comptime.string-append
            "gen-clone: unsupported cleanup-owning root "
            (type-key T)))
        unit)
      (if (= length 0)
        (comptime.comptime-error "gen-clone: nominal root name is empty")
        unit)
      (while (< index length)
        (let
          [code : i64 (cast (string.string-ref type-name index) : i64)]
          [upper? : bool
            (if (>= code 65)
              (<= code 90)
              false)]
          [lower? : bool
            (if (>= code 97)
              (<= code 122)
              false)]
          [digit? : bool
            (if (>= code 48)
              (<= code 57)
              false)]
          [separator? : bool
            (if (= code 45)
              true
              (= code 95))]
          (begin
            (if separator?
              (if (if (= index 0)
                true
                last-was-separator)
                (comptime.comptime-error
                  "gen-clone: nominal name has an ambiguous separator")
                (begin
                  (set!
                    function-name-text
                    (comptime.string-append function-name-text "-"))
                  (set! last-was-separator true)))
              (if upper?
                (let
                  [previous-code : i64
                    (if (> index 0)
                      (cast (string.string-ref type-name (- index 1)) : i64)
                      0)]
                  [next-code : i64
                    (if (< (+ index 1) length)
                      (cast (string.string-ref type-name (+ index 1)) : i64)
                      0)]
                  [previous-lower? : bool
                    (if (>= previous-code 97)
                      (<= previous-code 122)
                      false)]
                  [previous-digit? : bool
                    (if (>= previous-code 48)
                      (<= previous-code 57)
                      false)]
                  [previous-upper? : bool
                    (if (>= previous-code 65)
                      (<= previous-code 90)
                      false)]
                  [next-lower? : bool
                    (if (>= next-code 97)
                      (<= next-code 122)
                      false)]
                  [word-boundary? : bool
                    (if (= index 0)
                      false
                      (if previous-lower?
                        true
                        (if previous-digit?
                          true
                          (if previous-upper?
                            next-lower?
                            false))))]
                  (begin
                    (if (if word-boundary?
                      (= last-was-separator false)
                      false)
                      (set!
                        function-name-text
                        (comptime.string-append function-name-text "-"))
                      unit)
                    (set!
                      function-name-text
                      (comptime.string-append
                        function-name-text
                        (comptime.string-slice lowercase-alphabet (- code 65) 1)))
                    (set! last-was-separator false)))
                (if lower?
                  (begin
                    (set!
                      function-name-text
                      (comptime.string-append
                        function-name-text
                        (comptime.string-slice lowercase-alphabet (- code 97) 1)))
                    (set! last-was-separator false))
                  (if digit?
                    (begin
                      (set!
                        function-name-text
                        (comptime.string-append
                          function-name-text
                          (comptime.string-slice decimal-digits (- code 48) 1)))
                      (set! last-was-separator false))
                    (comptime.comptime-error
                      "gen-clone: unsupported character in nominal name")))))
            (set! index (+ index 1)))))
      (if last-was-separator
        (comptime.comptime-error "gen-clone: nominal name ends in a separator")
        unit)
      (if (comptime.module-value? owner function-name-text)
        (comptime.comptime-error
          (comptime.string-append
            "gen-clone: generated name collision for "
            (comptime.string-append
              function-name-text
              (comptime.string-append
                " in canonical owner module "
                owner-display))))
        unit)
      (let
        [root-key-expr : comptime.Expr (comptime.expr-string (type-key T))]
        [function-name : comptime.Expr (comptime.expr-var function-name-text)]
        [body : comptime.Expr
          (match kind
            ["struct" `(stdlib.clone.clone-struct-root ,T ,root-key-expr)]
            ["enum" `(stdlib.clone.clone-enum-root ,T ,root-key-expr)]
            [_
              (comptime.comptime-error
                (comptime.string-append
                  "gen-clone: expected a nominal aggregate, got "
                  (type-key T)))])]
        `(define (,function-name [value : (& value ,T)]) : ,T
          ,body)))))

;: Emit clone helper declarations for all requested reachable aggregates.
(defmacro (synthesize-helpers [types : comptime.Expr ...]) : Decls
  (let
    [type-index : i64 (comptime.expr-list-length types)]
    [out : comptime.ExprList (comptime.expr-list-empty)]
    (begin
      (while (> type-index 0)
        (begin
          (set! type-index (- type-index 1))
          (let
            [type-expr : comptime.Expr
              (comptime.expr-list-type-nth types type-index)]
            (begin
              (set! type-index (- type-index 1))
              (let
                [module-name : comptime.Expr
                  (comptime.expr-var
                    (comptime.expr-string-value
                      (comptime.expr-list-nth types type-index)))]
                ;; Naming this reflection also changes the producer identity so
                ;; a published seed from before the native source-name handoff
                ;; evaluates this one bootstrap generation interpretively.
                [type-kind-name : String (type-kind type-expr)]
                (set!
                  out
                  (comptime.expr-list-cons
                    `(module ,module-name)
                    (match type-kind-name
                      ["struct"
                        (let
                          [type-name : String (type-nominal-name type-expr)]
                          [helper-name : comptime.Expr
                            (comptime.expr-var
                              (comptime.string-append "clone$" type-name))]
                          [type-ctor : comptime.Expr
                            (comptime.expr-var type-name)]
                          [args : comptime.ExprList (comptime.expr-list-empty)]
                          [index : i64 (- (struct-field-count type-expr) 1)]
                          (begin
                            (while (>= index 0)
                              (let
                                [field : comptime.Expr
                                  (comptime.expr-struct-get
                                    (comptime.expr-var "value")
                                    (struct-field-name type-expr index))]
                                (begin
                                  (set!
                                    args
                                    (comptime.expr-list-cons
                                      `(clone ,field)
                                      args))
                                  (set! index (- index 1)))))
                            (let
                              [body : comptime.Expr
                                (comptime.expr-call type-ctor args)]
                              (comptime.expr-list-cons
                                `(define (,helper-name [value : ,type-expr]) : ,type-expr
                                  ,body)
                                out))))]
                      ["enum"
                        (let
                          [type-name : String (type-nominal-name type-expr)]
                          [helper-text : String
                            (comptime.string-append "clone$" type-name)]
                          [helper-name : comptime.Expr
                            (comptime.expr-var helper-text)]
                          [variant-count : i64 (enum-variant-count type-expr)]
                          [first-count : i64
                            (if (= variant-count 2)
                              (enum-variant-payload-count type-expr 0)
                              -1)]
                          [nil-index : i64
                            (if (= first-count 0)
                              0
                              1)]
                          [cons-index : i64
                            (if (= first-count 0)
                              1
                              0)]
                          [list-candidate : bool
                            (if (= variant-count 2)
                              (if (=
                                (enum-variant-payload-count type-expr nil-index)
                                0)
                                (=
                                  (enum-variant-payload-count
                                    type-expr
                                    cons-index)
                                  2)
                                false)
                              false)]
                          [direct-self : bool false]
                          [boxed-self : bool false]
                          (begin
                            (if list-candidate
                              (let
                                [tail-type : comptime.Expr
                                  (enum-variant-payload-type
                                    type-expr
                                    cons-index
                                    1)]
                                (begin
                                  (set!
                                    direct-self
                                    (string-eq
                                      (type-key tail-type)
                                      (type-key type-expr)))
                                  (if (string-eq (type-kind tail-type) "box")
                                    (set!
                                      boxed-self
                                      (string-eq
                                        (type-key
                                          (comptime.box-element-type tail-type))
                                        (type-key type-expr)))
                                    unit)))
                              unit)
                            (if (if direct-self
                              true
                              boxed-self)
                              (let
                                [acc-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append helper-text "$acc"))]
                                [rev-name : comptime.Expr
                                  (comptime.expr-var
                                    (comptime.string-append helper-text "$rev"))]
                                [nil-text : String
                                  (comptime.string-append
                                    type-name
                                    (comptime.string-append
                                      "."
                                      (enum-variant-name type-expr nil-index)))]
                                [nil-name : comptime.Expr
                                  (comptime.expr-var nil-text)]
                                [cons-text : String
                                  (comptime.string-append
                                    type-name
                                    (comptime.string-append
                                      "."
                                      (enum-variant-name type-expr cons-index)))]
                                [cons-name : comptime.Expr
                                  (comptime.expr-var cons-text)]
                                [nil-pattern : comptime.Pattern
                                  (comptime.pattern-variant
                                    nil-text
                                    (comptime.pattern-list-empty))]
                                [cons-pattern : comptime.Pattern
                                  (comptime.pattern-variant
                                    cons-text
                                    (comptime.pattern-list-cons
                                      (comptime.pattern-binding "head")
                                      (comptime.pattern-list-cons
                                        (comptime.pattern-binding "tail")
                                        (comptime.pattern-list-empty))))]
                                [next-tail : comptime.Expr
                                  (if boxed-self
                                    `(__tl-box-place tail)
                                    `tail)]
                                [acc-tail : comptime.Expr
                                  (if boxed-self
                                    `(box acc)
                                    `acc)]
                                [acc-cons : comptime.Expr
                                  (comptime.expr-call
                                    cons-name
                                    (comptime.expr-list-cons
                                      `(clone head)
                                      (comptime.expr-list-cons
                                        acc-tail
                                        (comptime.expr-list-empty))))]
                                [rev-cons : comptime.Expr
                                  (comptime.expr-call
                                    cons-name
                                    (comptime.expr-list-cons
                                      `head
                                      (comptime.expr-list-cons
                                        acc-tail
                                        (comptime.expr-list-empty))))]
                                [acc-step : comptime.Expr
                                  (comptime.expr-call
                                    acc-name
                                    (comptime.expr-list-cons
                                      next-tail
                                      (comptime.expr-list-cons
                                        acc-cons
                                        (comptime.expr-list-empty))))]
                                [rev-step : comptime.Expr
                                  (comptime.expr-call
                                    rev-name
                                    (comptime.expr-list-cons
                                      next-tail
                                      (comptime.expr-list-cons
                                        rev-cons
                                        (comptime.expr-list-empty))))]
                                [acc-body : comptime.Expr
                                  (comptime.expr-match
                                    (comptime.expr-var "value")
                                    (comptime.match-arm-list-cons
                                      (comptime.match-arm
                                        nil-pattern
                                        (comptime.expr-var "acc"))
                                      (comptime.match-arm-list-cons
                                        (comptime.match-arm
                                          cons-pattern
                                          acc-step)
                                        (comptime.match-arm-list-empty))))]
                                [rev-body : comptime.Expr
                                  (comptime.expr-match
                                    (comptime.expr-var "value")
                                    (comptime.match-arm-list-cons
                                      (comptime.match-arm
                                        nil-pattern
                                        (comptime.expr-var "acc"))
                                      (comptime.match-arm-list-cons
                                        (comptime.match-arm
                                          cons-pattern
                                          rev-step)
                                        (comptime.match-arm-list-empty))))]
                                (comptime.expr-list-cons
                                  `(define (,helper-name [value : ,type-expr]) : ,type-expr
                                    (,rev-name
                                      (,acc-name value (,nil-name))
                                      (,nil-name)))
                                  (comptime.expr-list-cons
                                    `(define (,acc-name
                                      [value : ,type-expr]
                                      [acc : ,type-expr]) : ,type-expr
                                      ,acc-body)
                                    (comptime.expr-list-cons
                                      `(define (,rev-name
                                        [value : ,type-expr]
                                        [acc : ,type-expr]) : ,type-expr
                                        ,rev-body)
                                      out))))
                              (let
                                [arms : comptime.MatchArmList
                                  (comptime.match-arm-list-empty)]
                                [variant-index : i64 (- variant-count 1)]
                                (begin
                                  (while (>= variant-index 0)
                                    (let
                                      [variant-name : String
                                        (enum-variant-name
                                          type-expr
                                          variant-index)]
                                      [qualified-variant : String
                                        (comptime.string-append
                                          type-name
                                          (comptime.string-append
                                            "."
                                            variant-name))]
                                      [payload-count : i64
                                        (enum-variant-payload-count
                                          type-expr
                                          variant-index)]
                                      [binding-prefix : String
                                        (comptime.string-append
                                          "__clone_payload_"
                                          (comptime.string-append
                                            (comptime.int->string variant-index)
                                            "_"))]
                                      [ctor-args : comptime.ExprList
                                        (comptime.expr-list-empty)]
                                      [payload-index : i64 (- payload-count 1)]
                                      (begin
                                        (while (>= payload-index 0)
                                          (let
                                            [binding : comptime.Expr
                                              (comptime.expr-var
                                                (comptime.string-append
                                                  binding-prefix
                                                  (comptime.int->string
                                                    payload-index)))]
                                            (begin
                                              (set!
                                                ctor-args
                                                (comptime.expr-list-cons
                                                  `(clone ,binding)
                                                  ctor-args))
                                              (set!
                                                payload-index
                                                (- payload-index 1)))))
                                        (let
                                          [pattern : comptime.Pattern
                                            (comptime.pattern-variant
                                              qualified-variant
                                              (comptime.pattern-list-bindings
                                                binding-prefix
                                                payload-count))]
                                          [body : comptime.Expr
                                            (comptime.expr-call
                                              (comptime.expr-var
                                                qualified-variant)
                                              ctor-args)]
                                          (begin
                                            (set!
                                              arms
                                              (comptime.match-arm-list-cons
                                                (comptime.match-arm
                                                  pattern
                                                  body)
                                                arms))
                                            (set!
                                              variant-index
                                              (- variant-index 1)))))))
                                  (let
                                    [body : comptime.Expr
                                      (comptime.expr-match
                                        (comptime.expr-var "value")
                                        arms)]
                                    (comptime.expr-list-cons
                                      `(define (,helper-name
                                        [value : ,type-expr]) : ,type-expr
                                        ,body)
                                      out)))))))]
                      [_
                        (comptime.comptime-error
                          (comptime.string-append
                            "clone: stdlib handoff expected a named aggregate, got "
                            (type-key type-expr)))]))))))))
      (comptime.expr-call (comptime.expr-var "begin") out))))