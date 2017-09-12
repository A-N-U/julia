# This file is a part of Julia. License is MIT: https://julialang.org/license

module Random

using Base.dSFMT
using Base.GMP: Limb, MPZ
import Base: copymutable, copy, copy!, ==, hash

export srand,
       rand, rand!,
       randn, randn!,
       randexp, randexp!,
       bitrand,
       randstring,
       randsubseq, randsubseq!,
       shuffle, shuffle!,
       randperm, randperm!,
       randcycle, randcycle!,
       AbstractRNG, MersenneTwister, RandomDevice,
       GLOBAL_RNG, randjump


## general definitions

abstract type AbstractRNG end

defaultRNG() = GLOBAL_RNG # defined in RNGs.jl

### floats

abstract type FloatInterval{T<:AbstractFloat} end

struct CloseOpen{  T<:AbstractFloat} <: FloatInterval{T} end # interval [0,1)
struct Close1Open2{T<:AbstractFloat} <: FloatInterval{T} end # interval [1,2)

const FloatInterval_64 = FloatInterval{Float64}
const CloseOpen_64     = CloseOpen{Float64}
const Close1Open2_64   = Close1Open2{Float64}

CloseOpen(  ::Type{T}=Float64) where {T<:AbstractFloat} = CloseOpen{T}()
Close1Open2(::Type{T}=Float64) where {T<:AbstractFloat} = Close1Open2{T}()

Base.eltype(::Type{FloatInterval{T}}) where {T<:AbstractFloat} = T

const BitFloatType = Union{Type{Float16},Type{Float32},Type{Float64}}

### State

abstract type State end

# temporarily for BaseBenchmarks
RangeGenerator(x) = State(defaultRNG(), x)

# In some cases, when only 1 random value is to be generated,
# the optimal sampler can be different than if multiple values
# have to be generated. Hence a `Repetition` parameter is used
# to choose the best one depending on the need.
const Repetition = Union{Val{1},Val{Inf}}

# these default fall-back for all RNGs would be nice,
# but generate difficult-to-solve ambiguities
# State(::AbstractRNG, X, ::Val{Inf}) = State(X)
# State(::AbstractRNG, ::Type{X}, ::Val{Inf}) where {X} = State(X)

State(rng::AbstractRNG, st::State, ::Repetition) =
    throw(ArgumentError("State for this object is not defined"))

# default shortcut for the general case
State(rng::AbstractRNG, X) = State(rng, X, Val(Inf))
State(rng::AbstractRNG, ::Type{X}) where {X} = State(rng, X, Val(Inf))

#### pre-defined useful State subtypes

# default fall-back for types
struct StateType{T} <: State end

State(::AbstractRNG, ::Type{T}, ::Repetition) where {T} = StateType{T}()

Base.getindex(st::StateType{T}) where {T} = T

# default fall-back for values
struct StateTrivial{T} <: State
    self::T
end

State(::AbstractRNG, X, ::Repetition) = StateTrivial(X)

Base.getindex(st::StateTrivial) = st.self

struct StateSimple{T,S} <: State
    self::T
    state::S
end

Base.getindex(st::StateSimple) = st.self


### machinery for generation with State

#### scalars

rand(rng::AbstractRNG, X) = rand(rng, State(rng, X, Val(1)))
rand(rng::AbstractRNG=GLOBAL_RNG, ::Type{X}=Float64) where {X} =
    rand(rng, State(rng, X, Val(1)))

rand(X) = rand(GLOBAL_RNG, X)
rand(::Type{X}) where X = rand(GLOBAL_RNG, X)

#### arrays

rand!(A::AbstractArray{T}, X) where {T} = rand!(GLOBAL_RNG, A, X)
rand!(A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(GLOBAL_RNG, A, X)

rand!(rng::AbstractRNG, A::AbstractArray{T}, X) where {T} = rand!(rng, A, State(rng, X))
rand!(rng::AbstractRNG, A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(rng, A, State(rng, X))

function rand!(rng::AbstractRNG, A::AbstractArray{T}, st::State) where T
    for i in eachindex(A)
        @inbounds A[i] = rand(rng, st)
    end
    A
end

rand(r::AbstractRNG, dims::Dims)       = rand(r, Float64, dims)
rand(                dims::Dims)       = rand(GLOBAL_RNG, dims)
rand(r::AbstractRNG, dims::Integer...) = rand(r, Dims(dims))
rand(                dims::Integer...) = rand(Dims(dims))

rand(r::AbstractRNG, X, dims::Dims)  = rand!(r, Array{eltype(X)}(dims), X)
rand(                X, dims::Dims)  = rand(GLOBAL_RNG, X, dims)

rand(r::AbstractRNG, X, d::Integer, dims::Integer...) = rand(r, X, Dims((d, dims...)))
rand(                X, d::Integer, dims::Integer...) = rand(X, Dims((d, dims...)))
# note: the above methods would trigger an ambiguity warning if d was not separated out:
# rand(r, ()) would match both this method and rand(r, dims::Dims)
# moreover, a call like rand(r, NotImplementedType()) would be an infinite loop

rand(r::AbstractRNG, ::Type{X}, dims::Dims) where {X} = rand!(r, Array{eltype(X)}(dims), X)
rand(                ::Type{X}, dims::Dims) where {X} = rand(GLOBAL_RNG, X, dims)

rand(r::AbstractRNG, ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(r, X, Dims((d, dims...)))
rand(                ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(X, Dims((d, dims...)))


## __init__ & include

function __init__()
    try
        srand()
    catch ex
        Base.showerror_nostdio(ex,
            "WARNING: Error during initialization of module Random")
    end
end

include("RNGs.jl")
include("generation.jl")
include("normal.jl")
include("misc.jl")


## rand & rand! & srand docstrings

"""
    rand([rng=GLOBAL_RNG], [S], [dims...])

Pick a random element or array of random elements from the set of values specified by `S`;
`S` can be

* an indexable collection (for example `1:n` or `['x','y','z']`),
* an `Associative` or `AbstractSet` object,
* a string (considered as a collection of characters), or
* a type: the set of values to pick from is then equivalent to `typemin(S):typemax(S)` for
  integers (this is not applicable to [`BigInt`](@ref)), and to ``[0, 1)`` for floating
  point numbers;

`S` defaults to [`Float64`](@ref).

# Examples
```julia-repl
julia> rand(Int, 2)
2-element Array{Int64,1}:
 1339893410598768192
 1575814717733606317

julia> rand(MersenneTwister(0), Dict(1=>2, 3=>4))
1=>2
```

!!! note
    The complexity of `rand(rng, s::Union{Associative,AbstractSet})`
    is linear in the length of `s`, unless an optimized method with
    constant complexity is available, which is the case for `Dict`,
    `Set` and `IntSet`. For more than a few calls, use `rand(rng,
    collect(s))` instead, or either `rand(rng, Dict(s))` or `rand(rng,
    Set(s))` as appropriate.
"""
rand

"""
    rand!([rng=GLOBAL_RNG], A, [S=eltype(A)])

Populate the array `A` with random values. If `S` is specified
(`S` can be a type or a collection, cf. [`rand`](@ref) for details),
the values are picked randomly from `S`.
This is equivalent to `copy!(A, rand(rng, S, size(A)))`
but without allocating a new array.

# Examples
```jldoctest
julia> rng = MersenneTwister(1234);

julia> rand!(rng, zeros(5))
5-element Array{Float64,1}:
 0.590845
 0.766797
 0.566237
 0.460085
 0.794026
```
"""
rand!

"""
    srand([rng=GLOBAL_RNG], seed) -> rng
    srand([rng=GLOBAL_RNG]) -> rng

Reseed the random number generator: `rng` will give a reproducible
sequence of numbers if and only if a `seed` is provided. Some RNGs
don't accept a seed, like `RandomDevice`.
After the call to `srand`, `rng` is equivalent to a newly created
object initialized with the same seed.

# Examples
```julia-repl
julia> srand(1234);

julia> x1 = rand(2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> srand(1234);

julia> x2 = rand(2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> x1 == x2
true

julia> rng = MersenneTwister(1234); rand(rng, 2) == x1
true

julia> MersenneTwister(1) == srand(rng, 1)
true

julia> rand(srand(rng), Bool) # not reproducible
true

julia> rand(srand(rng), Bool)
false

julia> rand(MersenneTwister(), Bool) # not reproducible either
true
```
"""
srand(rng::AbstractRNG, ::Void) = srand(rng)

end # module
