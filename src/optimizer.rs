use crate::ir::*;
use crate::types::Type;
use std::collections::{HashMap, HashSet};

/// Optimization passes for the IR
pub struct Optimizer;

#[derive(Debug, Clone, PartialEq)]
struct KnownConst {
    value: Value,
    ty: Type,
}

impl Optimizer {
    pub fn optimize(program: &mut Program) {
        for func in &mut program.functions {
            Self::optimize_function(func);
        }
    }

    fn optimize_function(func: &mut Function) {
        let mut changed = true;
        let mut iterations = 0;
        const MAX_ITERATIONS: usize = 10;

        while changed && iterations < MAX_ITERATIONS {
            changed = false;
            changed |= Self::constant_folding(func);
            changed |= Self::common_subexpression_elimination(func);
            changed |= Self::dead_code_elimination(func);
            changed |= Self::strength_reduction(func);
            changed |= Self::copy_propagation(func);
            iterations += 1;
        }
    }

    /// Constant folding: evaluate constant expressions at compile time
    fn constant_folding(func: &mut Function) -> bool {
        let mut changed = false;

        for block in &mut func.blocks {
            let mut constants: HashMap<VarId, KnownConst> = HashMap::new();
            for instr in &mut block.instructions {
                match instr {
                    Instruction::BinOp {
                        dst,
                        op,
                        lhs,
                        rhs,
                        ty,
                    } => {
                        let lhs_val = Self::resolve_value(lhs, &constants);
                        let rhs_val = Self::resolve_value(rhs, &constants);

                        if let (Some(l), Some(r)) = (lhs_val, rhs_val)
                            && let Some(result) = Self::eval_binop(*op, &l, &r, ty)
                        {
                            let dst_id = *dst;
                            let result_ty = ty.clone();
                            let result_clone = result.clone();
                            *instr = Instruction::Mov {
                                dst: dst_id,
                                src: result,
                                ty: result_ty.clone(),
                            };
                            constants.insert(
                                dst_id,
                                KnownConst {
                                    value: result_clone,
                                    ty: result_ty,
                                },
                            );
                            changed = true;
                            continue;
                        }

                        if let Value::Var(v) = lhs
                            && let Some(c) = constants.get(v)
                            && Self::can_inline_known_const(c)
                        {
                            *lhs = c.value.clone();
                            changed = true;
                        }
                        if let Value::Var(v) = rhs
                            && let Some(c) = constants.get(v)
                            && Self::can_inline_known_const(c)
                        {
                            *rhs = c.value.clone();
                            changed = true;
                        }
                        constants.remove(dst);
                    }
                    Instruction::UnOp { dst, op, src, ty } => {
                        let src_val = Self::resolve_value(src, &constants);
                        if let Some(s) = src_val
                            && let Some(result) = Self::eval_unop(*op, &s, ty)
                        {
                            let dst_id = *dst;
                            let result_ty = ty.clone();
                            let result_clone = result.clone();
                            *instr = Instruction::Mov {
                                dst: dst_id,
                                src: result,
                                ty: result_ty.clone(),
                            };
                            constants.insert(
                                dst_id,
                                KnownConst {
                                    value: result_clone,
                                    ty: result_ty,
                                },
                            );
                            changed = true;
                            continue;
                        }

                        if let Value::Var(v) = src
                            && let Some(c) = constants.get(v)
                            && Self::can_inline_known_const(c)
                        {
                            *src = c.value.clone();
                            changed = true;
                        }
                        constants.remove(dst);
                    }
                    Instruction::Cast {
                        dst,
                        src,
                        from_ty,
                        to_ty,
                    } => {
                        let src_val = Self::resolve_value(src, &constants);
                        if let Some(s) = src_val
                            && let Some(result) = Self::eval_cast(&s, from_ty, to_ty)
                        {
                            let dst_id = *dst;
                            let result_ty = to_ty.clone();
                            let result_clone = result.clone();
                            *instr = Instruction::Mov {
                                dst: dst_id,
                                src: result,
                                ty: result_ty.clone(),
                            };
                            constants.insert(
                                dst_id,
                                KnownConst {
                                    value: result_clone,
                                    ty: result_ty,
                                },
                            );
                            changed = true;
                            continue;
                        }

                        if let Value::Var(v) = src
                            && let Some(c) = constants.get(v)
                            && Self::can_inline_known_const(c)
                        {
                            *src = c.value.clone();
                            changed = true;
                        }
                        constants.remove(dst);
                    }
                    Instruction::Mov { dst, src, ty } => {
                        let known_src = match src {
                            Value::Var(v) => constants.get(v).cloned(),
                            _ => None,
                        };
                        if let Some(c) = known_src {
                            if Self::can_inline_known_const(&c) {
                                *src = c.value.clone();
                                changed = true;
                            }
                            constants.insert(
                                *dst,
                                KnownConst {
                                    value: c.value,
                                    ty: ty.clone(),
                                },
                            );
                        } else if Self::is_foldable_immediate(src) {
                            constants.insert(
                                *dst,
                                KnownConst {
                                    value: src.clone(),
                                    ty: ty.clone(),
                                },
                            );
                        } else {
                            constants.remove(dst);
                        }
                    }
                    _ => {
                        if let Some(dst) = Self::instruction_defined_var(instr) {
                            constants.remove(&dst);
                        }
                    }
                }
            }
        }

        changed
    }

    fn resolve_value(val: &Value, constants: &HashMap<VarId, KnownConst>) -> Option<KnownConst> {
        match val {
            Value::Var(v) => constants.get(v).cloned(),
            _ => val.ty().map(|ty| KnownConst {
                value: val.clone(),
                ty,
            }),
        }
    }

    fn can_inline_known_const(value: &KnownConst) -> bool {
        match &value.value {
            Value::Function(_) | Value::FunctionEntry(_) => true,
            _ => value.value.ty().is_some_and(|ty| ty == value.ty),
        }
    }

    fn is_foldable_immediate(value: &Value) -> bool {
        matches!(
            value,
            Value::ConstI64(_)
                | Value::ConstI32(_)
                | Value::ConstI8(_)
                | Value::ConstF64(_)
                | Value::ConstBool(_)
                | Value::ConstUnit
                | Value::ConstStr(_)
                | Value::Function(_)
                | Value::FunctionEntry(_)
        )
    }

    fn eval_binop(
        op: BinOp,
        lhs: &KnownConst,
        rhs: &KnownConst,
        result_ty: &Type,
    ) -> Option<Value> {
        match op {
            BinOp::And => Self::eval_bool_binop(lhs, rhs, |a, b| a && b),
            BinOp::Or => Self::eval_bool_binop(lhs, rhs, |a, b| a || b),
            _ if Self::is_float_binop(op, lhs, rhs) => {
                Self::eval_f64_binop(op, &lhs.value, &rhs.value)
            }
            _ => {
                let operand_ty = Self::binop_operand_ty(op, lhs, rhs, result_ty);
                Self::eval_integer_binop(op, lhs, rhs, &operand_ty)
            }
        }
    }

    fn eval_unop(op: UnOp, src: &KnownConst, result_ty: &Type) -> Option<Value> {
        match op {
            UnOp::Neg if *result_ty == Type::F64 => {
                let Value::ConstF64(value) = src.value else {
                    return None;
                };
                Some(Value::ConstF64(-value))
            }
            UnOp::Not if *result_ty == Type::Bool => {
                let Value::ConstBool(value) = src.value else {
                    return None;
                };
                Some(Value::ConstBool(!value))
            }
            UnOp::BitNot => {
                let bits = Self::integer_bits(&src.value, result_ty)?;
                let width = Self::integer_width(result_ty)?;
                Some(Self::value_from_bits(!bits & Self::mask(width), result_ty)?)
            }
            UnOp::Neg if result_ty.is_signed() => {
                let width = result_ty.bit_width();
                let value = Self::signed_integer_value(&src.value, result_ty)?;
                let result = value.checked_neg()?;
                Self::fits_signed(result, width).then(|| {
                    Self::value_from_bits(Self::bits_from_signed(result, width), result_ty)
                })?
            }
            _ => None,
        }
    }

    fn eval_cast(src: &KnownConst, from_ty: &Type, to_ty: &Type) -> Option<Value> {
        if !Self::castable_integer_ty(from_ty) || !Self::castable_integer_ty(to_ty) {
            return None;
        }

        let from_bits = Self::integer_bits(&src.value, from_ty)?;
        let extended = if from_ty.is_signed() {
            Self::signed_from_bits(from_bits, Self::integer_width(from_ty)?) as u128
        } else {
            from_bits
        };
        let to_bits = extended & Self::mask(Self::integer_width(to_ty)?);
        Self::value_from_bits(to_bits, to_ty)
    }

    fn eval_bool_binop(
        lhs: &KnownConst,
        rhs: &KnownConst,
        op: impl FnOnce(bool, bool) -> bool,
    ) -> Option<Value> {
        let (Value::ConstBool(a), Value::ConstBool(b)) = (&lhs.value, &rhs.value) else {
            return None;
        };
        Some(Value::ConstBool(op(*a, *b)))
    }

    fn is_float_binop(op: BinOp, lhs: &KnownConst, rhs: &KnownConst) -> bool {
        matches!(
            op,
            BinOp::Add
                | BinOp::Sub
                | BinOp::Mul
                | BinOp::Div
                | BinOp::Eq
                | BinOp::Ne
                | BinOp::Lt
                | BinOp::Le
                | BinOp::Gt
                | BinOp::Ge
        ) && lhs.ty == Type::F64
            && rhs.ty == Type::F64
    }

    fn eval_f64_binop(op: BinOp, lhs: &Value, rhs: &Value) -> Option<Value> {
        let (Value::ConstF64(a), Value::ConstF64(b)) = (lhs, rhs) else {
            return None;
        };
        match op {
            BinOp::Add => Some(Value::ConstF64(a + b)),
            BinOp::Sub => Some(Value::ConstF64(a - b)),
            BinOp::Mul => Some(Value::ConstF64(a * b)),
            BinOp::Div => Some(Value::ConstF64(a / b)),
            BinOp::Eq => Some(Value::ConstBool(a == b)),
            BinOp::Ne => Some(Value::ConstBool(a != b)),
            BinOp::Lt => Some(Value::ConstBool(a < b)),
            BinOp::Le => Some(Value::ConstBool(a <= b)),
            BinOp::Gt => Some(Value::ConstBool(a > b)),
            BinOp::Ge => Some(Value::ConstBool(a >= b)),
            _ => None,
        }
    }

    fn binop_operand_ty(op: BinOp, lhs: &KnownConst, rhs: &KnownConst, result_ty: &Type) -> Type {
        match op {
            BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => {
                if lhs.ty != Type::I64 {
                    lhs.ty.clone()
                } else {
                    rhs.ty.clone()
                }
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => {
                lhs.ty.clone()
            }
            _ => result_ty.clone(),
        }
    }

    fn eval_integer_binop(
        op: BinOp,
        lhs: &KnownConst,
        rhs: &KnownConst,
        ty: &Type,
    ) -> Option<Value> {
        match op {
            BinOp::Add | BinOp::Sub | BinOp::Mul => Self::eval_checked_arithmetic(op, lhs, rhs, ty),
            BinOp::Div | BinOp::Mod => Self::eval_checked_divmod(op, lhs, rhs, ty),
            BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => {
                Self::eval_integer_compare(op, lhs, rhs, ty)
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor => {
                let a = Self::integer_bits(&lhs.value, ty)?;
                let b = Self::integer_bits(&rhs.value, ty)?;
                let result = match op {
                    BinOp::BitAnd => a & b,
                    BinOp::BitOr => a | b,
                    BinOp::BitXor => a ^ b,
                    _ => unreachable!(),
                };
                let width = Self::integer_width(ty)?;
                Self::value_from_bits(result & Self::mask(width), ty)
            }
            BinOp::Shl | BinOp::Shr => Self::eval_shift(op, lhs, rhs, ty),
            BinOp::And | BinOp::Or => None,
        }
    }

    fn eval_checked_arithmetic(
        op: BinOp,
        lhs: &KnownConst,
        rhs: &KnownConst,
        ty: &Type,
    ) -> Option<Value> {
        if !ty.is_integer() {
            return None;
        }
        let width = ty.bit_width();
        if ty.is_signed() {
            let a = Self::signed_integer_value(&lhs.value, ty)?;
            let b = Self::signed_integer_value(&rhs.value, ty)?;
            let result = match op {
                BinOp::Add => a.checked_add(b)?,
                BinOp::Sub => a.checked_sub(b)?,
                BinOp::Mul => a.checked_mul(b)?,
                _ => unreachable!(),
            };
            return Self::fits_signed(result, width)
                .then(|| Self::value_from_bits(Self::bits_from_signed(result, width), ty))?;
        }

        let a = Self::integer_bits(&lhs.value, ty)?;
        let b = Self::integer_bits(&rhs.value, ty)?;
        let result = match op {
            BinOp::Add => a.checked_add(b)?,
            BinOp::Sub => a.checked_sub(b)?,
            BinOp::Mul => a.checked_mul(b)?,
            _ => unreachable!(),
        };
        (result <= Self::mask(width)).then(|| Self::value_from_bits(result, ty))?
    }

    fn eval_checked_divmod(
        op: BinOp,
        lhs: &KnownConst,
        rhs: &KnownConst,
        ty: &Type,
    ) -> Option<Value> {
        if !ty.is_integer() {
            return None;
        }
        let width = ty.bit_width();
        if ty.is_signed() {
            let a = Self::signed_integer_value(&lhs.value, ty)?;
            let b = Self::signed_integer_value(&rhs.value, ty)?;
            if b == 0 || (a == Self::signed_min(width) && b == -1) {
                return None;
            }
            let result = match op {
                BinOp::Div => a / b,
                BinOp::Mod => a % b,
                _ => unreachable!(),
            };
            return Self::value_from_bits(Self::bits_from_signed(result, width), ty);
        }

        let a = Self::integer_bits(&lhs.value, ty)?;
        let b = Self::integer_bits(&rhs.value, ty)?;
        if b == 0 {
            return None;
        }
        let result = match op {
            BinOp::Div => a / b,
            BinOp::Mod => a % b,
            _ => unreachable!(),
        };
        Self::value_from_bits(result, ty)
    }

    fn eval_integer_compare(
        op: BinOp,
        lhs: &KnownConst,
        rhs: &KnownConst,
        ty: &Type,
    ) -> Option<Value> {
        if !ty.is_integer() && !matches!(ty, Type::Char) {
            return None;
        }

        let result = if ty.is_signed() {
            let a = Self::signed_integer_value(&lhs.value, ty)?;
            let b = Self::signed_integer_value(&rhs.value, ty)?;
            match op {
                BinOp::Eq => a == b,
                BinOp::Ne => a != b,
                BinOp::Lt => a < b,
                BinOp::Le => a <= b,
                BinOp::Gt => a > b,
                BinOp::Ge => a >= b,
                _ => unreachable!(),
            }
        } else {
            let a = Self::integer_bits(&lhs.value, ty)?;
            let b = Self::integer_bits(&rhs.value, ty)?;
            match op {
                BinOp::Eq => a == b,
                BinOp::Ne => a != b,
                BinOp::Lt => a < b,
                BinOp::Le => a <= b,
                BinOp::Gt => a > b,
                BinOp::Ge => a >= b,
                _ => unreachable!(),
            }
        };

        Some(Value::ConstBool(result))
    }

    fn eval_shift(op: BinOp, lhs: &KnownConst, rhs: &KnownConst, ty: &Type) -> Option<Value> {
        if !ty.is_integer() {
            return None;
        }
        let width = ty.bit_width();
        let count = Self::shift_count(rhs)?;
        if count >= width {
            return None;
        }

        let bits = Self::integer_bits(&lhs.value, ty)?;
        let result = match op {
            BinOp::Shl => (bits << count) & Self::mask(width),
            BinOp::Shr if ty.is_signed() => {
                let shifted = Self::signed_from_bits(bits, width) >> count;
                Self::bits_from_signed(shifted, width)
            }
            BinOp::Shr => bits >> count,
            _ => unreachable!(),
        };
        Self::value_from_bits(result, ty)
    }

    fn shift_count(value: &KnownConst) -> Option<u8> {
        if !value.ty.is_integer() {
            return None;
        }
        if value.ty.is_signed() {
            let count = Self::signed_integer_value(&value.value, &value.ty)?;
            return u8::try_from(count).ok();
        }
        u8::try_from(Self::integer_bits(&value.value, &value.ty)?).ok()
    }

    fn castable_integer_ty(ty: &Type) -> bool {
        ty.is_integer() || matches!(ty, Type::Char)
    }

    fn integer_bits(value: &Value, ty: &Type) -> Option<u128> {
        let width = Self::integer_width(ty)?;
        let bits = match value {
            Value::ConstI64(value) => *value as u128,
            Value::ConstI32(value) => *value as u128,
            Value::ConstI8(value) => *value as u128,
            _ => return None,
        };
        Some(bits & Self::mask(width))
    }

    fn integer_width(ty: &Type) -> Option<u8> {
        if ty.is_integer() {
            Some(ty.bit_width())
        } else if matches!(ty, Type::Char) {
            Some(8)
        } else {
            None
        }
    }

    fn signed_integer_value(value: &Value, ty: &Type) -> Option<i128> {
        Some(Self::signed_from_bits(
            Self::integer_bits(value, ty)?,
            ty.bit_width(),
        ))
    }

    fn signed_from_bits(bits: u128, width: u8) -> i128 {
        let sign_bit = 1u128 << (width - 1);
        let bits = bits & Self::mask(width);
        if bits & sign_bit == 0 {
            bits as i128
        } else {
            bits as i128 - (1i128 << width)
        }
    }

    fn bits_from_signed(value: i128, width: u8) -> u128 {
        (value as u128) & Self::mask(width)
    }

    fn signed_min(width: u8) -> i128 {
        -(1i128 << (width - 1))
    }

    fn signed_max(width: u8) -> i128 {
        (1i128 << (width - 1)) - 1
    }

    fn fits_signed(value: i128, width: u8) -> bool {
        (Self::signed_min(width)..=Self::signed_max(width)).contains(&value)
    }

    fn mask(width: u8) -> u128 {
        debug_assert!(width <= 64);
        (1u128 << width) - 1
    }

    fn value_from_bits(bits: u128, ty: &Type) -> Option<Value> {
        let bits = bits & Self::mask(Self::integer_width(ty)?);
        match ty {
            Type::I64 | Type::U64 | Type::I16 | Type::U16 => {
                Some(Value::ConstI64(bits as u64 as i64))
            }
            Type::I32 | Type::U32 => Some(Value::ConstI32(bits as u32 as i32)),
            Type::I8 | Type::U8 | Type::Char => Some(Value::ConstI8(bits as u8 as i8)),
            _ => None,
        }
    }

    /// Dead code elimination: remove unused assignments
    fn dead_code_elimination(func: &mut Function) -> bool {
        let mut changed = false;

        // Collect all used variables
        let mut used: HashSet<VarId> = HashSet::new();
        for block in &func.blocks {
            for instr in &block.instructions {
                Self::collect_uses(instr, &mut used);
            }
        }

        // Remove unused pure computations
        for block in &mut func.blocks {
            block.instructions.retain(|instr| {
                let should_keep = match instr {
                    Instruction::BinOp { dst, .. }
                    | Instruction::UnOp { dst, .. }
                    | Instruction::Mov { dst, .. } => {
                        used.contains(dst) || Self::has_side_effects(instr)
                    }
                    _ => true,
                };
                if !should_keep {
                    changed = true;
                }
                should_keep
            });
        }

        changed
    }

    fn collect_uses(instr: &Instruction, used: &mut HashSet<VarId>) {
        match instr {
            Instruction::BinOp { lhs, rhs, .. } => {
                Self::add_value_uses(lhs, used);
                Self::add_value_uses(rhs, used);
            }
            Instruction::UnOp { src, .. } => Self::add_value_uses(src, used),
            Instruction::Mov { src, .. } => Self::add_value_uses(src, used),
            Instruction::Cast { src, .. } => Self::add_value_uses(src, used),
            Instruction::Load { src, .. } => Self::add_value_uses(src, used),
            Instruction::Store { dst, src, .. } => {
                Self::add_value_uses(dst, used);
                Self::add_value_uses(src, used);
            }
            Instruction::Call { args, .. } | Instruction::TailCall { args, .. } => {
                for arg in args {
                    Self::add_value_uses(arg, used);
                }
            }
            Instruction::CallIndirect { func, args, .. } => {
                Self::add_value_uses(func, used);
                for arg in args {
                    Self::add_value_uses(arg, used);
                }
            }
            Instruction::Branch { cond, .. } => Self::add_value_uses(cond, used),
            Instruction::Return(Some(v)) => Self::add_value_uses(v, used),
            Instruction::Gep { base, offset, .. } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(offset, used);
            }
            Instruction::Splat { value, .. } => Self::add_value_uses(value, used),
            Instruction::VectorBinOp { lhs, rhs, .. }
            | Instruction::VectorCompare { lhs, rhs, .. }
            | Instruction::MaskBinOp { lhs, rhs, .. } => {
                Self::add_value_uses(lhs, used);
                Self::add_value_uses(rhs, used);
            }
            Instruction::VectorReduce { src, .. } | Instruction::MaskReduce { src, .. } => {
                Self::add_value_uses(src, used)
            }
            Instruction::MaskNot { src, .. } => Self::add_value_uses(src, used),
            Instruction::Select {
                mask,
                on_true,
                on_false,
                ..
            } => {
                Self::add_value_uses(mask, used);
                Self::add_value_uses(on_true, used);
                Self::add_value_uses(on_false, used);
            }
            Instruction::VectorLoad { base, index, .. } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(index, used);
            }
            Instruction::VectorStore {
                base, index, value, ..
            } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(index, used);
                Self::add_value_uses(value, used);
            }
            Instruction::PredicatedStore {
                base,
                index,
                value,
                mask,
                ..
            } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(index, used);
                Self::add_value_uses(value, used);
                Self::add_value_uses(mask, used);
            }
            Instruction::PredicatedLoad {
                base, index, mask, ..
            } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(index, used);
                Self::add_value_uses(mask, used);
            }
            Instruction::TailMask { index, len, .. } => {
                Self::add_value_uses(index, used);
                Self::add_value_uses(len, used);
            }
            Instruction::Phi { incoming, .. } => {
                for (val, _) in incoming {
                    Self::add_value_uses(val, used);
                }
            }
            _ => {}
        }
    }

    fn add_value_uses(val: &Value, used: &mut HashSet<VarId>) {
        if let Value::Var(v) = val {
            used.insert(*v);
        }
    }

    fn has_side_effects(instr: &Instruction) -> bool {
        instr.effect().has_side_effect()
    }

    /// Basic-block local common subexpression elimination for pure operations.
    fn common_subexpression_elimination(func: &mut Function) -> bool {
        let mut changed = false;

        for block in &mut func.blocks {
            let mut available: HashMap<CseExpr, VarId> = HashMap::new();

            for instr in &mut block.instructions {
                let Some(expr) = CseExpr::from_instruction(instr) else {
                    if Self::cse_invalidates_available_expressions(instr) {
                        available.clear();
                    }
                    continue;
                };

                let (dst, ty) = match instr {
                    Instruction::BinOp { dst, ty, .. } | Instruction::UnOp { dst, ty, .. } => {
                        (*dst, ty.clone())
                    }
                    _ => unreachable!("CSE expressions are built only from pure value ops"),
                };

                if let Some(existing) = available.get(&expr).copied() {
                    *instr = Instruction::Mov {
                        dst,
                        src: Value::Var(existing),
                        ty,
                    };
                    changed = true;
                } else {
                    available.insert(expr, dst);
                }
            }
        }

        changed
    }

    fn cse_invalidates_available_expressions(instr: &Instruction) -> bool {
        instr.effect().invalidates_cse()
    }

    /// Strength reduction: replace expensive ops with cheaper ones
    fn strength_reduction(func: &mut Function) -> bool {
        let mut changed = false;

        for block in &mut func.blocks {
            let mut replacements: Vec<(usize, Instruction)> = Vec::new();
            for (idx, instr) in block.instructions.iter().enumerate() {
                if let Instruction::BinOp {
                    op,
                    rhs,
                    dst,
                    lhs,
                    ty,
                } = instr
                {
                    if let Value::ConstI64(n) = rhs {
                        // x * 1 -> x
                        if *op == BinOp::Mul && *n == 1 {
                            replacements.push((
                                idx,
                                Instruction::Mov {
                                    dst: *dst,
                                    src: lhs.clone(),
                                    ty: ty.clone(),
                                },
                            ));
                            continue;
                        }
                        // x * 0 -> 0
                        if *op == BinOp::Mul && *n == 0 {
                            replacements.push((
                                idx,
                                Instruction::Mov {
                                    dst: *dst,
                                    src: Value::ConstI64(0),
                                    ty: ty.clone(),
                                },
                            ));
                            continue;
                        }
                        // x + 0 -> x
                        if *op == BinOp::Add && *n == 0 {
                            replacements.push((
                                idx,
                                Instruction::Mov {
                                    dst: *dst,
                                    src: lhs.clone(),
                                    ty: ty.clone(),
                                },
                            ));
                            continue;
                        }
                    }
                    // Similarly for lhs being 0 in addition
                    if let Value::ConstI64(n) = lhs
                        && *op == BinOp::Add
                        && *n == 0
                    {
                        replacements.push((
                            idx,
                            Instruction::Mov {
                                dst: *dst,
                                src: rhs.clone(),
                                ty: ty.clone(),
                            },
                        ));
                    }
                }
            }
            for (idx, new_instr) in replacements {
                block.instructions[idx] = new_instr;
                changed = true;
            }
        }

        changed
    }

    /// Copy propagation: replace uses of a copy with the original value
    fn copy_propagation(func: &mut Function) -> bool {
        let mut changed = false;

        for block in &mut func.blocks {
            let mut copies: HashMap<VarId, Value> = HashMap::new();
            for instr in &mut block.instructions {
                // First, try to substitute any Var uses with known copies
                let subs = Self::substitute_copies(instr, &copies);
                if subs {
                    changed = true;
                }

                // Then, record new copies
                if let Instruction::Mov { dst, src, ty } = instr
                    && Self::can_copy_propagate(src, ty)
                {
                    copies.insert(*dst, src.clone());
                } else if let Some(dst) = Self::instruction_defined_var(instr) {
                    copies.remove(&dst);
                }
            }
        }

        changed
    }

    fn can_copy_propagate(src: &Value, ty: &Type) -> bool {
        if matches!(ty, Type::Vector(_, _) | Type::Mask(_)) {
            return false;
        }

        match src {
            Value::Var(_) | Value::Function(_) | Value::FunctionEntry(_) => true,
            Value::ConstI64(_)
            | Value::ConstI32(_)
            | Value::ConstI8(_)
            | Value::ConstF64(_)
            | Value::ConstBool(_)
            | Value::ConstUnit
            | Value::ConstStr(_) => src.ty().is_some_and(|src_ty| src_ty == *ty),
            Value::Global(_) => false,
        }
    }

    fn substitute_copies(instr: &mut Instruction, copies: &HashMap<VarId, Value>) -> bool {
        let mut changed = false;
        let mut substitute = |val: &mut Value| {
            if let Value::Var(v) = val
                && let Some(replacement) = copies.get(v)
            {
                *val = replacement.clone();
                changed = true;
            }
        };

        match instr {
            Instruction::BinOp { lhs, rhs, .. } => {
                substitute(lhs);
                substitute(rhs);
            }
            Instruction::UnOp { src, .. } => substitute(src),
            Instruction::Mov { src, .. } => substitute(src),
            Instruction::Cast { src, .. } => substitute(src),
            Instruction::Load { src, .. } => substitute(src),
            Instruction::Store { dst, src, .. } => {
                substitute(dst);
                substitute(src);
            }
            Instruction::Call { args, .. } | Instruction::TailCall { args, .. } => {
                for arg in args {
                    substitute(arg);
                }
            }
            Instruction::CallIndirect { func, args, .. } => {
                substitute(func);
                for arg in args {
                    substitute(arg);
                }
            }
            Instruction::Branch { cond, .. } => substitute(cond),
            Instruction::Return(Some(v)) => substitute(v),
            Instruction::Gep { base, offset, .. } => {
                substitute(base);
                substitute(offset);
            }
            Instruction::Splat { value, .. } => substitute(value),
            Instruction::VectorBinOp { lhs, rhs, .. }
            | Instruction::VectorCompare { lhs, rhs, .. }
            | Instruction::MaskBinOp { lhs, rhs, .. } => {
                substitute(lhs);
                substitute(rhs);
            }
            Instruction::VectorReduce { src, .. } | Instruction::MaskReduce { src, .. } => {
                substitute(src)
            }
            Instruction::MaskNot { src, .. } => substitute(src),
            Instruction::Select {
                mask,
                on_true,
                on_false,
                ..
            } => {
                substitute(mask);
                substitute(on_true);
                substitute(on_false);
            }
            Instruction::VectorLoad { base, index, .. } => {
                substitute(base);
                substitute(index);
            }
            Instruction::VectorStore {
                base, index, value, ..
            } => {
                substitute(base);
                substitute(index);
                substitute(value);
            }
            Instruction::PredicatedStore {
                base,
                index,
                value,
                mask,
                ..
            } => {
                substitute(base);
                substitute(index);
                substitute(value);
                substitute(mask);
            }
            Instruction::PredicatedLoad {
                base, index, mask, ..
            } => {
                substitute(base);
                substitute(index);
                substitute(mask);
            }
            Instruction::TailMask { index, len, .. } => {
                substitute(index);
                substitute(len);
            }
            Instruction::Phi { .. } => {}
            _ => {}
        }
        changed
    }

    fn instruction_defined_var(instr: &Instruction) -> Option<VarId> {
        match instr {
            Instruction::BinOp { dst, .. }
            | Instruction::UnOp { dst, .. }
            | Instruction::Mov { dst, .. }
            | Instruction::Cast { dst, .. }
            | Instruction::Load { dst, .. }
            | Instruction::AddrOf { dst, .. }
            | Instruction::Gep { dst, .. }
            | Instruction::LaneId { dst, .. }
            | Instruction::Splat { dst, .. }
            | Instruction::VectorBinOp { dst, .. }
            | Instruction::VectorReduce { dst, .. }
            | Instruction::VectorCompare { dst, .. }
            | Instruction::MaskBinOp { dst, .. }
            | Instruction::MaskNot { dst, .. }
            | Instruction::MaskReduce { dst, .. }
            | Instruction::Select { dst, .. }
            | Instruction::VectorLoad { dst, .. }
            | Instruction::PredicatedLoad { dst, .. }
            | Instruction::TailMask { dst, .. }
            | Instruction::Phi { dst, .. } => Some(*dst),
            Instruction::Alloc { var, .. } => Some(*var),
            Instruction::Call { dst, .. } | Instruction::CallIndirect { dst, .. } => *dst,
            Instruction::Store { .. }
            | Instruction::VectorStore { .. }
            | Instruction::PredicatedStore { .. }
            | Instruction::Branch { .. }
            | Instruction::TailCall { .. }
            | Instruction::Jump(_)
            | Instruction::Return(_) => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum CseExpr {
    BinOp {
        op: BinOp,
        lhs: CseValue,
        rhs: CseValue,
        ty: Type,
    },
    UnOp {
        op: UnOp,
        src: CseValue,
        ty: Type,
    },
}

impl CseExpr {
    fn from_instruction(instr: &Instruction) -> Option<Self> {
        match instr {
            Instruction::BinOp {
                op, lhs, rhs, ty, ..
            } => Some(CseExpr::BinOp {
                op: *op,
                lhs: CseValue::from_value(lhs)?,
                rhs: CseValue::from_value(rhs)?,
                ty: ty.clone(),
            }),
            Instruction::UnOp { op, src, ty, .. } => Some(CseExpr::UnOp {
                op: *op,
                src: CseValue::from_value(src)?,
                ty: ty.clone(),
            }),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum CseValue {
    ConstI64(i64),
    ConstI32(i32),
    ConstI8(i8),
    ConstF64(u64),
    ConstBool(bool),
    ConstUnit,
    ConstStr(String),
    Function(String),
    FunctionEntry(String),
    Var(VarId),
}

impl CseValue {
    fn from_value(value: &Value) -> Option<Self> {
        match value {
            Value::ConstI64(value) => Some(CseValue::ConstI64(*value)),
            Value::ConstI32(value) => Some(CseValue::ConstI32(*value)),
            Value::ConstI8(value) => Some(CseValue::ConstI8(*value)),
            Value::ConstF64(value) => Some(CseValue::ConstF64(value.to_bits())),
            Value::ConstBool(value) => Some(CseValue::ConstBool(*value)),
            Value::ConstUnit => Some(CseValue::ConstUnit),
            Value::ConstStr(value) => Some(CseValue::ConstStr(value.clone())),
            Value::Function(value) => Some(CseValue::Function(value.clone())),
            Value::FunctionEntry(value) => Some(CseValue::FunctionEntry(value.clone())),
            Value::Var(value) => Some(CseValue::Var(*value)),
            Value::Global(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::ir::{
        BasicBlock, BinOp, Function, Instruction, MaskBinOp, MaskReduceOp, Program, UnOp, Value,
        VectorReduceOp,
    };
    use crate::lower::lower_program;
    use crate::parser::parse;
    use crate::types::Type;

    use super::{KnownConst, Optimizer};

    fn known(value: Value, ty: Type) -> KnownConst {
        KnownConst { value, ty }
    }

    fn optimize(source: &str) -> crate::ir::Program {
        let prog = parse(source).unwrap();
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        ir
    }

    #[test]
    fn test_constant_folding() {
        let source = r#"
(define (main) : i64
  (+ 1 2))
"#;
        let ir = optimize(source);
        let func = &ir.functions[0];
        let entry = &func.blocks[0];
        // After optimization, the (+ 1 2) should be folded to ConstI64(3)
        // The Return should contain the constant directly
        let last = entry.instructions.last().unwrap();
        match last {
            Instruction::Return(Some(Value::ConstI64(3))) => {}
            _ => panic!("Expected Return(ConstI64(3)), got {:?}", last),
        }
    }

    #[test]
    fn test_strength_reduction_mul_zero() {
        let source = r#"
(define (main) : i64
  (* 42 0))
"#;
        let ir = optimize(source);
        let func = &ir.functions[0];
        let entry = &func.blocks[0];
        let last = entry.instructions.last().unwrap();
        match last {
            Instruction::Return(Some(Value::ConstI64(0))) => {}
            _ => panic!("Expected Return(ConstI64(0)), got {:?}", last),
        }
    }

    #[test]
    fn test_constant_folding_skips_overflowing_integer_ops() {
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Mul,
                &known(Value::ConstI64(i64::MAX), Type::I64),
                &known(Value::ConstI64(2), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Add,
                &known(Value::ConstI64(i64::MAX), Type::I64),
                &known(Value::ConstI64(1), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Sub,
                &known(Value::ConstI64(i64::MIN), Type::I64),
                &known(Value::ConstI64(1), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Div,
                &known(Value::ConstI64(i64::MIN), Type::I64),
                &known(Value::ConstI64(-1), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Mod,
                &known(Value::ConstI64(i64::MIN), Type::I64),
                &known(Value::ConstI64(-1), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_unop(
                UnOp::Neg,
                &known(Value::ConstI64(i64::MIN), Type::I64),
                &Type::I64
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_unop(UnOp::Neg, &known(Value::ConstI8(-1), Type::U8), &Type::U8),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Add,
                &known(Value::ConstI8(127), Type::I8),
                &known(Value::ConstI8(1), Type::I8),
                &Type::I8
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Add,
                &known(Value::ConstI8(-1), Type::U8),
                &known(Value::ConstI8(1), Type::U8),
                &Type::U8
            ),
            None
        );
    }

    #[test]
    fn test_typed_integer_constant_folding_uses_width_and_signedness() {
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Add,
                &known(Value::ConstI64(40), Type::I16),
                &known(Value::ConstI64(2), Type::I16),
                &Type::I16
            ),
            Some(Value::ConstI64(42))
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Gt,
                &known(Value::ConstI8(-1), Type::U8),
                &known(Value::ConstI8(1), Type::U8),
                &Type::Bool
            ),
            Some(Value::ConstBool(true))
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Lt,
                &known(Value::ConstI8(-1), Type::I8),
                &known(Value::ConstI8(1), Type::I8),
                &Type::Bool
            ),
            Some(Value::ConstBool(true))
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::BitAnd,
                &known(Value::ConstI8(-1), Type::U8),
                &known(Value::ConstI8(0x0f), Type::U8),
                &Type::U8
            ),
            Some(Value::ConstI8(0x0f))
        );
    }

    #[test]
    fn test_typed_shift_folding_preserves_runtime_traps() {
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Shr,
                &known(Value::ConstI8(-128), Type::U8),
                &known(Value::ConstI8(7), Type::U8),
                &Type::U8
            ),
            Some(Value::ConstI8(1))
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Shr,
                &known(Value::ConstI8(-128), Type::I8),
                &known(Value::ConstI8(7), Type::I8),
                &Type::I8
            ),
            Some(Value::ConstI8(-1))
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Shl,
                &known(Value::ConstI8(1), Type::I8),
                &known(Value::ConstI8(-1), Type::I8),
                &Type::I8
            ),
            None
        );
        assert_eq!(
            Optimizer::eval_binop(
                BinOp::Shl,
                &known(Value::ConstI8(1), Type::U8),
                &known(Value::ConstI8(8), Type::U8),
                &Type::U8
            ),
            None
        );
    }

    #[test]
    fn test_constant_cast_folding_preserves_source_sign_and_target_width() {
        assert_eq!(
            Optimizer::eval_cast(&known(Value::ConstI8(-1), Type::I8), &Type::I8, &Type::I64),
            Some(Value::ConstI64(-1))
        );
        assert_eq!(
            Optimizer::eval_cast(&known(Value::ConstI8(-1), Type::U8), &Type::U8, &Type::I64),
            Some(Value::ConstI64(255))
        );
        assert_eq!(
            Optimizer::eval_cast(
                &known(Value::ConstI64(257), Type::U16),
                &Type::U16,
                &Type::U8
            ),
            Some(Value::ConstI8(1))
        );
        assert_eq!(
            Optimizer::eval_cast(
                &known(Value::ConstI64(300), Type::U16),
                &Type::U16,
                &Type::Char
            ),
            Some(Value::ConstI8(44))
        );
    }

    #[test]
    fn test_constant_folding_rewrites_cast_instruction() {
        let mut func = Function {
            name: "f".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::U8), (1, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 0,
                        src: Value::ConstI8(-1),
                        ty: Type::U8,
                    },
                    Instruction::Cast {
                        dst: 1,
                        src: Value::Var(0),
                        from_ty: Type::U8,
                        to_ty: Type::I64,
                    },
                    Instruction::Return(Some(Value::Var(1))),
                ],
            }],
            entry: "entry".into(),
        };

        assert!(Optimizer::constant_folding(&mut func));
        assert!(matches!(
            func.blocks[0].instructions[1],
            Instruction::Mov {
                dst: 1,
                src: Value::ConstI64(255),
                ty: Type::I64
            }
        ));
    }

    #[test]
    fn test_copy_propagation_preserves_contextual_integer_constants() {
        let mut func = Function {
            name: "f".into(),
            params: vec![(2, Type::U64)],
            ret: Type::Bool,
            locals: vec![(0, Type::U64), (1, Type::Bool)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 0,
                        src: Value::ConstI64(1),
                        ty: Type::U64,
                    },
                    Instruction::BinOp {
                        dst: 1,
                        op: BinOp::Lt,
                        lhs: Value::Var(0),
                        rhs: Value::Var(2),
                        ty: Type::Bool,
                    },
                    Instruction::Return(Some(Value::Var(1))),
                ],
            }],
            entry: "entry".into(),
        };

        assert!(!Optimizer::copy_propagation(&mut func));
        assert!(matches!(
            func.blocks[0].instructions[1],
            Instruction::BinOp {
                lhs: Value::Var(0),
                ..
            }
        ));
    }

    #[test]
    fn test_dead_code_elimination_treats_tail_call_args_as_uses() {
        let mut func = Function {
            name: "loop".into(),
            params: vec![(0, Type::I64)],
            ret: Type::I64,
            locals: vec![(1, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 1,
                        src: Value::Var(0),
                        ty: Type::I64,
                    },
                    Instruction::TailCall {
                        func: "loop".into(),
                        args: vec![Value::Var(1)],
                        ty: Type::I64,
                    },
                ],
            }],
            entry: "entry".into(),
        };

        assert!(!Optimizer::dead_code_elimination(&mut func));
        assert!(matches!(
            func.blocks[0].instructions.as_slice(),
            [
                Instruction::Mov { dst: 1, .. },
                Instruction::TailCall {
                    args,
                    ..
                }
            ] if args == &[Value::Var(1)]
        ));
    }

    #[test]
    fn test_constant_folding_does_not_propagate_across_branch_join() {
        let mut func = Function {
            name: "f".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Branch {
                            cond: Value::ConstBool(true),
                            true_label: "then".into(),
                            false_label: "else".into(),
                        },
                    ],
                },
                BasicBlock {
                    label: "then".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(2),
                            ty: Type::I64,
                        },
                        Instruction::Jump("join".into()),
                    ],
                },
                BasicBlock {
                    label: "else".into(),
                    instructions: vec![Instruction::Jump("join".into())],
                },
                BasicBlock {
                    label: "join".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 1,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                },
            ],
            entry: "entry".into(),
        };

        assert!(
            !Optimizer::constant_folding(&mut func),
            "branch-local constants must not flow into join blocks"
        );
        assert!(matches!(
            func.blocks[3].instructions[0],
            Instruction::BinOp {
                lhs: Value::Var(0),
                rhs: Value::ConstI64(1),
                ..
            }
        ));
    }

    #[test]
    fn test_constant_folding_does_not_use_block_order_through_loop_backedge() {
        let mut func = Function {
            name: "f".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64), (2, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(0),
                            ty: Type::I64,
                        },
                        Instruction::Jump("loop".into()),
                    ],
                },
                BasicBlock {
                    label: "loop".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 1,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Mov {
                            dst: 0,
                            src: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::Branch {
                            cond: Value::ConstBool(false),
                            true_label: "loop".into(),
                            false_label: "exit".into(),
                        },
                    ],
                },
                BasicBlock {
                    label: "exit".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(2))),
                    ],
                },
            ],
            entry: "entry".into(),
        };

        assert!(
            !Optimizer::constant_folding(&mut func),
            "constants from entry/loop blocks must not be reused through a backedge"
        );
        assert!(matches!(
            func.blocks[1].instructions[0],
            Instruction::BinOp {
                lhs: Value::Var(0),
                ..
            }
        ));
        assert!(matches!(
            func.blocks[2].instructions[0],
            Instruction::BinOp {
                lhs: Value::Var(0),
                ..
            }
        ));
    }

    #[test]
    fn test_copy_propagation_does_not_propagate_across_branch_join() {
        let mut func = Function {
            name: "f".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Branch {
                            cond: Value::ConstBool(true),
                            true_label: "then".into(),
                            false_label: "else".into(),
                        },
                    ],
                },
                BasicBlock {
                    label: "then".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(2),
                            ty: Type::I64,
                        },
                        Instruction::Jump("join".into()),
                    ],
                },
                BasicBlock {
                    label: "else".into(),
                    instructions: vec![Instruction::Jump("join".into())],
                },
                BasicBlock {
                    label: "join".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 1,
                            src: Value::Var(0),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                },
            ],
            entry: "entry".into(),
        };

        assert!(
            Optimizer::copy_propagation(&mut func),
            "the join block's own copy can still propagate locally"
        );
        assert!(matches!(
            func.blocks[3].instructions[0],
            Instruction::Mov {
                src: Value::Var(0),
                ..
            }
        ));
        assert!(matches!(
            func.blocks[3].instructions[1],
            Instruction::Return(Some(Value::Var(0)))
        ));
    }

    #[test]
    fn test_copy_propagation_does_not_rewrite_phi_incoming_values() {
        let mut func = Function {
            name: "f".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![BasicBlock {
                label: "join".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 0,
                        src: Value::ConstI64(1),
                        ty: Type::I64,
                    },
                    Instruction::Phi {
                        dst: 1,
                        incoming: vec![(Value::Var(0), "pred".into())],
                        ty: Type::I64,
                    },
                    Instruction::Return(Some(Value::Var(1))),
                ],
            }],
            entry: "join".into(),
        };

        assert!(
            !Optimizer::copy_propagation(&mut func),
            "current-block copies do not describe phi predecessor values"
        );
        assert!(matches!(
            &func.blocks[0].instructions[1],
            Instruction::Phi { incoming, .. }
                if incoming == &vec![(Value::Var(0), "pred".into())]
        ));
    }

    #[test]
    fn test_basic_block_cse_reuses_repeated_pure_binop() {
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64), (1, Type::I64)],
                ret: Type::I64,
                locals: vec![(2, Type::I64), (3, Type::I64), (4, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::BinOp {
                            dst: 3,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::BinOp {
                            dst: 4,
                            op: BinOp::Mul,
                            lhs: Value::Var(3),
                            rhs: Value::ConstI64(2),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(4))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        let add_count = instrs
            .iter()
            .filter(|instr| matches!(instr, Instruction::BinOp { op: BinOp::Add, .. }))
            .count();
        assert_eq!(add_count, 1, "expected one add after CSE: {instrs:?}");
        assert!(matches!(
            instrs.last(),
            Some(Instruction::Return(Some(Value::Var(4))))
        ));
        assert!(
            instrs.iter().any(|instr| matches!(
                instr,
                Instruction::BinOp {
                    dst: 4,
                    op: BinOp::Mul,
                    lhs: Value::Var(2),
                    rhs: Value::ConstI64(2),
                    ..
                }
            )),
            "expected later use to refer to the first add result: {instrs:?}"
        );
    }

    #[test]
    fn test_basic_block_cse_does_not_eliminate_loads_or_calls() {
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![
                    (1, Type::I64),
                    (2, Type::I64),
                    (3, Type::I64),
                    (4, Type::I64),
                ],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Load {
                            dst: 1,
                            src: Value::Var(0),
                            ty: Type::I64,
                        },
                        Instruction::Load {
                            dst: 2,
                            src: Value::Var(0),
                            ty: Type::I64,
                        },
                        Instruction::Call {
                            dst: Some(3),
                            func: "effect".into(),
                            args: vec![Value::Var(1)],
                            ty: Type::I64,
                        },
                        Instruction::Call {
                            dst: Some(4),
                            func: "effect".into(),
                            args: vec![Value::Var(2)],
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(4))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        let load_count = instrs
            .iter()
            .filter(|instr| matches!(instr, Instruction::Load { .. }))
            .count();
        let call_count = instrs
            .iter()
            .filter(|instr| matches!(instr, Instruction::Call { .. }))
            .count();
        assert_eq!(
            load_count, 2,
            "loads must not be CSE candidates: {instrs:?}"
        );
        assert_eq!(
            call_count, 2,
            "calls must not be CSE candidates: {instrs:?}"
        );
    }

    #[test]
    fn test_basic_block_cse_does_not_reuse_across_store() {
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64), (1, Type::I64)],
                ret: Type::I64,
                locals: vec![(2, Type::I64), (3, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Store {
                            dst: Value::Var(1),
                            src: Value::Var(2),
                            ty: Type::I64,
                        },
                        Instruction::BinOp {
                            dst: 3,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(3))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        let add_count = instrs
            .iter()
            .filter(|instr| matches!(instr, Instruction::BinOp { op: BinOp::Add, .. }))
            .count();
        assert_eq!(add_count, 2, "stores must invalidate CSE state: {instrs:?}");
    }

    #[test]
    fn test_basic_block_cse_does_not_cross_block_boundaries() {
        let mut func = Function {
            name: "f".into(),
            params: vec![(0, Type::I64), (1, Type::I64)],
            ret: Type::I64,
            locals: vec![(2, Type::I64), (3, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::Jump("next".into()),
                    ],
                },
                BasicBlock {
                    label: "next".into(),
                    instructions: vec![
                        Instruction::BinOp {
                            dst: 3,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(3))),
                    ],
                },
            ],
            entry: "entry".into(),
        };

        assert!(
            !Optimizer::common_subexpression_elimination(&mut func),
            "same expression in different blocks must not be rewritten"
        );
        assert!(matches!(
            func.blocks[1].instructions[0],
            Instruction::BinOp { dst: 3, .. }
        ));
    }

    #[test]
    fn test_vector_ir_is_not_cse_rewritten_by_scalar_optimizer() {
        let vec_ty = Type::Vector(Box::new(Type::I64), 4);
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, vec_ty.clone()), (1, vec_ty.clone())],
                ret: Type::Unit,
                locals: vec![(2, vec_ty.clone()), (3, vec_ty)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::VectorBinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::VectorBinOp {
                            dst: 3,
                            op: BinOp::Add,
                            lhs: Value::Var(0),
                            rhs: Value::Var(1),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::Return(None),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        assert_eq!(
            instrs
                .iter()
                .filter(|instr| matches!(instr, Instruction::VectorBinOp { .. }))
                .count(),
            2,
            "vector ops need explicit vector-aware CSE: {instrs:?}"
        );
        assert!(
            !instrs
                .iter()
                .any(|instr| matches!(instr, Instruction::Mov { dst: 3, .. })),
            "scalar CSE must not rewrite vector op to a move: {instrs:?}"
        );
    }

    #[test]
    fn test_vector_reduction_ir_is_not_cse_rewritten_by_scalar_optimizer() {
        let vec_ty = Type::Vector(Box::new(Type::I64), 4);
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, vec_ty)],
                ret: Type::Unit,
                locals: vec![(1, Type::I64), (2, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::VectorReduce {
                            dst: 1,
                            op: VectorReduceOp::Sum,
                            src: Value::Var(0),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::VectorReduce {
                            dst: 2,
                            op: VectorReduceOp::Sum,
                            src: Value::Var(0),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::Return(None),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        assert_eq!(
            instrs
                .iter()
                .filter(|instr| matches!(instr, Instruction::VectorReduce { .. }))
                .count(),
            2,
            "vector reductions need explicit vector-aware CSE: {instrs:?}"
        );
        assert!(
            !instrs
                .iter()
                .any(|instr| matches!(instr, Instruction::Mov { dst: 2, .. })),
            "scalar CSE must not rewrite vector reduction to a move: {instrs:?}"
        );
    }

    #[test]
    fn test_vector_reduce_result_clears_stale_scalar_constant() {
        let vec_ty = Type::Vector(Box::new(Type::I64), 4);
        let mut program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, vec_ty)],
                ret: Type::I64,
                locals: vec![(1, Type::I64), (2, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 1,
                            src: Value::ConstI64(10),
                            ty: Type::I64,
                        },
                        Instruction::VectorReduce {
                            dst: 1,
                            op: VectorReduceOp::Sum,
                            src: Value::Var(0),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::BinOp {
                            dst: 2,
                            op: BinOp::Add,
                            lhs: Value::Var(1),
                            rhs: Value::ConstI64(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(2))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        Optimizer::optimize(&mut program);

        let instrs = &program.functions[0].blocks[0].instructions;
        assert!(
            instrs.iter().any(|instr| matches!(
                instr,
                Instruction::BinOp {
                    lhs: Value::Var(1),
                    ..
                }
            )),
            "vector reduction result must clear stale scalar constants: {instrs:?}"
        );
        assert!(
            !instrs.iter().any(|instr| matches!(
                instr,
                Instruction::Mov {
                    dst: 2,
                    src: Value::ConstI64(11),
                    ..
                }
            )),
            "scalar folding must not reuse constants overwritten by reductions: {instrs:?}"
        );
    }

    #[test]
    fn test_vector_copy_is_not_propagated_by_scalar_optimizer() {
        let vec_ty = Type::Vector(Box::new(Type::I64), 4);
        let mut func = Function {
            name: "f".into(),
            params: vec![(0, vec_ty.clone()), (1, vec_ty.clone())],
            ret: Type::Unit,
            locals: vec![(2, vec_ty.clone()), (3, vec_ty)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 2,
                        src: Value::Var(0),
                        ty: Type::Vector(Box::new(Type::I64), 4),
                    },
                    Instruction::VectorBinOp {
                        dst: 3,
                        op: BinOp::Add,
                        lhs: Value::Var(2),
                        rhs: Value::Var(1),
                        lanes: 4,
                        elem_ty: Type::I64,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        assert!(
            !Optimizer::copy_propagation(&mut func),
            "vector copies should wait for a vector-aware propagation pass"
        );
        assert!(matches!(
            func.blocks[0].instructions[1],
            Instruction::VectorBinOp {
                lhs: Value::Var(2),
                ..
            }
        ));
    }

    #[test]
    fn test_mask_copy_is_not_propagated_by_scalar_optimizer() {
        let mut func = Function {
            name: "f".into(),
            params: vec![(0, Type::Mask(4)), (1, Type::Mask(4))],
            ret: Type::Unit,
            locals: vec![(2, Type::Mask(4)), (3, Type::Mask(4))],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 2,
                        src: Value::Var(0),
                        ty: Type::Mask(4),
                    },
                    Instruction::MaskBinOp {
                        dst: 3,
                        op: MaskBinOp::And,
                        lhs: Value::Var(2),
                        rhs: Value::Var(1),
                        lanes: 4,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        assert!(!Optimizer::copy_propagation(&mut func));
        assert!(matches!(
            func.blocks[0].instructions[1],
            Instruction::MaskBinOp {
                lhs: Value::Var(2),
                ..
            }
        ));
    }

    #[test]
    fn test_mask_reduce_does_not_receive_propagated_mask_copy() {
        let mut func = Function {
            name: "f".into(),
            params: vec![(0, Type::Mask(4))],
            ret: Type::Unit,
            locals: vec![(1, Type::Mask(4)), (2, Type::Bool)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 1,
                        src: Value::Var(0),
                        ty: Type::Mask(4),
                    },
                    Instruction::MaskReduce {
                        dst: 2,
                        op: MaskReduceOp::Any,
                        src: Value::Var(1),
                        lanes: 4,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        assert!(!Optimizer::copy_propagation(&mut func));
        assert!(matches!(
            func.blocks[0].instructions[1],
            Instruction::MaskReduce {
                src: Value::Var(1),
                ..
            }
        ));
    }
}
