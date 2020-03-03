module Testy

using Test
using Distributed: addprocs, rmprocs, remotecall_fetch, remotecall, RemoteException

# TODO refactor into patch to bring these into Base

# NOTE: Since  the internals have changed in julia v1.3.0, we need VERSION checks inside
# these functions.

# Helper for `pmatch`: Mirrors Base.PCRE.exec
function pexec(re, subject, offset, options, match_data)
    rc = ccall((:pcre2_match_8, Base.PCRE.PCRE_LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Cuint, Ptr{Cvoid}, Ptr{Cvoid}),
               re, subject, sizeof(subject), offset, options, match_data,
               @static if VERSION >= v"1.3-"
                   Base.PCRE.get_local_match_context()
               else
                   Base.PCRE.MATCH_CONTEXT[]
               end)
    # rc == -1 means no match, -2 means partial match.
    rc < -2 && error("PCRE.exec error: $(err_message(rc))")
    (rc >= 0 ||
        # Allow partial matches if they were requested in the options.
        ((options & Base.PCRE.PARTIAL_HARD != 0 || options & Base.PCRE.PARTIAL_SOFT != 0) && rc == -2))
end

# Helper to call `pexec` w/ thread-safe match data: Mirrors Base.PCRE.exec_r_data
# Only used for Julia Version >= v"1.3-"
function pexec_r_data(re, subject, offset, options)
    match_data = Base.PCRE.create_match_data(re)
    ans = pexec(re, subject, offset, options, match_data)
    return ans, match_data
end

"""
   pmatch(r::Regex, s::AbstractString[, idx::Integer[, addopts]])

Variant of `Base.match` that supports partial matches (when `Base.PCRE.PARTIAL_HARD`
is set in `re.match_options`).
"""
function pmatch(re::Regex, str::Union{SubString{String}, String}, idx::Integer, add_opts::UInt32=UInt32(0))
    Base.compile(re)
    opts = re.match_options | add_opts
    @static if VERSION >= v"1.3-"
        # rc == -1 means no match, -2 means partial match.
        matched, data = pexec_r_data(re.regex, str, idx-1, opts)
        if !matched
            Base.PCRE.free_match_data(data)
            return nothing
        end
        n = div(Base.PCRE.ovec_length(data), 2) - 1
        p = Base.PCRE.ovec_ptr(data)
        mat = SubString(str, unsafe_load(p, 1)+1, prevind(str, unsafe_load(p, 2)+1))
        cap = Union{Nothing,SubString{String}}[unsafe_load(p,2i+1) == Base.PCRE.UNSET ? nothing :
                                            SubString(str, unsafe_load(p,2i+1)+1,
                                                      prevind(str, unsafe_load(p,2i+2)+1)) for i=1:n]
        off = Int[ unsafe_load(p,2i+1)+1 for i=1:n ]
        result = RegexMatch(mat, cap, unsafe_load(p,1)+1, off, re)
        Base.PCRE.free_match_data(data)
        return result
    else  #  Julia VERSION < v"1.3"
        # rc == -1 means no match, -2 means partial match.
        matched = pexec(re.regex, str, idx-1, opts, re.match_data)
        if !matched
            return nothing
        end
        ovec = re.ovec
        n = div(length(ovec),2) - 1
        mat = SubString(str, ovec[1]+1, prevind(str, ovec[2]+1))
        cap = Union{Nothing,SubString{String}}[ovec[2i+1] == PCRE.UNSET ? nothing :
                                            SubString(str, ovec[2i+1]+1,
                                                      prevind(str, ovec[2i+2]+1)) for i=1:n]
        off = Int[ ovec[2i+1]+1 for i=1:n ]
        RegexMatch(mat, cap, ovec[1]+1, off, re)
    end
end

pmatch(r::Regex, s::AbstractString) = pmatch(r, s, firstindex(s))
pmatch(r::Regex, s::AbstractString, i::Integer) = throw(ArgumentError(
    "regex matching is only available for the String type; use String(s) to convert"
))

"""
Constructs a regular expression to perform partial matching.
"""
partial(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS | Base.PCRE.PARTIAL_HARD)

"""
Constructs a regular expression to perform exact maching.
"""
exact(str::AbstractString) = Regex(str)


# struct TestySet <: Test.AbstractTestSet
#     parent::Test.DefaultTestSet
#
#     function TestySet(description::String)
#         new(Test.DefaultTestSet(description))
#     end
# end
#
# function Test.record(ts::TestySet, res::Test.Result)
#     # println("Recording $res for $(Test.get_test_set()) at depth $(Test.get_testset_depth())")
#     Test.record(ts.parent, res)
# end
#
# function Test.finish(ts::TestySet)
#     # println("Finishing")
#     Test.finish(ts.parent)
# end

"""
State maintained during a test run, consisting of a stack of strings
for the nested `@testset`s, a maximum depth beyond which we skip `@testset`s,
and a pair of regular expressions over `@testset` nestings used to decide
which `@testset`s should be executed.  We also keep a record of tests run or
skipped so that these can be reported at the end of the test run.
"""
struct TestyState
    stack::Vector{String}
    maxdepth::Int
    include::Regex
    exclude::Regex
    seen::Dict{String,Bool}
end

function open_testset(rs::TestyState, name::String)
    push!(rs.stack, name)
    join(rs.stack, "/")
end

function close_testset(rs::TestyState)
    pop!(rs.stack)
end

const ⊤ = r""       # matches any string
const ⊥ = r"(?!)"   # matches no string

TestyState() = TestyState([], typemax(Int64), ⊤, ⊥, Dict{String,Bool}())

TestyState(maxdepth::Int, include::Regex, exclude::Regex) =
   TestyState([], maxdepth, include, exclude, Dict{String,Bool}())

function checked_ts_expr(name::Expr, ts_expr::Expr)
    quote
        tls = task_local_storage()
        rs = haskey(tls, :__TESTY_STATE__) ? tls[:__TESTY_STATE__] : TestyState()
        print("  "^length(rs.stack))
        path = open_testset(rs, $name)
        shouldrun = length(rs.stack) <= rs.maxdepth &&
                pmatch(rs.include, path) != nothing && pmatch(rs.exclude, path) == nothing
        rs.seen[path] = shouldrun
        ts_obj = if shouldrun
            print("Running ")
            printstyled(path; bold=true)
            println(" tests...")
            $ts_expr
        else
            printstyled("Skipping $path tests...\n"; color=:light_black)
            nothing
        end
        close_testset(rs)
        ts_obj
    end
end

"Wrapped version of `Base.Test.@testset`."
macro testset(args...)
    ts_expr = esc(:($Test.@testset($(args...))))
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr)
end

function runtests(fun::Function, depth::Int64=typemax(Int64), args...)
    includes = []
    excludes = ["(?!)"]     # seed with an unsatisfiable regex
    for arg in args
        if startswith(arg, "-") || startswith(arg, "¬")
            push!(excludes, arg[nextind(arg,1):end])
        else
            push!(includes, arg)
        end
    end
    include = partial(join(includes, "|"))
    exclude = exact(join(excludes, "|"))
    state = TestyState(depth, include, exclude)
    task_local_storage(:__TESTY_STATE__, state) do
        fun()
    end
    state
end

macro distributed_testset(args...)
    # Enforce that this occurs inside a `@sync` expression (since we need to keep the parent
    # TestSet alive).
    var = Base.sync_varname
    test_proc = gensym("test_proc")
    init_success = gensym("init_success")
    future = gensym("future")
    inner_ts = gensym("inner_ts")
    ts = gensym("ts")
    e = gensym("e")
    test_error = gensym("test_error")
    default_testset = gensym("default_testset")

    esc(quote
        # Create an outer testset to group the tests in this `distributed_testset`.
        $default_testset = $Test.DefaultTestSet($args[1])
        @assert $(Expr(:isdefined, var)) "@distributed_testset must be called within a @sync block!"
        ($test_proc,) = $addprocs(1)
        $init_success = $remotecall_fetch(()->begin
            @eval begin
                using Pkg
                Pkg.activate($(Base.current_project()))
                import Testy
            end
        end, $test_proc)
        $future = $remotecall(()->begin
            # Return the user created testset expression
            $Testy.@testset $(args...)
        end, $test_proc)
        $Base.@async begin
            try
                $ts = fetch($future)
                $rmprocs($test_proc)
                @assert $ts isa $Test.DefaultTestSet
                # Record the results of the TestSet into our parent TestSet, as if it wasn't remote.
                $Test.record($default_testset, $ts)
            catch $e
                if $e isa $RemoteException
                    if $e.captured.ex isa $Test.TestSetException
                        for $test_error in $e.captured.ex.errors_and_fails
		              $Test.record($default_testset, $test_error)
                        end
                    end
                else
                    $Base.rethrow()
                end
            end
        end
        # We finished running the tests. Call finish to display the result
        $Test.finish($default_testset)
    end)
end

"""
Include file `filepath` and execute test sets matching the regular expressions
in `args`.  See alternative form of `runtests` for examples.
"""
function runtests(filepath::String, args...)
    runtests(typemax(Int), args...) do
        @eval Main begin
            # Construct a new throw-away module in which to run the tests
            # (see https://github.com/RelationalAI-oss/Testy.jl/issues/2)
            m = @eval Main module $(gensym("TestyModule")) end  # e.g. Main.##TestyModule#365
            # Perform the include inside the new module m
            m.include($filepath)
        end
    end
end

"""
Include file `test/runtests.jl` and execute test sets matching the regular
expressions in `args` (where a leading '-' or '¬' indicates that tests
matching the expression should be excluded).

# Examples
```jldoctest
julia> runtests(["t/a/.*"])         # Run all tests under `t/a`

julia> runtests(["t/.*", "¬t/b/2"])  # Run all tests under `t` except `t/b/2`
```
"""
function runtests(args::Vector{String})
    testfile = pwd() * "/test/runtests.jl"
    if !isfile(testfile)
        @error("Could not find test/runtests.jl")
        return
    end
    runtests(testfile, args...)
end

"""
Run test sets up to the provided nesting `depth` and matching the regular
expressions in `args`.
"""
function runtests(depth::Int, args...)
    testfile = pwd() * "/test/runtests.jl"
    if !isfile(testfile)
        @error("Could not find test/runtests.jl")
        return
    end
    runtests(testfile, depth, args...)
end

export @testset, @test_broken
export runtests, showtests

#
# Purely delegated macros and functions
#
using Test: @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated
using Test: @inferred
using Test: detect_ambiguities, detect_unbound_args
using Test: GenericString, GenericSet, GenericDict, GenericArray
using Test: TestSetException
using Test: get_testset, get_testset_depth
using Test: AbstractTestSet, DefaultTestSet, record, finish

export @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated
export @inferred
export detect_ambiguities, detect_unbound_args
export GenericString, GenericSet, GenericDict, GenericArray
export TestSetException
export get_testset, get_testset_depth
export AbstractTestSet, DefaultTestSet, record, finish

end
