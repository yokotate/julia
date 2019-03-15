# This file is a part of Julia. License is MIT: https://julialang.org/license

# RUN: julia --startup-file=no %s %t && llvm-link -S %t/* -o %t/module.ll
# RUN: cat %t/module.ll | FileCheck %s
# RUN: cat %t/module.ll | opt -load libjulia%shlibext -LowerSIMDLoop -S - | FileCheck %s -check-prefix=LOWER
using InteractiveUtils
using Printf

dir = ARGS[1]
rm(dir, force=true, recursive=true)
mkdir(dir)

# CHECK-LABEL: @julia_simdf_
# LOWER-LABEL: @julia_simdf_
function simdf(X)
    acc = zero(eltype(X))
    @simd for x in X
        acc += x
# CHECK: call void @julia.loopinfo_marker(), {{.*}}, !julia.loopinfo [[LOOPINFO:![0-9]+]]
# LOWER-NOT: llvm.mem.parallel_loop_access
# LOWER-NOT: call void @julia.loopinfo_marker()
# LOWER: fadd fast double
# LOWER: br {{.*}}, !llvm.loop [[LOOPID:![0-9]+]]
    end
    acc
end

# CHECK-LABEL: @julia_simdf2_
# LOWER-LABEL: @julia_simdf2_
function simdf2(X)
    acc = zero(eltype(X))
    @simd ivdep for x in X
        acc += x
# CHECK: call void @julia.loopinfo_marker(), {{.*}}, !julia.loopinfo [[LOOPINFO2:![0-9]+]]
# LOWER: llvm.mem.parallel_loop_access
# LOWER-NOT: call void @julia.loopinfo_marker()
# LOWER: fadd fast double
# LOWER: br {{.*}}, !llvm.loop [[LOOPID2:![0-9]+]]
    end
    acc
end

@noinline iterate(i) = @show i

# CHECK-LABEL: @julia_loop_unroll
# LOWER-LABEL: @julia_loop_unroll
@eval function loop_unroll(N)
    for i in 1:N
        iterate(i)
        $(Expr(:loopinfo, (Symbol("llvm.loop.unroll.count"), 3)))
# CHECK: call void @julia.loopinfo_marker(), {{.*}}, !julia.loopinfo [[LOOPINFO3:![0-9]+]]
# LOWER-NOT: call void @julia.loopinfo_marker()
# LOWER: br {{.*}}, !llvm.loop [[LOOPID3:![0-9]+]]
    end
end

# CHECK-LABEL: @julia_loop_unroll2
# LOWER-LABEL: @julia_loop_unroll2
@eval function loop_unroll2(I)
    for i in 1:10
        for j in I
            j == 2 && continue
            iterate(i)
        end
        $(Expr(:loopinfo, (Symbol("llvm.loop.unroll.full"),)))
# CHECK: call void @julia.loopinfo_marker(), {{.*}}, !julia.loopinfo [[LOOPINFO4:![0-9]+]]
# LOWER-NOT: call void @julia.loopinfo_marker()
# LOWER: br {{.*}}, !llvm.loop [[LOOPID4:![0-9]+]]
    end
end

## Check all the MD nodes
# CHECK: [[LOOPINFO]] = !{!"julia.simdloop"}
# CHECK: [[LOOPINFO2]] = !{!"julia.simdloop", !"julia.ivdep"}
# CHECK: [[LOOPINFO3]] = !{[[LOOPUNROLL:![0-9]+]]}
# CHECK: [[LOOPUNROLL]] = !{!"llvm.loop.unroll.count", i64 3}
# CHECK: [[LOOPINFO4]] = !{[[LOOPUNROLL2:![0-9]+]]}
# CHECK: [[LOOPUNROLL2]] = !{!"llvm.loop.unroll.full"}
# LOWER: [[LOOPID]] = distinct !{[[LOOPID]]}
# LOWER: [[LOOPID2]] = distinct !{[[LOOPID2]]}
# LOWER: [[LOOPID3]] = distinct !{[[LOOPID3]], [[LOOPUNROLL:![0-9]+]]}
# LOWER: [[LOOPUNROLL]] = !{!"llvm.loop.unroll.count", i64 3}
# LOWER: [[LOOPID4]] = distinct !{[[LOOPID4]], [[LOOPUNROLL2:![0-9]+]]}
# LOWER: [[LOOPUNROLL2]] = !{!"llvm.loop.unroll.full"}

# Emit LLVM IR to dir
counter = 0
function emit(f, tt...)
    global counter
    name = nameof(f)
    open(joinpath(dir, @sprintf("%05d-%s.ll", counter, name)), "w") do io
        code_llvm(io, f, tt, raw=true, optimize=false, dump_module=true, debuginfo=:none)
    end
    counter+=1
end

# Maintaining the order is important
emit(simdf, Vector{Float64})
emit(simdf2, Vector{Float64})
emit(loop_unroll, Int64)
emit(loop_unroll2, Int64)
