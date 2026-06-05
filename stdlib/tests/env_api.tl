(import "stdlib/env.tl")

(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-env-none [value : EnvMaybeString] [message : String]) : unit
  (match value
    [(EnvNoString) unit]
    [(EnvSomeString _) (panic message)]))

(define (assert-env-some
  [value : EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(EnvSomeString actual) (assert-owned-string-eq actual expected message)]
    [(EnvNoString) (panic message)]))

(define (assert-env-path-none [value : EnvMaybeStringList] [message : String]) : unit
  (match value
    [(EnvNoStringList) unit]
    [(EnvSomeStringList _) (panic message)]))

(define (assert-env-path-empty [value : EnvMaybeStringList] [message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (match items
        [(EnvStringNil) unit]
        [_ (panic message)])]
    [(EnvNoStringList) (panic message)]))

(define (assert-env-list3
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(EnvStringCons a rest)
      (match (box-get rest)
        [(EnvStringCons b tail)
          (match (box-get tail)
            [(EnvStringCons c end)
              (match (box-get end)
                [(EnvStringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-env-list5
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (match items
    [(EnvStringCons a rest)
      (match (box-get rest)
        [(EnvStringCons b rest2)
          (match (box-get rest2)
            [(EnvStringCons c rest3)
              (match (box-get rest3)
                [(EnvStringCons d rest4)
                  (match (box-get rest4)
                    [(EnvStringCons e end)
                      (match (box-get end)
                        [(EnvStringNil)
                          (begin
                            (assert-owned-string-eq a first message)
                            (assert-owned-string-eq b second message)
                            (assert-owned-string-eq c third message)
                            (assert-owned-string-eq d fourth message)
                            (assert-owned-string-eq e fifth message))]
                        [_ (panic message)])]
                    [_ (panic message)])]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-env-path3
  [value : EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (assert-env-list3 items first second third message)]
    [(EnvNoStringList) (panic message)]))

(define (main) : i64
  (begin
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (assert-env-none (env-get (& name)) "env missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (assert-env-some (env-get (& name)) "" "env empty"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_VALUE"]
      (assert-env-some (env-get (& name)) "env-value-854" "env value"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (assert-env-path-none (env-path-list (& name)) "env path missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (assert-env-path-empty (env-path-list (& name)) "env path empty"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (assert-env-path3
        (env-path-list (& name))
        "one"
        "two"
        "three"
        "env path list"))
    (let
      [value : String (env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (assert-owned-string-eq
        (env-path-join (env-path-split (& value)))
        value
        "env path join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (assert-env-list5
        (env-path-split-with-separator (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (assert-owned-string-eq
        (env-path-join-with-separator
          (env-path-split-with-separator (& value) (& separator))
          (& separator))
        value
        "env semicolon join"))
    42))