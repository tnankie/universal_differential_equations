cd(@__DIR__)
using Pkg; Pkg.activate("."); Pkg.instantiate()

# Single experiment, move to ensemble further on
# Some good parameter values are stored as comments right now
# because this is really good practice

using OrdinaryDiffEq
using ModelingToolkit
using DataDrivenDiffEq
using Flux, Tracker
using LinearAlgebra
using DiffEqFlux
using Plots
gr()



function lotka(du, u, p, t)
    α, β, γ, δ = p
    du[1] = α*u[1] - β*u[2]*u[1]
    du[2] = γ*u[1]*u[2]  - δ*u[2]
end

# Define the experimental parameter
# Empirical upper bound is 7
tspan = (0.0f0,3.0f0)
u0 = [0.44249296,4.6280594]
#p = Float32[0.5, 0.5, 0.7, 0.3]
p = Float32[1.3, 0.9, 0.5, 1.8]
prob = ODEProblem(lotka, u0,tspan, p)
solution = solve(prob, Vern7(), abstol=1e-12, reltol=1e-12, saveat = 0.1)
plot(solution)

# Initial condition and parameter for the Neural ODE
u0_ = Tracker.param(u0)
p_ = param(p)


# Define the neueral network which learns L(x, y, y(t-τ))
# Actually, we do not care about overfitting right now, since we want to
# extract the derivative information without numerical differentiation.
ann = Chain(Dense(2, 32,swish),Dense(32, 32, swish), Dense(32, 32, swish),Dense(32, 2)) |> f32
ann(u0_)

function dudt_(u,p,t)
    ann(u)
end

dudt_(u0_, p_, 0.0f0)

prob_ = ODEProblem(dudt_,u0_, tspan, p_)
s = diffeq_rd(p_, prob_, Tsit5())

plot(Flux.data.(s)')

function predict_rd()
    diffeq_rd(p_, prob_, Vern7(), saveat = solution.t, abstol=1e-6, reltol=1e-6)
end

function predict_rd(sol)
    diffeq_rd(p_, prob_, u0 = param(sol[:,1]), Vern7(),
              abstol=1e-6, reltol=1e-6,
              saveat = sol.t)
end

# No regularisation right now
loss_rd() = sum(abs2, solution[:,:] .- predict_rd()[:,:]) # + 1e-5*sum(sum.(abs, params(ann)))
loss_rd()

callback() = begin
    display(loss_rd())
end

opt = ADAM(3e-2)
# Train the neural DDE
Juno.@progress for i in 1:1000
    Flux.train!(loss_rd, params(ann), [()], opt, cb = callback)
end

opt = Descent(1e-4)
Juno.@progress for i in 1:10000
    Flux.train!(loss_rd, params(ann), [()], opt, cb = callback)
end

# Plot the data and the approximation
plot(solution.t, Flux.data.(predict_rd(solution)'))
plot!(solution.t, solution[:,:]')
loss_rd()
# Plot the error
plot(abs.(solution[:,:] .- Flux.data.(predict_rd()[:,:]))' .+ eps(Float32), yaxis = :log)

_sol = diffeq_rd(p_, prob_, Vern7(), saveat = 0.01, abstol=1e-8, reltol=1e-8)
fnnZ = Tracker.data.(_sol[:,:])
fnnL = Flux.data(ann(fnnZ))

# Get the analytical solution
fnnl1 = p[1]*fnnZ[1,:]-p[2]*fnnZ[1,:].*fnnZ[2,:]
fnnl2 = p[3]*fnnZ[1,:].*fnnZ[2,:] - p[4]*fnnZ[2,:]

# Plot L₂
plot3d(fnnZ[1,:], fnnZ[2,:],  fnnL[2,:])
plot3d!(fnnZ[1,:], fnnZ[2,:], fnnl2)

# Create a Basis
@variables u[1:2]

# Lots of polynomials
polys = [0u[1]]
for i ∈ 1:3

    push!(polys, u[1]^i)
    push!(polys, u[2]^i)

    for j ∈ i:3
        push!(polys, (u[1]^i)*(u[2]^j))
    end
end

# And some other stuff
h = [cos(u[1]); sin(u[1]); polys...]
fnnL̃ = [fnnl1'; fnnl2']
basis = Basis(h, u)
Ψ = SInDy(fnnZ[:, :], fnnL̃[:, :], basis, ϵ = 1e-1)
Ψ.basis


plot(hcat(Ψ.(eachcol(Z))...)')
plot!(L')


function approx(du, u, p, t)
    # Add SInDy Term
    du .= Ψ(u)
end

tspan = (0.0f0, 20.0f0)
a_prob = ODEProblem(approx, u0, tspan, p)
a_solution = solve(a_prob, Tsit5(), saveat = 0.1f0)

plot(solution, color = :blue)
plot!(a_solution, linestyle = :dash , color = :red, label = ["Estimation", ""])

using JLD2
@save "no_knowledge_NN.jld2" solution Ψ a_solution
