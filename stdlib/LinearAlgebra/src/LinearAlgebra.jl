# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Linear algebra module. Provides array arithmetic,
matrix factorizations and other linear algebra related
functionality.
"""
module LinearAlgebra

import Base: \, /, *, ^, +, -, ==
import Base: USE_BLAS64, abs, acos, acosh, acot, acoth, acsc, acsch, adjoint, asec, asech,
    asin, asinh, atan, atanh, axes, big, broadcast, ceil, conj, convert, copy, copyto!, cos,
    cosh, cot, coth, csc, csch, eltype, exp, fill!, floor, getindex, hcat,
    getproperty, imag, inv, isapprox, isone, iszero, IndexStyle, kron, length, log, map, ndims,
    oneunit, parent, power_by_squaring, print_matrix, promote_rule, real, round, sec, sech,
    setindex!, show, similar, sin, sincos, sinh, size, sqrt,
    strides, stride, tan, tanh, transpose, trunc, typed_hcat, vec
using Base: hvcat_fill, IndexLinear, promote_op, promote_typeof,
    @propagate_inbounds, @pure, reduce, typed_vcat, require_one_based_indexing
using Base.Broadcast: Broadcasted, broadcasted

export
# Modules
    LAPACK,
    BLAS,

# Types
    Adjoint,
    Transpose,
    SymTridiagonal,
    Tridiagonal,
    Bidiagonal,
    Factorization,
    BunchKaufman,
    Cholesky,
    CholeskyPivoted,
    Eigen,
    GeneralizedEigen,
    GeneralizedSVD,
    GeneralizedSchur,
    Hessenberg,
    LU,
    LDLt,
    QR,
    QRPivoted,
    LQ,
    Schur,
    SVD,
    Hermitian,
    Symmetric,
    LowerTriangular,
    UpperTriangular,
    UnitLowerTriangular,
    UnitUpperTriangular,
    UpperHessenberg,
    Diagonal,
    UniformScaling,

# Functions
    axpy!,
    axpby!,
    bunchkaufman,
    bunchkaufman!,
    cholesky,
    cholesky!,
    cond,
    condskeel,
    copyto!,
    copy_transpose!,
    cross,
    adjoint,
    adjoint!,
    det,
    diag,
    diagind,
    diagm,
    dot,
    eigen,
    eigen!,
    eigmax,
    eigmin,
    eigvals,
    eigvals!,
    eigvecs,
    factorize,
    givens,
    hessenberg,
    hessenberg!,
    isdiag,
    ishermitian,
    isposdef,
    isposdef!,
    issuccess,
    issymmetric,
    istril,
    istriu,
    kron,
    ldiv!,
    ldlt!,
    ldlt,
    logabsdet,
    logdet,
    lowrankdowndate,
    lowrankdowndate!,
    lowrankupdate,
    lowrankupdate!,
    lu,
    lu!,
    lyap,
    mul!,
    lmul!,
    rmul!,
    norm,
    normalize,
    normalize!,
    nullspace,
    ordschur!,
    ordschur,
    pinv,
    qr,
    qr!,
    lq,
    lq!,
    opnorm,
    rank,
    rdiv!,
    reflect!,
    rotate!,
    schur,
    schur!,
    svd,
    svd!,
    svdvals!,
    svdvals,
    sylvester,
    tr,
    transpose,
    transpose!,
    tril,
    triu,
    tril!,
    triu!,

# Operators
    \,
    /,

# Constants
    I

const BlasFloat = Union{Float64,Float32,ComplexF64,ComplexF32}
const BlasReal = Union{Float64,Float32}
const BlasComplex = Union{ComplexF64,ComplexF32}

if USE_BLAS64
    const BlasInt = Int64
else
    const BlasInt = Int32
end


abstract type Algorithm end
struct DivideAndConquer <: Algorithm end
struct QRIteration <: Algorithm end


# Check that stride of matrix/vector is 1
# Writing like this to avoid splatting penalty when called with multiple arguments,
# see PR 16416
"""
    stride1(A) -> Int

Return the distance between successive array elements
in dimension 1 in units of element size.

# Examples
```jldoctest
julia> A = [1,2,3,4]
4-element Array{Int64,1}:
 1
 2
 3
 4

julia> LinearAlgebra.stride1(A)
1

julia> B = view(A, 2:2:4)
2-element view(::Array{Int64,1}, 2:2:4) with eltype Int64:
 2
 4

julia> LinearAlgebra.stride1(B)
2
```
"""
stride1(x) = stride(x,1)
stride1(x::Array) = 1
stride1(x::DenseArray) = stride(x, 1)::Int

@inline chkstride1(A...) = _chkstride1(true, A...)
@noinline _chkstride1(ok::Bool) = ok || error("matrix does not have contiguous columns")
@inline _chkstride1(ok::Bool, A, B...) = _chkstride1(ok & (stride1(A) == 1), B...)

"""
    LinearAlgebra.checksquare(A)

Check that a matrix is square, then return its common dimension.
For multiple arguments, return a vector.

# Examples
```jldoctest
julia> A = fill(1, (4,4)); B = fill(1, (5,5));

julia> LinearAlgebra.checksquare(A, B)
2-element Array{Int64,1}:
 4
 5
```
"""
function checksquare(A)
    m,n = size(A)
    m == n || throw(DimensionMismatch("matrix is not square: dimensions are $(size(A))"))
    m
end

function checksquare(A...)
    sizes = Int[]
    for a in A
        size(a,1)==size(a,2) || throw(DimensionMismatch("matrix is not square: dimensions are $(size(a))"))
        push!(sizes, size(a,1))
    end
    return sizes
end

function char_uplo(uplo::Symbol)
    if uplo === :U
        return 'U'
    elseif uplo === :L
        return 'L'
    else
        throw_uplo()
    end
end

function sym_uplo(uplo::Char)
    if uplo == 'U'
        return :U
    elseif uplo == 'L'
        return :L
    else
        throw_uplo()
    end
end


@noinline throw_uplo() = throw(ArgumentError("uplo argument must be either :U (upper) or :L (lower)"))


"""
    ldiv!(Y, A, B) -> Y

Compute `A \\ B` in-place and store the result in `Y`, returning the result.

The argument `A` should *not* be a matrix.  Rather, instead of matrices it should be a
factorization object (e.g. produced by [`factorize`](@ref) or [`cholesky`](@ref)).
The reason for this is that factorization itself is both expensive and typically allocates memory
(although it can also be done in-place via, e.g., [`lu!`](@ref)),
and performance-critical situations requiring `ldiv!` usually also require fine-grained
control over the factorization of `A`.

# Examples
```jldoctest
julia> A = [1 2.2 4; 3.1 0.2 3; 4 1 2];

julia> X = [1; 2.5; 3];

julia> Y = zero(X);

julia> ldiv!(Y, qr(A), X);

julia> Y
3-element Array{Float64,1}:
  0.7128099173553719
 -0.051652892561983674
  0.10020661157024757

julia> A\\X
3-element Array{Float64,1}:
  0.7128099173553719
 -0.05165289256198333
  0.10020661157024785
```
"""
ldiv!(Y, A, B)

"""
    ldiv!(A, B)

Compute `A \\ B` in-place and overwriting `B` to store the result.

The argument `A` should *not* be a matrix.  Rather, instead of matrices it should be a
factorization object (e.g. produced by [`factorize`](@ref) or [`cholesky`](@ref)).
The reason for this is that factorization itself is both expensive and typically allocates memory
(although it can also be done in-place via, e.g., [`lu!`](@ref)),
and performance-critical situations requiring `ldiv!` usually also require fine-grained
control over the factorization of `A`.

# Examples
```jldoctest
julia> A = [1 2.2 4; 3.1 0.2 3; 4 1 2];

julia> X = [1; 2.5; 3];

julia> Y = copy(X);

julia> ldiv!(qr(A), X);

julia> X
3-element Array{Float64,1}:
  0.7128099173553719
 -0.051652892561983674
  0.10020661157024757

julia> A\\Y
3-element Array{Float64,1}:
  0.7128099173553719
 -0.05165289256198333
  0.10020661157024785
```
"""
ldiv!(A, B)


"""
    rdiv!(A, B)

Compute `A / B` in-place and overwriting `A` to store the result.

The argument `B` should *not* be a matrix.  Rather, instead of matrices it should be a
factorization object (e.g. produced by [`factorize`](@ref) or [`cholesky`](@ref)).
The reason for this is that factorization itself is both expensive and typically allocates memory
(although it can also be done in-place via, e.g., [`lu!`](@ref)),
and performance-critical situations requiring `rdiv!` usually also require fine-grained
control over the factorization of `B`.
"""
rdiv!(A, B)

copy_oftype(A::AbstractArray{T}, ::Type{T}) where {T} = copy(A)
copy_oftype(A::AbstractArray{T,N}, ::Type{S}) where {T,N,S} = convert(AbstractArray{S,N}, A)

include("adjtrans.jl")
include("transpose.jl")

include("exceptions.jl")
include("generic.jl")

include("blas.jl")
include("matmul.jl")
include("lapack.jl")

include("dense.jl")
include("tridiag.jl")
include("triangular.jl")

include("factorization.jl")
include("qr.jl")
include("lq.jl")
include("eigen.jl")
include("svd.jl")
include("symmetric.jl")
include("cholesky.jl")
include("lu.jl")
include("bunchkaufman.jl")
include("diagonal.jl")
include("bidiag.jl")
include("uniformscaling.jl")
include("hessenberg.jl")
include("givens.jl")
include("special.jl")
include("bitarray.jl")
include("ldlt.jl")
include("schur.jl")
include("structuredbroadcast.jl")
include("deprecated.jl")

const ⋅ = dot
const × = cross
export ⋅, ×

"""
    hadamard(a, b)
    a ⊙ b

Elementwise multiplication of `a` and `b`. This yields the same result as `map(*, a, b)`
if `a` and `b` have the same axes, and throws an error otherwise.

`⊙` can be passed as an operator to higher-order functions.

```jldoctest
julia> a = [2, 3]; b = [5, 7];

julia> a ⊙ b
2-element Array{$Int,1}:
 10
 21

julia> a ⊙ [5]
ERROR: DimensionMismatch("in the axes of `A` and `B` must match, got (Base.OneTo(2),) and (Base.OneTo(1),)")
[...]
```

!!! compat "Julia 1.5"
    This function requires at least Julia 1.5. In Julia 1.0-1.4 it is available from
    the `Compat` package.
"""
function hadamard(A::AbstractArray, B::AbstractArray)
    @noinline throw_dmm(axA, axB) = throw(DimensionMismatch("Axes of `A` and `B` must match, got $axA and $axB"))

    axA, axB = axes(A), axes(B)
    axA == axB || throw_dmm(axA, axB)
    return map(hadamard, A, B)
end
hadamard(a, b) = a * b
const ⊙ = hadamard

"""
    hadamard!(dest, A, B)

Similar to `hadamard(A, B)` (which can also be written `A ⊙ B`), but stores its results in
the pre-allocated array `dest`.

!!! compat "Julia 1.5"
    This function requires at least Julia 1.5. In Julia 1.0-1.4 it is available from
    the `Compat` package.
"""
function hadamard!(dest::AbstractArray, A::AbstractArray, B::AbstractArray)
    @noinline function throw_dmm(axA, axB, axdest)
        throw(DimensionMismatch("`axes(dest) = $axdest` must be equal to `axes(A) = $axA` and `axes(B) = $axB`"))
    end

    axA, axB, axdest = axes(A), axes(B), axes(dest)
    ((axdest == axA) & (axdest == axB)) || throw_dmm(axA, axB, axdest)
    @simd for I in eachindex(dest, A, B)
        @inbounds dest[I] = A[I]*B[I]
    end
    return dest
end

export ⊙, hadamard, hadamard!

"""
    tensor(A, B)
    A ⊗ B

Compute the tensor product of `A` and `B`.
If `C = A ⊗ B`, then `C[i1, ..., im, j1, ..., jn] = A[i1, ... im] * B[j1, ..., jn]`.

```jldoctest
julia> a = [2, 3]; b = [5, 7, 11];

julia> a ⊗ b
2×3 Array{$Int,2}:
 10  14  22
 15  21  33
```

See also: [`kron`](@ref).

!!! compat "Julia 1.5"
    This function requires at least Julia 1.5. In Julia 1.0-1.4 it is available from
    the `Compat` package.
"""
tensor(A::AbstractArray, B::AbstractArray) = [a*b for a in A, b in B]
const ⊗ = tensor

function tensor(u::AbstractVector, v::Adjoint{T,<:AbstractVector}) where T
    error("`u ⊗ v'` is not defined, perhaps you meant `u * v'` or `u * transpose(v)`")
end
function tensor(u::AbstractVector, v::Transpose{T,<:AbstractVector}) where T
    error("`u ⊗ v'` is not defined, perhaps you meant `u * v'` or `u * transpose(v)`")
end

"""
    tensor!(dest, A, B)

Similar to `tensor(A, B)` (which can also be written `A ⊗ B`), but stores its results in
the pre-allocated array `dest`.

!!! compat "Julia 1.5"
    This function requires at least Julia 1.5. In Julia 1.0-1.4 it is available from
    the `Compat` package.
"""
function tensor!(dest::AbstractArray, A::AbstractArray, B::AbstractArray)
    @noinline function throw_dmm(axA, axB, axdest)
        throw(DimensionMismatch("`axes(dest) = $axdest` must concatenate `axes(A) = $axA` and `axes(B) = $axB`"))
    end

    axA, axB, axdest = axes(A), axes(B), axes(dest)
    axes(dest) == (axA..., axB...) || throw_dmm(axA, axB, axdest)
    if IndexStyle(dest) === IndexCartesian()
        for IB in CartesianIndices(axB)
            @inbounds b = B[IB]
            @simd for IA in CartesianIndices(axA)
                @inbounds dest[IA,IB] = A[IA]*b
            end
        end
    else
        i = firstindex(dest)
        @inbounds for b in B
            @simd for a in A
                dest[i] = a*b
                i += 1
            end
        end
    end
    return dest
end

export ⊗, tensor, tensor!

"""
    LinearAlgebra.peakflops(n::Integer=2000; parallel::Bool=false)

`peakflops` computes the peak flop rate of the computer by using double precision
[`gemm!`](@ref LinearAlgebra.BLAS.gemm!). By default, if no arguments are specified, it
multiplies a matrix of size `n x n`, where `n = 2000`. If the underlying BLAS is using
multiple threads, higher flop rates are realized. The number of BLAS threads can be set with
[`BLAS.set_num_threads(n)`](@ref).

If the keyword argument `parallel` is set to `true`, `peakflops` is run in parallel on all
the worker processors. The flop rate of the entire parallel computer is returned. When
running in parallel, only 1 BLAS thread is used. The argument `n` still refers to the size
of the problem that is solved on each processor.

!!! compat "Julia 1.1"
    This function requires at least Julia 1.1. In Julia 1.0 it is available from
    the standard library `InteractiveUtils`.
"""
function peakflops(n::Integer=2000; parallel::Bool=false)
    a = fill(1.,100,100)
    t = @elapsed a2 = a*a
    a = fill(1.,n,n)
    t = @elapsed a2 = a*a
    @assert a2[1,1] == n
    if parallel
        let Distributed = Base.require(Base.PkgId(
                Base.UUID((0x8ba89e20_285c_5b6f, 0x9357_94700520ee1b)), "Distributed"))
            return sum(Distributed.pmap(peakflops, fill(n, Distributed.nworkers())))
        end
    else
        return 2*Float64(n)^3 / t
    end
end


function versioninfo(io::IO=stdout)
    if Base.libblas_name == "libopenblas" || BLAS.vendor() === :openblas || BLAS.vendor() === :openblas64
        openblas_config = BLAS.openblas_get_config()
        println(io, "BLAS: libopenblas (", openblas_config, ")")
    else
        println(io, "BLAS: ",Base.libblas_name)
    end
    println(io, "LAPACK: ",Base.liblapack_name)
end

function __init__()
    try
        BLAS.check()
        if BLAS.vendor() === :mkl
            ccall((:MKL_Set_Interface_Layer, Base.libblas_name), Cvoid, (Cint,), USE_BLAS64 ? 1 : 0)
        end
        Threads.resize_nthreads!(Abuf)
        Threads.resize_nthreads!(Bbuf)
        Threads.resize_nthreads!(Cbuf)
    catch ex
        Base.showerror_nostdio(ex,
            "WARNING: Error during initialization of module LinearAlgebra")
    end
    # register a hook to disable BLAS threading
    Base.at_disable_library_threading(() -> BLAS.set_num_threads(1))
end

end # module LinearAlgebra
