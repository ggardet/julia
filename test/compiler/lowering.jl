using Core: SSAValue

# Call into lowering stage 1; syntax desugaring
function fl_expand_forms(ex)
    ccall(:jl_call_scm_on_ast_formonly, Any, (Cstring, Any, Any), "expand-forms", ex, Main)
end

function lift_lowered_expr!(ex, nextids, valmap, lift_full)
    if ex isa SSAValue
        # Rename SSAValues into renumbered symbols
        return get!(valmap, ex) do
            newid = nextids[1]
            nextids[1] = newid+1
            Symbol("ssa$newid")
        end
    end
    if ex isa Symbol
        name = string(ex)
        if startswith(name, "#s")
            return get!(valmap, ex) do
                newid = nextids[2]
                nextids[2] = newid+1
                Symbol("gsym$newid")
            end
        end
    end
    if ex isa Expr
        filter!(e->!(e isa LineNumberNode), ex.args)
        if ex.head == :block && length(ex.args) == 1
            # Remove trivial blocks
            return lift_lowered_expr!(ex.args[1], nextids, valmap, lift_full)
        end
        map!(ex.args, ex.args) do e
            lift_lowered_expr!(e, nextids, valmap, lift_full)
        end
        if lift_full
            # Lift exotic Expr heads into standard julia syntax for ease in
            # writing test case expressions.
            if ex.head == :top || ex.head == :core
                # Special global refs renamed to look like modules
                newhead = ex.head == :top ? :Top : :Core
                return Expr(:(.), newhead, QuoteNode(ex.args[1]))
            elseif ex.head == :unnecessary
                # `unnecessary` marks expressions generated by lowering that
                # do not need to be evaluated if their value is unused.
                return Expr(:call, :maybe_unused, ex.args...)
            end
        end
    end
    return ex
end

"""
Clean up an `Expr` into an equivalent form which can be easily entered by
hand

* Replacing `SSAValue(id)` with consecutively numbered symbols :ssa\$i
* Remove trivial blocks
"""
function lift_lowered_expr(ex; lift_full=false)
    valmap = Dict{Union{Symbol,SSAValue},Symbol}()
    lift_lowered_expr!(deepcopy(ex), ones(Int,2), valmap, lift_full)
end

"""
Very slight lowering of reference expressions to allow comparison with
desugared forms.

* Remove trivial blocks
* Translate psuedo-module expressions Top.x and Core.x to Expr(:top) and
  Expr(:core)
"""
function lower_ref_expr!(ex)
    if ex isa Expr
        filter!(e->!(e isa LineNumberNode), ex.args)
        map!(lower_ref_expr!, ex.args, ex.args)
        if ex.head == :block && length(ex.args) == 1
            # Remove trivial blocks
            return lower_ref_expr!(ex.args[1])
        end
        # Translate a selection of special expressions into the exotic Expr
        # heads used in lowered code.
        if ex.head == :(.) && length(ex.args) >= 1 && (ex.args[1] == :Top ||
                                                       ex.args[1] == :Core)
            (length(ex.args) == 2 && ex.args[2] isa QuoteNode) || throw("Unexpected top/core expression $(sprint(dump, ex))")
            return Expr(ex.args[1] == :Top ? :top : :core, ex.args[2].value)
        elseif ex.head == :call && length(ex.args) >= 1 && ex.args[1] == :maybe_unused
            return Expr(:unnecessary, ex.args[2:end]...)
        elseif ex.head == :$ && length(ex.args) == 1 && ex.args[1] isa Expr &&
               ex.args[1].head == :call && ex.args[1].args[1] == :Expr
            # Expand exprs of form $(Expr(head, ...))
            return Expr(map(q->q.value, ex.args[1].args[2:end])...)
        elseif ex.head == :macrocall
            # TODO heads for blocks
        end
    end
    return ex
end
lower_ref_expr(ex) = lower_ref_expr!(deepcopy(ex))


function diffdump(io::IOContext, ex1, ex2, n, prefix, indent)
    if ex1 == ex2
        isempty(prefix) || print(io, prefix)
        dump(io, ex1, n, indent)
    else
        if ex1 isa Expr && ex2 isa Expr && ex1.head == ex2.head && length(ex1.args) == length(ex2.args)
            isempty(prefix) || print(io, prefix)
            println(io, "Expr")
            println(io, indent, "  head: ", ex1.head)
            println(io, indent, "  args: Array{Any}(", size(ex1.args), ")")
            for i in 1:length(ex1.args)
                prefix = string(indent, "    ", i, ": ")
                diffdump(io, ex1.args[i], ex2.args[i], n - 1, prefix, string("    ", indent))
                i < length(ex1.args) && println(io)
            end
        else
            printstyled(io, string(prefix, sprint(dump, ex1, n, indent; context=io)), color=:red)
            println()
            printstyled(io, string(prefix, sprint(dump, ex2, n, indent; context=io)), color=:green)
        end
    end
end

"""
Display colored differences between two expressions `ex1` and `ex2` using the
`dump` format.
"""
function diffdump(ex1, ex2; maxdepth=20)
    mod = get(stdout, :module, Main)
    diffdump(IOContext(stdout, :limit => true, :module => mod), ex1, ex2, maxdepth, "", "")
    println(stdout)
end

# For interactive convenience in constructing test cases with flisp based lowering
desugar(ex) = lift_lowered_expr(fl_expand_forms(ex); lift_full=true)

macro desugar(ex)
    quote
        desugar($(QuoteNode(ex)))
    end
end

"""
Test that syntax desugaring of `input` produces an expression equivalent to the
reference expression `ref`.
"""
macro test_desugar(input, ref)
    ex = quote
        input = lift_lowered_expr(fl_expand_forms($(QuoteNode(input))))
        ref   = lower_ref_expr($(QuoteNode(ref)))
        @test input == ref
        if input != ref
            # Kinda crude. Would be better if Test supported custom/more
            # capable diffing for failed tests.
            println("Diff dump:")
            diffdump(input, ref)
        end
    end
    # Attribute the test to the correct line number
    @assert ex.args[6].args[1] == Symbol("@test")
    ex.args[6].args[2] = __source__
    ex
end

macro test_desugar_error(input, msg)
    ex = quote
        input = lift_lowered_expr(fl_expand_forms($(QuoteNode(input))))
        @test input == Expr(:error, $msg)
    end
    # Attribute the test to the correct line number
    @assert ex.args[4].args[1] == Symbol("@test")
    ex.args[4].args[2] = __source__
    ex
end

#-------------------------------------------------------------------------------
# Tests

@testset "Property notation" begin
    @test_desugar a.b    Top.getproperty(a, :b)
    @test_desugar a.b.c  Top.getproperty(Top.getproperty(a, :b), :c)

    @test_desugar(a.b = c,
        begin
            Top.setproperty!(a, :b, c)
            maybe_unused(c)
        end
    )
    @test_desugar(a.b.c = d,
        begin
            ssa1 = Top.getproperty(a, :b)
            Top.setproperty!(ssa1, :c, d)
            maybe_unused(d)
        end
    )
end

@testset "Index notation" begin
    # (process-indices) (partially-expand-ref)
    @testset "getindex" begin
        # Indexing
        @test_desugar a[i]      Top.getindex(a, i) 
        @test_desugar a[i,j]    Top.getindex(a, i, j) 
        # Indexing with `end`
        @test_desugar a[end]    Top.getindex(a, Top.lastindex(a)) 
        @test_desugar a[i,end]  Top.getindex(a, i, Top.lastindex(a,2)) 
        # Nesting of `end`
        @test_desugar a[[end]]  Top.getindex(a, Top.vect(Top.lastindex(a)))
        @test_desugar a[b[end] + end]  Top.getindex(a, Top.getindex(b, Top.lastindex(b)) + Top.lastindex(a)) 
        @test_desugar a[f(end) + 1]    Top.getindex(a, f(Top.lastindex(a)) + 1) 
        # Interaction of `end` with splatting
        @test_desugar(a[I..., end],
            Core._apply(Top.getindex, Core.tuple(a), I,
                        Core.tuple(Top.lastindex(a, Top.:+(1, Top.length(I)))))
        )

        @test_desugar_error a[i,j;k]  "unexpected semicolon in array expression"
    end

    @testset "setindex!" begin
        # (lambda in expand-table)
        @test_desugar(a[i] = b,
            begin
                Top.setindex!(a, b, i)
                maybe_unused(b)
            end
        )
        @test_desugar(a[i,end] = b+c,
            begin
                ssa1 = b+c
                Top.setindex!(a, ssa1, i, Top.lastindex(a,2))
                maybe_unused(ssa1)
            end
        )
    end
end

@testset "Array notation" begin
    @testset "Literals" begin
        @test_desugar [a,b]     Top.vect(a,b)
        @test_desugar T[a,b]    Top.getindex(T, a,b)  # Only so much syntax to go round :-/
        @test_desugar_error [a,b;c]  "unexpected semicolon in array expression"
        @test_desugar_error [a=b,c]  "misplaced assignment statement in \"[a = b, c]\""
    end

    @testset "Concatenation" begin
        # (lambda in expand-table)
        @test_desugar [a b]     Top.hcat(a,b)
        @test_desugar [a; b]    Top.vcat(a,b)
        @test_desugar T[a b]    Top.typed_hcat(T, a,b)
        @test_desugar T[a; b]   Top.typed_vcat(T, a,b)
        @test_desugar [a b; c]  Top.hvcat(Core.tuple(2,1), a, b, c)
        @test_desugar T[a b; c] Top.typed_hvcat(T, Core.tuple(2,1), a, b, c)

        @test_desugar_error [a b=c]   "misplaced assignment statement in \"[a b = c]\""
        @test_desugar_error [a; b=c]  "misplaced assignment statement in \"[a; b = c]\""
        @test_desugar_error T[a b=c]  "misplaced assignment statement in \"T[a b = c]\""
        @test_desugar_error T[a; b=c] "misplaced assignment statement in \"T[a; b = c]\""
    end
end

@testset "Splatting" begin
    @test_desugar f(i,j,v...,k)  Core._apply(f, Core.tuple(i,j), v, Core.tuple(k))
end

@testset "Comparison chains" begin
    # (expand-compare-chain)
    @test_desugar(a < b < c,
        if a < b
            b < c
        else
            false
        end
    )
    # Nested
    @test_desugar(a < b > d <= e,
        if a < b
            if b > d
                d <= e
            else
                false
            end
        else
            false
        end
    )
    # Subexpressions
    @test_desugar(a < b+c < d,
        if (ssa1 = b+c; a < ssa1)
            ssa1 < d
        else
            false
        end
    )

    # Interaction with broadcast syntax
    @test_desugar(a < b .< c,
        Top.materialize(Top.broadcasted(&, a < b, Top.broadcasted(<, b, c)))
    )
    @test_desugar(a .< b+c < d,
        Top.materialize(Top.broadcasted(&,
                                        begin
                                            ssa1 = b+c
                                            # Is this a bug?
                                            Top.materialize(Top.broadcasted(<, a, ssa1))
                                        end,
                                        ssa1 < d))
    )
    @test_desugar(a < b+c .< d,
        Top.materialize(Top.broadcasted(&,
                                        begin
                                            ssa1 = b+c
                                            a < ssa1
                                        end,
                                        Top.broadcasted(<, ssa1, d)))
    )
end

@testset "Short circuit , ternary" begin
    # (expand-or) (expand-and)
    @test_desugar a || b      if a; a else b end
    @test_desugar a && b      if a; b else false end
    @test_desugar a ? x : y   if a; x else y end
end

@testset "Adjoint" begin
    @test_desugar a'  Top.adjoint(a)
end

@testset "Broadcast" begin
    # Basic
    @test_desugar x .+ y        Top.materialize(Top.broadcasted(+, x, y))
    @test_desugar f.(x)         Top.materialize(Top.broadcasted(f, x))
    # Fusing
    @test_desugar f.(x) .+ g.(y)  Top.materialize(Top.broadcasted(+, Top.broadcasted(f, x),
                                                                  Top.broadcasted(g, y)))
    # Keywords don't participate
    @test_desugar(f.(x, a=1),
        Top.materialize(
            begin
                ssa1 = Top.broadcasted_kwsyntax
                ssa2 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
                Core.kwfunc(ssa1)(ssa2, ssa1, f, x)
            end
        )
    )
    # Nesting
    @test_desugar f.(g(x))      Top.materialize(Top.broadcasted(f, g(x)))
    @test_desugar f.(g(h.(x)))  Top.materialize(Top.broadcasted(f,
                                    g(Top.materialize(Top.broadcasted(h, x)))))

    # In place
    @test_desugar x .= a        Top.materialize!(x, Top.broadcasted(Top.identity, a))
    @test_desugar x .= f.(a)    Top.materialize!(x, Top.broadcasted(f, a))
    @test_desugar x .+= a       Top.materialize!(x, Top.broadcasted(+, x, a))
end

@testset "Keyword arguments" begin
    @test_desugar(
        f(x,a=1),
        begin
            ssa1 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
            Core.kwfunc(f)(ssa1, f, x)
        end
    )
end

@testset "In place update operators" begin
    # (lower-update-op)
    @test_desugar x += a       x = x+a
    @test_desugar x::Int += a  x = x::Int + a
    @test_desugar(x[end] += a,
        begin
            ssa1 = Top.lastindex(x)
            begin
                ssa2 = Top.getindex(x, ssa1) + a
                Top.setindex!(x, ssa2, ssa1)
                maybe_unused(ssa2)
            end
        end
    )
    @test_desugar(x[f(y)] += a,
        begin
            ssa1 = f(y)
            begin
                ssa2 = Top.getindex(x, ssa1) + a
                Top.setindex!(x, ssa2, ssa1)
                maybe_unused(ssa2)
            end
        end
    )
    @test_desugar((x,y) .+= a,
        begin
            ssa1 = Core.tuple(x, y)
            Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
        end
    )
    @test_desugar([x y] .+= a,
        begin
            ssa1 = Top.hcat(x, y)
            Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
        end
    )
    # TODO @test_desugar (x+y) += 1  Error
end

@testset "Assignment" begin
    # (lambda in expand-table)

    # Assignment chain; nontrivial rhs
    @test_desugar(x = y = f(a),
        begin
            ssa1 = f(a)
            y = ssa1
            x = ssa1
            maybe_unused(ssa1)
        end
    )

    @testset "Multiple Assignemnt" begin
        # Simple multiple assignment exact match
        @test_desugar((x,y) = (a,b),
            begin
                x = a
                y = b
                maybe_unused(Core.tuple(a,b))
            end
        )
        # Destructuring
        @test_desugar((x,y) = a,
            begin
                begin
                    ssa1 = Top.indexed_iterate(a, 1)
                    x = Core.getfield(ssa1, 1)
                    gsym1 = Core.getfield(ssa1, 2)
                    ssa1
                end
                begin
                    ssa2 = Top.indexed_iterate(a, 2, gsym1)
                    y = Core.getfield(ssa2, 1)
                    ssa2
                end
                maybe_unused(a)
            end
        )
        # Nested destructuring
        @test_desugar((x,(y,z)) = a,
            begin
                begin
                    ssa1 = Top.indexed_iterate(a, 1)
                    x = Core.getfield(ssa1, 1)
                    gsym1 = Core.getfield(ssa1, 2)
                    ssa1
                end
                begin
                    ssa2 = Top.indexed_iterate(a, 2, gsym1)
                    begin
                        ssa3 = Core.getfield(ssa2, 1)
                        begin
                            ssa4 = Top.indexed_iterate(ssa3, 1)
                            y = Core.getfield(ssa4, 1)
                            gsym2 = Core.getfield(ssa4, 2)
                            ssa4
                        end
                        begin
                            ssa5 = Top.indexed_iterate(ssa3, 2, gsym2)
                            z = Core.getfield(ssa5, 1)
                            ssa5
                        end
                        maybe_unused(ssa3)
                    end
                    ssa2
                end
                maybe_unused(a)
            end
        )
    end

    @test_desugar(x::T = a,
        begin
            $(Expr(:decl, :x, :T))
            x = a
        end
    )

    @test_desugar_error 1=a      "invalid assignment location \"1\""
    @test_desugar_error true=a   "invalid assignment location \"true\""
    @test_desugar_error "str"=a  "invalid assignment location \"\"str\"\""
end
