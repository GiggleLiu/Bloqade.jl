export to_matrix, SimpleRydberg, subspace,
    RydbergHamiltonian, AbstractRydbergHamiltonian,
    evaluate_qaoa!

const ParameterType{T} = Union{T, Vector{T}} where {T <: Number}

"""
    subspace(n::Int, mis::Vector)

Create a subspace from given maximal independent set `mis`.
"""
function subspace(n::Int, mis::Vector)
    it = map(mis) do each
        fixed_points = setdiff(1:n, each)
        itercontrol(n, fixed_points, zero(fixed_points))
    end
    return sort(unique(Iterators.flatten(it)))
end

function subspace(graph::SimpleGraph)
    cg = complement(graph)
    mis = maximal_cliques(cg)
    n = nv(graph)
    subspace_v = subspace(n, mis)
end

getscalarmaybe(x::Vector, k) = x[k]
getscalarmaybe(x::Number, k) = x

"""
    sigma_x_term!(dst::AbstractMatrix{T}, n::Int, lhs, i, subspace_v, Ω, ϕ) where {T}

Sigma X term of the Rydberg Hamiltonian in MIS subspace:

```math
\\sum_{i=0}^n Ω_i (e^{iϕ_i})|0⟩⟨1| + e^{-iϕ_i}|1⟩⟨0|)
```
"""
function sigma_x_term!(dst::AbstractMatrix{T}, n::Int, lhs, i, subspace_v, Ω::ParameterType, ϕ::ParameterType) where {T}
    sigma_x = zero(T)
    for k in 1:n
        each_k = readbit(lhs, k)
        rhs = flip(lhs, 1 << (k - 1))
        # TODO: optimize this part by reusing node id
        # generated by creating subspace
        if rhs in subspace_v
            j = findfirst(isequal(rhs), subspace_v)
            if each_k == 0
                dst[i, j] = getscalarmaybe(Ω, k) * exp(im * getscalarmaybe(ϕ, k))
            else
                dst[i, j] = getscalarmaybe(Ω, k) * exp(-im * getscalarmaybe(ϕ, k))
            end
        end
    end
    return dst
end

"""
    sigma_z_term!(dst::AbstractMatrix{T}, n::Int, lhs, i, Δ) where {T <: Number}

Sigma Z term of the Rydberg Hamiltonian in MIS subspace.

```math
\\sum_{i=1}^n Δ_i σ_i^z
```
"""
function sigma_z_term!(dst::AbstractMatrix{T}, n::Int, lhs, i, Δ::ParameterType) where {T <: Number}
    sigma_z = zero(T)
    for k in 1:n
        if readbit(lhs, k) == 1
            sigma_z -= getscalarmaybe(Δ, k)
        else
            sigma_z += getscalarmaybe(Δ, k)
        end
    end
    dst[i, i] = sigma_z
    return dst
end

"""
    to_matrix!(dst::AbstractMatrix{T}, n::Int, subspace_v, Ω, ϕ[, Δ]) where T

Create a Rydberg Hamiltonian matrix from given parameters inplacely with blakable approximation.
The matrix is preallocated as `dst`.
"""
function to_matrix!(dst::AbstractMatrix, n::Int, subspace_v, Ω::ParameterType, ϕ::ParameterType, Δ::ParameterType)
    for (i, lhs) in enumerate(subspace_v)
        sigma_z_term!(dst, n, lhs, i, Δ)
        sigma_x_term!(dst, n, lhs, i, subspace_v, Ω, ϕ)
    end
    return dst
end

function to_matrix!(dst::AbstractMatrix, n::Int, subspace_v, Ω::ParameterType, ϕ::ParameterType)
    for (i, lhs) in enumerate(subspace_v)
        sigma_x_term!(dst, n, lhs, i, subspace_v, Ω, ϕ)
    end
    return dst
end

function to_matrix(graph, Ω::ParameterType, ϕ::ParameterType, Δ::ParameterType)
    n = nv(graph)
    subspace_v = subspace(graph)
    m = length(subspace_v)
    H = spzeros(ComplexF64, m, m)
    to_matrix!(H, n, subspace_v, Ω, ϕ, Δ)
    return Hermitian(H)
end

function to_matrix(graph, Ω::ParameterType, ϕ::ParameterType)
    n = nv(graph)
    subspace_v = subspace(graph)
    m = length(subspace_v)
    H = spzeros(ComplexF64, m, m)
    to_matrix!(H, n, subspace_v, Ω, ϕ)
    return Hermitian(H)
end

abstract type AbstractRydbergHamiltonian end

"""
    SimpleRydberg{T <: Number} <: AbstractRydbergHamiltonian

Simple Rydberg Hamiltonian, there is only one global parameter ϕ, and Δ=0, Ω=1.
"""
struct SimpleRydberg{T <: Number} <: AbstractRydbergHamiltonian
    ϕ::T
end

function Base.getproperty(x::SimpleRydberg{T}, name::Symbol) where T
    name == :Ω && return one(T)
    name == :Δ && return zero(T)
    return getfield(x, name)
end

# general case
struct RydbergHamiltonian{T <: Real, OmegaT <: ParameterType{T}, PhiT <: ParameterType{T}, DeltaT <: ParameterType{T}}
    C::T
    Ω::OmegaT
    ϕ::PhiT
    Δ::DeltaT
end

function to_matrix(h::AbstractRydbergHamiltonian, atoms::AtomPosition)
    g = unit_disk_graph(atoms)
    return to_matrix(g, h.Ω, h.ϕ, h.Δ)
end

function timestep!(st::Vector, h::AbstractRydbergHamiltonian, atoms, t::Float64, dt::Float64)
    H = to_matrix(h, atoms)
    return expv(-im * t, H, st)
end

"""
    evaluate_qaoa!(st::Vector{Complex{T}}, hs::Vector{<:AbstractRydbergHamiltonian}, n, subspace_v, ts::Vector{<:Real})

Evaluate a QAOA sequence `hs` along with parameters `ts` given initial state `st` and atom geometry `atoms`.
"""
function evaluate_qaoa! end

function evaluate_qaoa!(st::Vector{Complex{T}}, hs::Vector{SimpleRydberg{T}}, n::Int, subspace_v, ts::Vector{T}) where T
    m = length(subspace_v)
    H = spzeros(Complex{T}, m, m)
    
    # Krylov Subspace Cfg
    Ks_m = min(30, size(H, 1))
    Ks = KrylovSubspace{Complex{T}, T}(length(st), Ks_m)

    for (h, t) in zip(hs, ts)
        to_matrix!(H, n, subspace_v, one(T), h.ϕ)
        # qaoa step
        # NOTE: we share the Krylov subspace here since
        #       the Hamiltonians have the same shape
        arnoldi!(Ks, H, st; m=Ks_m, ishermitian=true)
        st = expv!(st, t, Ks)
        dropzeros!(fill!(H, zero(Complex{T})))
    end
    return st
end
