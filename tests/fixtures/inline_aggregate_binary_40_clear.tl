;; Keep the same import graph as the arena-gated twin.
;; lint-allow: unused-import
(import stdlib.arena)

(defstruct E0
  (n i64))

(defstruct E1
  (a E0)
  (b E0))

(defstruct E2
  (a E1)
  (b E1))

(defstruct E3
  (a E2)
  (b E2))

(defstruct E4
  (a E3)
  (b E3))

(defstruct E5
  (a E4)
  (b E4))

(defstruct E6
  (a E5)
  (b E5))

(defstruct E7
  (a E6)
  (b E6))

(defstruct E8
  (a E7)
  (b E7))

(defstruct E9
  (a E8)
  (b E8))

(defstruct E10
  (a E9)
  (b E9))

(defstruct E11
  (a E10)
  (b E10))

(defstruct E12
  (a E11)
  (b E11))

(defstruct E13
  (a E12)
  (b E12))

(defstruct E14
  (a E13)
  (b E13))

(defstruct E15
  (a E14)
  (b E14))

(defstruct E16
  (a E15)
  (b E15))

(defstruct E17
  (a E16)
  (b E16))

(defstruct E18
  (a E17)
  (b E17))

(defstruct E19
  (a E18)
  (b E18))

(defstruct E20
  (a E19)
  (b E19))

(defstruct E21
  (a E20)
  (b E20))

(defstruct E22
  (a E21)
  (b E21))

(defstruct E23
  (a E22)
  (b E22))

(defstruct E24
  (a E23)
  (b E23))

(defstruct E25
  (a E24)
  (b E24))

(defstruct E26
  (a E25)
  (b E25))

(defstruct E27
  (a E26)
  (b E26))

(defstruct E28
  (a E27)
  (b E27))

(defstruct E29
  (a E28)
  (b E28))

(defstruct E30
  (a E29)
  (b E29))

(defstruct E31
  (a E30)
  (b E30))

(defstruct E32
  (a E31)
  (b E31))

(defstruct E33
  (a E32)
  (b E32))

(defstruct E34
  (a E33)
  (b E33))

(defstruct E35
  (a E34)
  (b E34))

(defstruct E36
  (a E35)
  (b E35))

(defstruct E37
  (a E36)
  (b E36))

(defstruct E38
  (a E37)
  (b E37))

(defstruct E39
  (a E38)
  (b E38))

(defstruct E40
  (a E39)
  (b E39))

(define (exercise [_value : E40]) : i64
  (let
    [_owner 0]
    0))

(define (main) : i64
  0)