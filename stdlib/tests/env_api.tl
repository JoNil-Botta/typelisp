(import stdlib.array)
(import stdlib.env)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (env-api-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (env-api-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (env-api-assert-true (= actual expected) message))

(define (env-api-assert-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (env-api-assert-true (string.eq actual expected) message))

;: Construct an owned three-byte string containing an interior NUL.
(define (env-api-string-with-nul) : String
  (let
    [bytes : (Array u8) (array.make-array u8 3)]
    (begin
      (array-set! bytes 0 (cast 'a' : u8))
      (array-set! bytes 1 (cast 0 : u8))
      (array-set! bytes 2 (cast 'b' : u8))
      (unsafe
        (string-from-bytes (ptr-cast (array-data bytes) : (Ptr u8)) 3)))))

(define (env-api-assert-none [value : env.EnvMaybeString] [message : String]) : unit
  (match value
    [(env.EnvNoString) unit]
    [(env.EnvSomeString _) (io.panic message)]))

(define (env-api-assert-some
  [value : env.EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeString actual)
      (env-api-assert-string-eq actual expected message)]
    [(env.EnvNoString) (io.panic message)]))

(define (env-api-assert-path-none
  [value : env.EnvMaybeStringList]
  [message : String]) : unit
  (match value
    [(env.EnvNoStringList) unit]
    [(env.EnvSomeStringList _) (io.panic message)]))

(define (env-api-assert-path-vec-none
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvNoStringVec) unit]
    [(env.EnvSomeStringVec _) (io.panic message)]))

(define (env-api-assert-path-empty
  [value : env.EnvMaybeStringList]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (match items
        [(env.EnvStringNil) unit]
        [_ (io.panic message)])]
    [(env.EnvNoStringList) (io.panic message)]))

(define (env-api-assert-path-vec-empty
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items)
      (env-api-assert-i64-eq (svec.len (& items)) 0 message)]
    [(env.EnvNoStringVec) (io.panic message)]))

(define (env-api-assert-list3
  [items : env.EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(env.EnvStringCons a rest)
      (match (box-get rest)
        [(env.EnvStringCons b tail)
          (match (box-get tail)
            [(env.EnvStringCons c end)
              (match (box-get end)
                [(env.EnvStringNil)
                  (begin
                    (env-api-assert-string-eq a first message)
                    (env-api-assert-string-eq b second message)
                    (env-api-assert-string-eq c third message))]
                [_ (io.panic message)])]
            [_ (io.panic message)])]
        [_ (io.panic message)])]
    [_ (io.panic message)]))

(define (env-api-assert-list5
  [items : env.EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (match items
    [(env.EnvStringCons a rest)
      (match (box-get rest)
        [(env.EnvStringCons b rest2)
          (match (box-get rest2)
            [(env.EnvStringCons c rest3)
              (match (box-get rest3)
                [(env.EnvStringCons d rest4)
                  (match (box-get rest4)
                    [(env.EnvStringCons e end)
                      (match (box-get end)
                        [(env.EnvStringNil)
                          (begin
                            (env-api-assert-string-eq a first message)
                            (env-api-assert-string-eq b second message)
                            (env-api-assert-string-eq c third message)
                            (env-api-assert-string-eq d fourth message)
                            (env-api-assert-string-eq e fifth message))]
                        [_ (io.panic message)])]
                    [_ (io.panic message)])]
                [_ (io.panic message)])]
            [_ (io.panic message)])]
        [_ (io.panic message)])]
    [_ (io.panic message)]))

(define (env-api-assert-vec3
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (env-api-assert-i64-eq (svec.len (& items)) 3 message)
    (env-api-assert-string-eq (svec.get (& items) 0 "missing") first message)
    (env-api-assert-string-eq (svec.get (& items) 1 "missing") second message)
    (env-api-assert-string-eq (svec.get (& items) 2 "missing") third message)))

(define (env-api-assert-vec5
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (env-api-assert-i64-eq (svec.len (& items)) 5 message)
    (env-api-assert-string-eq (svec.get (& items) 0 "missing") first message)
    (env-api-assert-string-eq (svec.get (& items) 1 "missing") second message)
    (env-api-assert-string-eq (svec.get (& items) 2 "missing") third message)
    (env-api-assert-string-eq (svec.get (& items) 3 "missing") fourth message)
    (env-api-assert-string-eq (svec.get (& items) 4 "missing") fifth message)))

(define (env-api-assert-path3
  [value : env.EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (env-api-assert-list3 items first second third message)]
    [(env.EnvNoStringList) (io.panic message)]))

(define (env-api-assert-path-vec3
  [value : env.EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items)
      (env-api-assert-vec3 items first second third message)]
    [(env.EnvNoStringVec) (io.panic message)]))

(test
  env-api
  (begin
    (let
      [name : String "TYPELISP_STDLIB_TEST_MUTATION_5167"]
      (begin
        (env-api-assert-true (env.unset! (& name)) "env initial unset")
        (env-api-assert-true
          (not (env.var-exists? name))
          "env initially missing")
        (env-api-assert-true
          (not (env.set! "" "value"))
          "env rejects empty name")
        (env-api-assert-true
          (not (env.set! "TYPELISP=INVALID" "value"))
          "env rejects equals in name")
        (env-api-assert-true
          (not (env.unset! "TYPELISP=INVALID"))
          "env unset rejects equals in name")
        (let
          [with-nul : String (env-api-string-with-nul)]
          (begin
            (env-api-assert-true
              (not (env.set! (& with-nul) "value"))
              "env rejects nul in name")
            (env-api-assert-true
              (not (env.set! (& name) (& with-nul)))
              "env rejects nul in value")))
        (env-api-assert-true (env.set! (& name) "first") "env set value")
        (env-api-assert-true (env.var-exists? name) "env set exists")
        (env-api-assert-string-eq
          (env.var-value name)
          "first"
          "env set round trip")
        (env-api-assert-some (env.get (& name)) "first" "env set get")
        (env-api-assert-true (env.set! (& name) "") "env set empty")
        (env-api-assert-true (env.var-exists? name) "env empty exists")
        (env-api-assert-string-eq
          (env.var-value name)
          ""
          "env empty round trip")
        (env-api-assert-true (env.unset! (& name)) "env unset")
        (env-api-assert-true (not (env.var-exists? name)) "env unset missing")
        (env-api-assert-none (env.get (& name)) "env unset get")
        (env-api-assert-true (env.unset! (& name)) "env repeated unset")))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-none (env.get (& name)) "env missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (match (env.get (& name))
        [(env.EnvSomeString actual)
          (begin
            (env-api-assert-string-eq actual "" "env empty")
            (env-api-assert-path-empty
              (env.path-list (& name))
              "env path empty")
            (env-api-assert-path-vec-empty
              (env.path-list-vec (& name))
              "env path vec empty"))]
        [(env.EnvNoString) unit]))
    (let
      [name : String "TYPELISP_STDLIB_TEST_VALUE"]
      (env-api-assert-some (env.get (& name)) "env-value-854" "env value"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-path-none (env.path-list (& name)) "env path missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-path-vec-none
        (env.path-list-vec (& name))
        "env path vec missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-api-assert-path3
        (env.path-list (& name))
        "one"
        "two"
        "three"
        "env path list"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-api-assert-path-vec3
        (env.path-list-vec (& name))
        "one"
        "two"
        "three"
        "env path vec"))
    (let
      [value : String (env.var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-api-assert-string-eq
        (env.path-join (env.path-split (& value)))
        value
        "env path join"))
    (let
      [value : String (env.var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-api-assert-string-eq
        (env.path-join-vec (env.path-split-vec (& value)))
        value
        "env path vec join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-list5
        (env.path-split-with-separator (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-vec5
        (env.path-split-with-separator-vec (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split vec"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-string-eq
        (env.path-join-with-separator
          (env.path-split-with-separator (& value) (& separator))
          (& separator))
        value
        "env semicolon join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-string-eq
        (env.path-join-vec-with-separator
          (env.path-split-with-separator-vec (& value) (& separator))
          (& separator))
        value
        "env semicolon join vec"))
    unit))