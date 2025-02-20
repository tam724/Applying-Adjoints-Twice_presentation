### A Pluto.jl notebook ###
# v0.19.41

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ 7e849952-e7f7-416c-b008-2078172dd26e
begin
	using Gridap, GridapGmsh
	using Plots, Interpolations , SparseArrays, Distributions, Pardiso, IterativeSolvers
	using PlutoUI, LinearAlgebra
	using Zygote, FiniteDifferences, Optim
	using Zygote: @adjoint
	using HypertextLiteral
	using Lux, Random, Optimisers, StatsFuns
end

# ╔═╡ dc9219f0-dbfe-42b5-b47b-10afd03b95b0
using BenchmarkTools

# ╔═╡ 91bd4b96-3381-401f-80c8-ab22b42ccd69
begin
	function assemble_bilinear(a, pars, U, V)
	    u = get_trial_fe_basis(U)
	    v = get_fe_basis(V)
	    matcontribs = a(u, v, pars...)
	    data = Gridap.FESpaces.collect_cell_matrix(U, V, matcontribs)
	    return assemble_matrix(SparseMatrixAssembler(U, V), data)
	end
	
	function assemble_linear(b, pars, U, V)
	    v = get_fe_basis(V)
	    veccontribs = b(v, pars...)
	    data = Gridap.FESpaces.collect_cell_vector(V, veccontribs)
	    return assemble_vector(SparseMatrixAssembler(U, V), data)
	end
end

# ╔═╡ aedee969-e868-4c4b-88dc-3eda6f05b8c3
function project_function(U, (dΩ, dΓ, n, α_h), f)
	op = AffineFEOperator((u, v) -> ∫(u*v)dΩ, v -> ∫(v*f)dΩ, U, U)
	return Gridap.solve(op)
end

# ╔═╡ f4fadc84-f802-11ee-20c1-e5e52daf6688
md"""
# Adjoint-Adjoint for the Poisson Equation (with implementation in Gridap)

We consider the following  problem:

$$-\nabla \cdot{} m(x) \nabla u^{(i)}(x) = 0 \quad \forall x \in \Omega$$
$$u^{(i)}(x) = g^{(i)}(x) \quad \forall x \in \partial \Omega$$
$$\Sigma^{(i, j)} = \int_{\Omega} \mu^{(j)}(x) u^{(i)}(x) dx$$
"""

# ╔═╡ 2f14bfb7-5811-4092-9675-cb9f80a8a16d
md"""
## Weak Form
Multiplication of the pde with a test function $v$ and integration leads (after integration by parts) to

$$\int_{\Omega}m\nabla u^{(i)} \cdot{} \nabla v \, dx - \int_{\partial \Omega} m \nabla_n u^{(i)} v \,d \Gamma = 0$$

We introduce a term to weakly enforce boundary conditions (bc. $(u^{(i)} - g^{(i)}) = 0$ at the boundary)
 
$$\int_{\Omega}m\nabla u^{(i)} \cdot{} \nabla v \, dx - \int_{\partial \Omega} m \nabla_n u^{(i)} v \,d \Gamma - \int_{\partial \Omega} (u^{(i)} - g^{(i)})\nabla_n v \, d\Gamma = 0$$

This leads to the following system: Find $u^{(i)} \in H^1(\Omega)$ s.t. 

$$a_m(u^{(i)}, v) + b^{(i)}(v) = 0 \quad \forall v \in H^1(\Omega)$$

where 

$$a_m(u^{(i)}, v) = \int_{\Omega}m\nabla u^{(i)} \cdot{} \nabla v \, dx -\int_{\partial \Omega} m \nabla_n u^{(i)} v + u^{(i)} \nabla_n v \,d \Gamma$$

and 

$$b^{(i)}(v) = \int_{\partial \Omega} g^{(i)} \nabla_n v \, d\Gamma$$

the extraction is given by the equation for $\Sigma^{(i, j)}$

$$\Sigma^{(i, j)} = c^{(j)}(u^{(i)}) = \int_{\Omega} \mu^{(j)}(x) u^{(i)}(x) \, dx$$
"""

# ╔═╡ 5e1cda6d-e06b-4160-9fb9-fe19125faccc
# first some function space definitions

# ╔═╡ 9631b4e0-9583-4b3d-863c-fb2a97b8c8de
∇ₙ(u, n) = dot(∇(u), n)

# ╔═╡ 982c4f4e-3ffe-48cd-8786-ffdc0d009c54
a_(u, v, m, (dΩ, dΓ, n, α_h)) = ∫(m*dot(∇(u), ∇(v)))dΩ - ∫(m*∇ₙ(u, n)*v + u*∇ₙ(v, n))dΓ + ∫(α_h * u * v)dΓ # nitsche trick (stabilization based in α_h)

# ╔═╡ ae53dffa-eee9-4ceb-8722-43eb95252a2e
dot_a_(u, v, m, dot_m, (dΩ, dΓ, n, α_h)) = ∫(dot_m*dot(∇(u), ∇(v)))dΩ
# dot_a_(u, v, m, dot_m, (dΩ, dΓ, n, α_h)) = ∫(dot_m*dot(∇(u), ∇(v)))dΩ - ∫(dot_m*∇ₙ(u, n)*v)dΓ

# ╔═╡ 4958b150-19b7-4a28-b88f-9087bdafaa0a
b_(v, m, g, (dΩ, dΓ, n, α_h)) = ∫(∇ₙ(v,  n)*g)dΓ - ∫(α_h * (g * v))dΓ # nitsche trick (stabilization based in α_h)

# ╔═╡ a552c91e-0aa6-4666-acd4-3b6d5a39176f
c_(u, m, μ, (dΩ, dΓ, n, α_h)) = ∫(μ*u)dΩ

# ╔═╡ 1dfee3b9-47da-43bb-9578-15a384c8654f
begin
	# dirchlet boundary
	measurement_angles = range(0, 2π, length=800)
	angle(x, y) = acos(dot(x, y) / sqrt(dot(x, x) / sqrt(dot(y, y))))
	g = tuple((x -> exp(-10.0*angle(x, (cos(θ), sin(θ)))^2) for θ in measurement_angles)...)

	# extraction function
	extraction_locations = [(0.5*cos(θ), 0.5*sin(θ)) for θ in range(0, 2π, length=7)[1:end-1]]
	push!(extraction_locations, (0.0, 0.0))
	# μ = tuple((x -> exp(-20.0*((x[1] - x_loc)^2 + (x[2] - y_loc)^2)) for (x_loc, y_loc) in extraction_locations)...)
	μ = tuple((x -> (((x[1] - x_loc)^2 + (x[2] - y_loc)^2) < 0.03) ? 1.0 : 0.0 for (x_loc, y_loc) in extraction_locations)...)
end

# ╔═╡ 605d877f-925e-42aa-9680-0046b30ec565
begin
	struct ModelFunction{Mspace, Uspace, Vspace, Mfunc, Omega, Pars}
		measurement_angles::Vector{Float64}
		extraction_locations::Vector{Tuple{Float64, Float64}}
	
		M::Mspace
		U::Uspace
		V::Vspace
		
		m::Mfunc
		
		A::SparseMatrixCSC{Float64}
		AT::SparseMatrixCSC{Float64}
		
		b::Matrix{Float64}
		c::Matrix{Float64}
		
		Ω::Omega
		pars::Pars

		temp_storage::Matrix{Float64}
	end
	
	function ModelFunction(measurement_angles, extraction_locations, grid_path)
		model = GmshDiscreteModel(joinpath(@__DIR__(), grid_path))
		order = 1
		refel = ReferenceFE(lagrangian, Float64, order)
		V = TestFESpace(model, refel, conformity=:H1)
		U = TrialFESpace(V)
		M = TestFESpace(model, ReferenceFE(lagrangian, Float64, 0), conformity=:L2)
		
		Ω = Triangulation(model)
		dΩ = Measure(Ω, order + 1)
		Γ = BoundaryTriangulation(model)
		dΓ = Measure(Γ, order + 1)
		n = get_normal_vector(Γ)

		# nietsche coefficient 10 / cell radius
		α_h = 10.0/(sqrt(π/num_free_dofs(M))) # TODO!
		#∫(FEFunction(FF.M, ones(num_free_dofs(FF.M))))*FF.pars.dΩ)[FF.Ω][:]
		pars = (dΩ=dΩ, dΓ=dΓ, n=n, α_h=α_h)
		
		m = FEFunction(M, ones(num_free_dofs(M)))
		
		A = assemble_bilinear(a_, (m, pars), U, V)
		AT = transpose(A)
		excitations = hcat([assemble_linear(b_, (m, g[i], pars), U, V) for i in 1:length(measurement_angles)]...)
		extractions = hcat([assemble_linear(c_, (m, μ[i], pars), U, V) for i in 1:length(extraction_locations)]...)
		
		return ModelFunction{typeof(M), typeof(U), typeof(V), typeof(m), typeof(Ω), typeof(pars)}(
			measurement_angles, extraction_locations, M, U, V, m, A, AT, excitations, extractions, Ω, pars, zeros(num_free_dofs(V), length(extraction_locations)))
	end
	
	function set_params!(f, p)
		f.m.free_values .= p
		f.A .= assemble_bilinear(a_, (f.m, f.pars), f.U, f.V)
		f.AT .= transpose(f.A)
		# for i in 1:length(f.measurement_angles)
		# 	f.b[:, i] .= assemble_linear(b_, (m(f.pp), g[i], f.pars), f.U, f.V)
		# end
	end

	function solve_forward(f, p, slow=false)
		set_params!(f, p)
		solutions = Matrix{Float64}(undef, num_free_dofs(f.U), length(f.measurement_angles))
		if slow
			for i in 1:length(f.measurement_angles)
				sol, log = idrs!(solutions[:, i], f.A, -f.b[:, i], log=true)
				 # .= sol
				# @show log
			end
		else
			ps = MKLPardisoSolver()
			Pardiso.solve!(ps, solutions, f.A, -f.b)
		end
		return [FEFunction(f.U, solutions[:, i]) for i in 1:length(f.measurement_angles)]
	end

	function solve_adjoint(f, p)
		set_params!(f, p)
		solutions = Matrix{Float64}(undef, num_free_dofs(f.U), length(f.extraction_locations))
		ps = MKLPardisoSolver()
		Pardiso.solve!(ps, solutions, f.AT, -f.c)
		return [FEFunction(f.U, solutions[:, i]) for i in 1:length(f.extraction_locations)]
	end

	function measure_forward(f::ModelFunction, p)
		set_params!(f, p)
		solutions = zeros(num_free_dofs(f.U), length(f.measurement_angles))
		measurements = Matrix{Float64}(undef, length(f.measurement_angles), length(f.extraction_locations))
		for i in 1:length(f.measurement_angles)
			sol, log = bicgstabl(f.A, -f.b[:, i], log=true, max_mv_products=2*size(f.A, 2))
			solutions[:, i] .= sol
		end
		mul!(measurements, solutions', f.c)
		return measurements
	end

	function (f::ModelFunction)(p)
		set_params!(f, p)
		# allocate
		solutions_adjoint = zeros(num_free_dofs(f.U), length(f.extraction_locations))
		# solutions_adjoint = Matrix{Float64}(undef, num_free_dofs(f.U), length(f.extraction_locations))
		measurements = Matrix{Float64}(undef, length(f.measurement_angles), length(f.extraction_locations))
		#solve
		for i in 1:length(f.extraction_locations)
			sol_, log = bicgstabl(f.AT, -f.c[:, i], log=true, max_mv_products=2*size(f.A, 2))
			solutions_adjoint[:, i] .= sol_
			# @show log
		end
		mul!(measurements, f.b', solutions_adjoint)
		return measurements
	end
	
	Zygote.@adjoint function (f::ModelFunction)(p)
		set_params!(f, p)
		# allocate
		solutions_adjoint = zeros(num_free_dofs(f.U), length(f.extraction_locations))
		measurements = Matrix{Float64}(undef, length(f.measurement_angles), length(f.extraction_locations))
		#solve
		for i in 1:length(f.extraction_locations)
			sol_, log = bicgstabl(f.AT, -f.c[:, i], log=true, max_mv_products=2*size(f.A, 2))
			solutions_adjoint[:, i] .= sol_
			# @show log
		end
		# gmres(f.AT, -f.c)
		mul!(measurements, f.b', solutions_adjoint)

		function f_pullback(measurements_)
			source_adjoint = f.b * measurements_
			solutions_adjoint_gradient = zeros(num_free_dofs(f.U), length(f.extraction_locations))
			for i in 1:length(f.extraction_locations)
				sol_, log = bicgstabl(f.A, -source_adjoint[:, i], log=true, max_mv_products=2*size(f.A, 2))
				solutions_adjoint_gradient[:, i] = sol_
				# @show log 
			end
			# Pardiso.solve!(ps, solutions_adjoint_gradient, f.A, -source_adjoint)
			f.temp_storage .= solutions_adjoint_gradient
			
			M_ = TrialFESpace(f.M)
			grad_vals = zeros(num_free_dofs(f.M))
			for i in 1:length(extraction_locations)
				bar_u = FEFunction(f.U, solutions_adjoint_gradient[:, i])
				λ = FEFunction(f.U, solutions_adjoint[:, i])

				op = AffineFEOperator(
					(u_m, v_m) -> ∫(u_m*v_m)f.pars.dΩ, 
					v_m -> dot_a_(bar_u, λ, f.m, v_m, f.pars),
					#v_m -> dot_a(f.pp)(bar_u, λ, v_m, pars),
					M_, f.M)
				grad = Gridap.solve(op)
				grad_vals += grad.free_values
			end
			return (nothing, grad_vals, )
		end
		return measurements, f_pullback
	end
end

# ╔═╡ 8700eb22-d2f5-4750-8fb9-51d443f16422
begin
	# FF_highres = ModelFunction(measurement_angles, extraction_locations, "circle_fine.msh")
	FF_true = ModelFunction(measurement_angles, extraction_locations, "circle_middle.msh")
	FF = ModelFunction(measurement_angles, extraction_locations, "circle_middle.msh")
end

# ╔═╡ 7c7c6bde-3e75-4c49-ab18-87f28a7db82c
begin
		true_m_func(x) = exp(-10.0*(cos(0.9)*x[1] + sin(0.9)*x[2])^2)*0.4 + 0.4
		p_true = (μ1=0.0, μ2=-0.3, r=π/4, a=0.3, b=0.8)
		p_true2 = (μ1=-0.4, μ2=0.4, r=-π/4, a=0.2, b=1.0)
		is_in_ellipse(x, p_true) = ((x[1] - p_true.μ1)*cos(p_true.r) + (x[2] - p_true.μ2)*sin(p_true.r))^2/p_true.a^2 + ((x[1] - p_true.μ1)*sin(p_true.r) - (x[2] - p_true.μ2)*cos(p_true.r))^2/p_true.b^2 < 1.0
		function true_m_func(x)
			if is_in_ellipse(x, p_true)
				return 0.9
			elseif x[2] > 0.0 # is_in_ellipse(x, p_true2)
				return 0.1
			else
				return 0.4
			end
		end
		#true_m_func(x) = (x[1] > 0.0 && x[2] > -0.5 && x[2] < 0.5) ? 0.8 : 0.2
		true_m_pars = project_function(FF_true.M, FF_true.pars, true_m_func).free_values
		true_measurements = FF_true(true_m_pars)
		true_measurements .*= 1.0 .+ 0.01.*randn(size(true_measurements))
	
		squared_error(p) = sum((FF(p) .- true_measurements).^2)
end

# ╔═╡ 1fb005ba-ba3c-40da-8132-86bd9368a210
meas = measure_forward(FF_true, true_m_pars)

# ╔═╡ 280ea22e-eef9-436a-bd1f-a9fc1b640437
FF_true(true_m_pars)

# ╔═╡ 5cbcdb73-437c-435f-8d34-efeb2a69926e
function plot_solution(sol, clims=extrema(sol.free_values), res=60, rev=false)
	gr()
	g = x -> sol(x / norm(x)*0.99)
	vis(x, y) = sqrt(x*x + y*y) >= 1.0 ? g(Point(x, y)) : sol(Point(x, y))
	scale_point(x) = (sqrt(x[1]*x[1] + x[2]*x[2]) >= 1.0) ? x / norm(x) * 0.99 : x
	cmap=cgrad(:thermal, rev=rev)
	xpoints = range(-1.0, 1.0, length=res)
	ypoints = range(-1.0, 1.0, length=res)

	points = scale_point.(Point.(xpoints', ypoints))[:]
	z = reshape(sol(points), (res, res))
	contourf(xpoints, ypoints, z, aspect_ratio=:equal, cmap=cmap, clims=clims, linewidth=0, levels=30, grid=:none, right_margin=5Plots.mm)
	plot!(1.3*sin.(0:0.05:2π), 1.3*cos.(0:0.05:2π), color=:white, label=nothing, linewidth=94) #, linecolor=get.(Ref(cgrad(:thermal)), g.(Point.(sin.(0:0.01:2π), cos.(0:0.01:2π)))), linewidth=3)
	scale(x, clims) = (x - clims[1])/(clims[2] - clims[1])
	p = plot!(sin.(0:0.02:2π), cos.(0:0.02:2π), color=:black, label=nothing, linecolor=get.(Ref(cgrad(cmap)), scale.(g.(Point.(sin.(0:0.02:2π), cos.(0:0.02:2π))), Ref(clims))), linewidth=3)
	xlabel!("x")
	ylabel!("y")
	xlims!(-1.1, 1.1)
	ylims!(-1.1, 1.1)
	return p
end

# ╔═╡ 0dcbb440-b3af-450d-98f4-2f39acc87ab2
let
	p = plot_solution(FEFunction(FF_true.M, true_m_pars), (0, 1))
	plot!(size=(480, 480))
	# savefig("claus_applying_adjoints_twice_presentation/figures/poisson/true_material.svg")
	@htl("<table><tr><th>true_material</th></tr><tr><th>$(p)</th></tr></table>")
end

# ╔═╡ a17d22f8-c625-4b3f-a235-369cb5fb655d
begin
	sols = solve_forward(FF_true, true_m_pars, false)
	measurements = FF_true(true_m_pars)
end

# ╔═╡ fc00caf8-a1b1-4153-9b3c-f127b0aed0d7
let
	#sol = solve_forward(FF_true, true_m_pars, false)
	#sol2 = solve_forward(FF_true, true_m_pars, true)
	@btime FF_true(true_m_pars)
end

# ╔═╡ 1cc2d2b1-b711-45db-a661-07c77fe6cb77
# ╠═╡ disabled = true
#=╠═╡
let
	for i in 1:length(measurement_angles)
		p1 = plot_solution(sols[i], (0, 1))
		p1 = plot!([1.0, 0.0, cos(FF.measurement_angles[i])], [0.0, 0.0, sin(FF.measurement_angles[i])], color=:gray, label=nothing)
		p1 = plot!(size=(480, 480))
		p1 = plot!(0.1.*cos.(0:0.01:FF.measurement_angles[i]), 0.1.*sin.(0:0.01:FF.measurement_angles[i]), color=:gray, label=nothing)
		p1 = annotate!(0.2*cos(FF.measurement_angles[i] / 2.0), 0.2*sin(FF.measurement_angles[i] / 2.0), "θ", :gray, label=nothing)
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/forward_solution/$(i).svg")
	end
	
	for i in 1:length(extraction_locations)
		p2 = plot(FF.measurement_angles, measurements[:, i], size=(430, 430), label="measurements (extraction:$(i))")
		# p2 = vline!([FF.measurement_angles[i_measurement_angle]], label="θ", color=:gray)
		xlabel!("θ")
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/measurements/$(i).svg")
	end

	p3 = plot()
	for i in 1:length(extraction_locations)
		p3 = plot!(FF.measurement_angles, measurements[:, i], size=(430, 430), label="measurements (extraction:$(i))")		
		# p2 = vline!([FF.measurement_angles[i_measurement_angle]], label="θ", color=:gray)
	end
	xlabel!("θ")
	plot!(right_margin = 5Plots.mm)
	savefig("claus_applying_adjoints_twice_presentation/figures/poisson/all_measurements.svg")

	p10 = plot()
	for i in 1:length(extraction_locations)
		p10 = plot!(FF_true.measurement_angles, meas[:, i], size=(430, 430), label="measurements (extraction:$(i))")
		# p2 = vline!([FF.measurement_angles[i_measurement_angle]], label="θ", color=:gray)
	end
	xlabel!("θ")
	plot!(right_margin = 5Plots.mm)
	savefig("claus_applying_adjoints_twice_presentation/figures/poisson/all_measurements_forward.svg")

	for i in 1:length(extraction_locations)
		p1 = plot_solution(Gridap.interpolate(μ[i], FF_highres.U))
		plot!(size=(480, 480))
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/extractions/$(i).svg")

		p2 = plot_solution(sols_a[i])
		plot!(size=(480, 480))
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/forward_adjoint/$(i).svg")

		p3 = plot_solution(FEFunction(FF.V, FF.temp_storage[:, i]))
		plot!(size=(480, 480))
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/derivative_adjoint/$(i).svg")
	end

	p4 = plot_solution(FEFunction(FF.M, grad[1]))
	plot!(size=(480, 480))
	plot!(right_margin = 5Plots.mm)
	savefig("claus_applying_adjoints_twice_presentation/figures/poisson/gradient.svg")

	p4 = plot_solution(FEFunction(FF.M, grad_fd2 ./ volumes))
	plot!(size=(480, 480))
	plot!(right_margin = 5Plots.mm)
	savefig("claus_applying_adjoints_twice_presentation/figures/poisson/gradient_fd.svg")
end
  ╠═╡ =#

# ╔═╡ f20bdad5-eeda-44ab-8fb7-97407dbbf4b4
# new plots
let
	# for i in 1:length(measurement_angles)
	# 	p1 = plot_solution(sols[i], (0, 1))
	# 	p1 = plot!([1.0, 0.0, cos(FF.measurement_angles[i])], [0.0, 0.0, sin(FF.measurement_angles[i])], color=:gray, label=nothing)
	# 	p1 = plot!(size=(480, 480))
	# 	p1 = plot!(0.1.*cos.(0:0.01:FF.measurement_angles[i]), 0.1.*sin.(0:0.01:FF.measurement_angles[i]), color=:gray, label=nothing)
	# 	p1 = annotate!(0.2*cos(FF.measurement_angles[i] / 2.0), 0.2*sin(FF.measurement_angles[i] / 2.0), "θ", :gray, label=nothing)
	# 	for (x_loc, y_loc) in extraction_locations
	# 		plot!(x_loc .+ sqrt(0.03).*cos.(0:0.01:2π), y_loc .+ sqrt(0.03).*sin.(0:0.01:2π), color=:gray, label=nothing)
	# 	end
	# 	plot!()
	# 	plot!(right_margin = 5Plots.mm)
	# 	savefig("claus_applying_adjoints_twice_presentation/figures/poisson2/forward_solution/$(lpad(i, 3, "0")).svg")
	# end

	for i in 1:length(extraction_locations)
		# p2 = plot_solution(sols_a[i], (-0.25, 0.0), 60, true)
		# plot!(size=(480, 480))
		# plot!(right_margin = 5Plots.mm)
		# for (x_loc, y_loc) in extraction_locations
		# 	plot!(x_loc .+ sqrt(0.03).*cos.(0:0.01:2π), y_loc .+ sqrt(0.03).*sin.(0:0.01:2π), color=:gray, label=nothing)
		# end
		# savefig("claus_applying_adjoints_twice_presentation/figures/poisson/forward_adjoint2/$(i).svg")

		p3 = plot_solution(FEFunction(FF.V, FF.temp_storage[:, i]), (-1.3, 1.2))
		plot!(size=(480, 480))
		plot!(right_margin = 5Plots.mm)
		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/derivative_adjoint2/$(i).svg")
	end
	plot!()
end

# ╔═╡ 9317ca6a-04e9-49f0-b66b-41e179ff9228
cgrad(:default, rev=true)

# ╔═╡ d0464f28-06df-4237-8de8-63cc7cd886b3
lpad

# ╔═╡ 3f92bb62-00e4-4e7f-8be4-e9a23acb8f56
extraction_locations

# ╔═╡ 79f5d795-1da0-4a7a-8657-fd7d492a9d8c
@htl("<h3>choose measurement angle</h3> $(@bind i_measurement_angle Slider(1:length(measurement_angles)))")

# ╔═╡ 2a71be41-20f8-4e3b-9981-066458639ba4
sols_a = solve_adjoint(FF_true, true_m_pars)

# ╔═╡ f2f37ad9-f24a-4423-99a1-44fe1bd287b8
@htl("<h3>choose extraction location</h3> $(@bind i_extraction_location Slider(1:length(extraction_locations)))")

# ╔═╡ 4ee2f3ce-72c7-4740-81e5-9e48c3b58e30
let
	p1 = plot_solution(sols[i_measurement_angle])
	p1 = plot!([1.0, 0.0, cos(FF.measurement_angles[i_measurement_angle])], [0.0, 0.0, sin(FF.measurement_angles[i_measurement_angle])], color=:gray, label=nothing)
	p1 = plot!(size=(480, 480))
	p1 = plot!(0.1.*cos.(0:0.01:FF.measurement_angles[i_measurement_angle]), 0.1.*sin.(0:0.01:FF.measurement_angles[i_measurement_angle]), color=:gray, label=nothing)
	p1 = annotate!(0.2*cos(FF.measurement_angles[i_measurement_angle] / 2.0), 0.2*sin(FF.measurement_angles[i_measurement_angle] / 2.0), "θ", :gray, label=nothing)

	# θ = 0:0.01:2π
	# gs = [g[i_measurement_angle]([x, y]) for (x, y) ∈ zip(cos.(θ), sin.(θ))]
	# p1 = plot!(cos.(θ).*(1.01 .+ gs*0.1), sin.(θ).*(1.01 .+ gs*0.1), aspect_ratio=:equal)
	
	p2 = plot()
	for i in (1:length(extraction_locations))[i_extraction_location:i_extraction_location]
		p2 = plot!(FF.measurement_angles, measurements[:, i], size=(430, 430), label="measurements $(i)")
	end
	p2 = vline!([FF.measurement_angles[i_measurement_angle]], label="θ", color=:gray)
	xlabel!("θ")
	@htl("<table><tr><th>forward solution</th><th>measurements</th></tr><tr><th>$(p1)</th><th>$(p2)</th></tr></table>")
end

# ╔═╡ d0e5e872-0ba6-4019-8133-380b442d223c
i_extraction_location

# ╔═╡ bf70a619-509a-424e-9f55-77cf99df7d55
let
	p1 = plot_solution(FEFunction(FF_true.U, FF_true.c[:, i_extraction_location]))
	p2 = plot_solution(sols_a[i_extraction_location])
	@htl("<table><tr><th>extraction</th><th>adjoint solution</th></tr><tr><th>$(p1)</th><th>$(p2)</th></tr></table>")
end

# ╔═╡ 79b34a3e-02fd-4888-927f-fa552b55e44e
val, grad = Zygote.withgradient(squared_error, 0.5*ones(num_free_dofs(FF.M)))

# ╔═╡ 1aa9d66a-00f3-4a95-a37b-25066b790460
let
	p1 = plot_solution(FEFunction(FF.M, grad[1]))
	@htl("<table><tr><th>gradient of squared error</th></tr><tr><th>$(p1)</th></tr></table>")
end

# ╔═╡ 77478768-20be-4b40-a491-4eff4c2aeb5c
let
	p1 = plot_solution(FEFunction(FF.V, FF.temp_storage[:, i_extraction_location]))
	@htl("<table><tr><th>solution of the adjoint-adjoint</th></tr><tr><th>$(p1)</th></tr></table>")
end

# ╔═╡ b92ad479-953d-44cf-9983-c0b808ee370b
function finite_differences(f, p, h)
	val0 = f(p)
	grad = zeros(size(p))
	for i in 1:length(p)
		p_ = copy(p)
		p_[i] += h
		grad[i] = (f(p_) - val0)/h
	end
	return grad
end

# ╔═╡ 8c419a5c-f98e-4a55-86c1-d1442e492a32
num_free_dofs(FF.M)

# ╔═╡ 9f450eca-40bf-4d41-ba2e-de7ee336813d
squared_error(0.5*ones(num_free_dofs(FF.M)))

# ╔═╡ 24a7fd22-4169-4cb1-a038-8e3864cd5079
# ╠═╡ disabled = true
#=╠═╡
grad_fd2 = finite_differences(squared_error, 0.5*ones(num_free_dofs(FF.M)), 0.001)
  ╠═╡ =#

# ╔═╡ 8eb9aac0-0999-4e43-b4cb-6ff9724c9d7c
#=╠═╡
let
	p2 = plot_solution(FEFunction(FF.M, grad_fd2 ./ volumes))
	p1 = plot_solution(FEFunction(FF.M, grad[1]))
	@htl("<table><tr><th>gradient of squared error</th><th>gradient finite differences</th></tr><tr><th>$(p1)</th><th>$(p2)</th></tr></table>")
end
  ╠═╡ =#

# ╔═╡ 21fb6e44-a465-4a75-8ad6-f8b52540edbc
# ╠═╡ disabled = true
#=╠═╡
begin
	p4 = plot_solution(FEFunction(FF.M, grad_fd2 ./ volumes))
	plot!(size=(480, 480))
	savefig("claus_applying_adjoints_twice_presentation/figures/poisson/gradient_fd.svg")
end
  ╠═╡ =#

# ╔═╡ 39a88b33-438f-4b42-b5f4-011eb11f7521
begin
	volumes = (∫(FEFunction(FF.M, ones(num_free_dofs(FF.M))))*FF.pars.dΩ)[FF.Ω][:]
end

# ╔═╡ 8a15d18c-b7da-4cb2-83ca-9f2c11d427bf
begin
	p_trans1(p) = 0.5.*tanh.(p) .+ 0.5

	x_coords = [x[1] for x = mean.(Gridap.get_cell_coordinates(FF.M.fe_basis.trian.grid))]
	y_coords = [x[2] for x = mean.(Gridap.get_cell_coordinates(FF.M.fe_basis.trian.grid))]

	xy = Float32.(Matrix(hcat([[0.5*(x_coords[i]+1), 0.5*(y_coords[i]+1)] for i in 1:length(x_coords)]...)))

	function parametrization2(x, y, (μ1, μ2, r, a, b, ρ, z))
		return StatsFuns.logistic(z*((((x - μ1)*cos(r) + (y - μ2)*sin(r))^2 / a^2 + ((x - μ1)*sin(r) - (y - μ2)*cos(r))^2 / b^2) - 1.0)) * StatsFuns.logistic(ρ) + (1.0 - StatsFuns.logistic(z*((((x - μ1)*cos(r) + (y - μ2)*sin(r))^2 / a^2 + ((x - μ1)*sin(r) - (y - μ2)*cos(r))^2 / b^2) - 1.0)))*(1.0 - StatsFuns.logistic(ρ))
	end
	
	function p_trans2(p)
		return parametrization2.(x_coords, y_coords, Ref(tuple(p...)))
	end

	struct MyLayer <: Lux.AbstractExplicitLayer end


	Lux.initialparameters(::AbstractRNG, layer::MyLayer) = (p=randn(Float32, 1), )
	Lux.initialstates(::AbstractRNG, layer::MyLayer) = (vals = Float32[0.1 0.9 0.4], )

	(l::MyLayer)(x, ps, st) = st.vals * x, st
	#(l::MyLayer)(x, ps, st) = x[1]*Lux.sigmoid(ps.p[1]) + x[2]*(1.0 - Lux.sigmoid(ps.p[1])), st

	
	struct FourierLayer <: Lux.AbstractExplicitLayer end

	Lux.initialparameters(::AbstractRNG, layer::FourierLayer) = ()
	Lux.initialstates(::AbstractRNG, layer::FourierLayer) = (bs = rand(Float32, 20, 2), )

	function (l::FourierLayer)(x, ps, st)
		# res = [cos.(Float32(2.0*π) .* (st.bs * x))
		# 	sin.(Float32(2.0*π) .* (st.bs * x))]
		res = cos.(Float32(2.0*π) .* (st.bs * x))
		return res, st
	end
	
	struct NNTrans
		model
		st
		re
	end

	function create_NNTrans()
		model = Chain(Dense(2, 20, tanh), Dense(20, 20, tanh), Dense(20, 3), Lux.softmax, MyLayer())
		#model = Chain(FourierLayer(), Dense(20, 20, tanh), Dense(20, 3), Lux.softmax, MyLayer())
		ps, st = Lux.setup(Random.default_rng(), model)
		vec, re = Optimisers.destructure(ps)
		return vec, NNTrans(model, st, re)
	end

	function material(trans::NNTrans, p, x)
		ps = trans.re(p)
		y = first(Lux.apply(trans.model, x, ps, trans.st))
		return y
	end
	
	function (trans::NNTrans)(p)
		ps = trans.re(p)
		y = first(Lux.apply(trans.model, xy, ps, trans.st))
		return y[:]
	end
	
	p02, p_trans3 = create_NNTrans()

	exp_trans(p) = exp.(p)

	p_trans = exp_trans
	
	objective(p) = squared_error(p_trans(p))# + 0.01*l2(p)
	function objective_g!(g, p)
		g .= [Zygote.gradient(objective, p)[1]...]
	end
end

# ╔═╡ 6050d1d1-71ab-4d27-a25e-47e8b6b7ad77
begin
	import Optim: common_trace!
	# quick hack to make adam run.
	function common_trace!(tr, d, state, iteration, method::Optim.FirstOrderOptimizer, options, curr_time=time())
	    dt = Dict()
	    dt["time"] = curr_time
	    if options.extended_trace
	        dt["x"] = copy(state.x)
	        dt["g(x)"] = copy(Optim.gradient(d))
	        #dt["Current step size"] = state.alpha
	    end
	    g_norm = maximum(abs, Optim.gradient(d))
	    Optim.update!(tr,
	            iteration,
	            Optim.value(d),
	            g_norm,
	            dt,
	            options.store_trace,
	            options.show_trace,
	            options.show_every,
	            options.callback)
	end
end

# ╔═╡ d52e3930-82ee-4e69-8569-da89ff44bf56
# ╠═╡ disabled = true
#=╠═╡
begin
	p0 = Optimisers.destructure(Lux.setup(Random.default_rng(), p_trans3.model)[1])[1]
	Lux.trainmode(p_trans3.st)
	#p0 = [0.0, 0.0, 0.5, 0.5, 0.5, 0.0, -1]
	res = optimize(objective, objective_g!, p0, Optim.LBFGS(), Optim.Options(store_trace=true, extended_trace=true, iterations=2000, time_limit=200, g_abstol=1e-3, g_reltol=1e-3))
	Lux.testmode(p_trans3.st)
	res
end
  ╠═╡ =#

# ╔═╡ 2156d0cf-6ffb-4920-8217-f8e581428a12
@htl("<h3>choose optimization iteration</h3> $(@bind i_opti Slider(1:length(res.trace), default=length(res.trace)))")

# ╔═╡ cd53e724-62d6-4b53-9501-307f7dae419c
#=╠═╡
let
	measurements = FF(p_trans(res.trace[i_opti].metadata["x"]))
	p1 = plot(size=(480, 370))
	for i in 1:length(extraction_locations)
		p1 = plot!(measurements[:, i], color=i, label=nothing)
		p1 = plot!(true_measurements[:, i], color=i, ls=:dash, label=nothing)
	end

	p_i_opti = (
		μ1 = res.trace[i_opti].metadata["x"][1],
		μ2 = res.trace[i_opti].metadata["x"][2],
		r = res.trace[i_opti].metadata["x"][3],
		a = res.trace[i_opti].metadata["x"][4],
		b = res.trace[i_opti].metadata["x"][5],
		ρ = res.trace[i_opti].metadata["x"][6],
		z = res.trace[i_opti].metadata["x"][7],
	)
	
	p2 = plot_solution(FEFunction(FF.M, Float64.(p_trans(res.trace[i_opti].metadata["x"]))), (0, 1), 80)
	#p2 = scatter!([p_i_opti.μ1], [p_i_opti.μ2], color=:black)
	#p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.a*cos(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 + p_i_opti.a*sin(p_i_opti.r)], color=:black)
	#p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.b*sin(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 -p_i_opti.b*cos(p_i_opti.r)], color=:black)
	p2 = plot!(size=(480, 480))
	p3 = plot_solution(FEFunction(FF_true.M, true_m_pars), (0, 1), 80)
	# p3 = scatter!([p_true[1]], [p_true[2]])
	
	p3 = plot!(size=(480, 480))

	@htl("<table><tr><th>optimized measurements</th><th>optimized material</th><th>true material</th></tr><tr><th>$(p1)</th><th>$(p2)</th><th>$(p3)</th></tr></table>")
end
  ╠═╡ =#

# ╔═╡ 88f5488a-a0d9-4ca0-8158-5d3a0433385f
#=╠═╡
p_trans(res.trace[i_opti].metadata["x"])
  ╠═╡ =#

# ╔═╡ f271d049-9cb1-47b7-af74-31f83898aebd
#=╠═╡
res.trace[1]
  ╠═╡ =#

# ╔═╡ 563a57bc-af31-47bd-a84a-4308a7372a3d
# ╠═╡ disabled = true
#=╠═╡
let
	obj = [objective(s.metadata["x"]) for s in res.trace[1:200]]
	
	for j in 1:200
		measurements = FF(p_trans(res.trace[j].metadata["x"]))
		# p1 = plot(size=(480, 370))
		# for i in 1:length(extraction_locations)
		# 	p1 = plot!(measurements[:, i], color=i, label=nothing)
		# 	p1 = plot!(true_measurements[:, i], color=i, ls=:dash, label=nothing)
		# end
		# savefig("claus_applying_adjoints_twice_presentation/figures/poisson/optimization_measurements/$(lpad(j, 3, "0")).svg")

		p3 = plot(obj, size=(480, 370), label=error, yaxis=:log)
		p3 = vline!([j], color=:gray, label=nothing)
		p3 = xlabel!("iteration")

		savefig("claus_applying_adjoints_twice_presentation/figures/poisson/optimization_error/$(lpad(j, 3, "0")).svg")
		
		# p2 = plot_solution(FEFunction(FF.M, Float64.(p_trans(res.trace[j].metadata["x"]))), (0, 1), 80)
		# #p2 = scatter!([p_i_opti.μ1], [p_i_opti.μ2], color=:black)
		# #p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.a*cos(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 + p_i_opti.a*sin(p_i_opti.r)], color=:black)
		# #p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.b*sin(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 -p_i_opti.b*cos(p_i_opti.r)], color=:black)
		# p2 = plot!(size=(480, 480))
		# savefig("claus_applying_adjoints_twice_presentation/figures/poisson/optimization_material/$(lpad(j, 3, "0")).svg")
	end
end
  ╠═╡ =#

# ╔═╡ 840ebab9-8c5a-40cd-9b58-313b56dfd79f
#=╠═╡
material(p_trans3, res.minimizer, [0.0, 0.0])
  ╠═╡ =#

# ╔═╡ 4ffad3ed-d91c-4d2f-ba45-9cc3d83ebfee
#=╠═╡
contourf(0:0.01:1, 0:0.01:1, (x, y) -> material(p_trans3, res.minimizer, [x, y])[1], clims=(0, 1), aspect_ratio=:equal, linewidth=0)
  ╠═╡ =#

# ╔═╡ 5dd8f3b3-f412-4b86-834b-86b43ab35f2a
# ╠═╡ disabled = true
#=╠═╡
let
	@gif for i_opti in 1:length(res.trace)
		measurements = FF(p_trans(res.trace[i_opti].metadata["x"]))
		p1 = plot(size=(480, 370))
		for i in 1:length(extraction_locations)
			p1 = plot!(measurements[:, i], color=i, label=nothing)
			p1 = plot!(true_measurements[:, i], color=i, ls=:dash, label=nothing)
		end
		
		p2 = plot_solution(FEFunction(FF.M, p_trans(res.trace[i_opti].metadata["x"])), (0, 1), 50)
		#p2 = scatter!([p_i_opti.μ1], [p_i_opti.μ2], color=:black)
		#p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.a*cos(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 + p_i_opti.a*sin(p_i_opti.r)], color=:black)
		#p2 = plot!([p_i_opti.μ1, p_i_opti.μ1 + p_i_opti.b*sin(p_i_opti.r)], [p_i_opti.μ2, p_i_opti.μ2 -p_i_opti.b*cos(p_i_opti.r)], color=:black)
		p2 = plot!(size=(480, 480))
		p3 = plot_solution(FEFunction(FF_true.M, true_m_pars), (0, 1), 50)
		# p3 = scatter!([p_true[1]], [p_true[2]])
		
		p3 = plot!(size=(480, 480))
		plot(p1, p2, p3, layout=(1, 3), size=(3*650, 480))
	end
end
  ╠═╡ =#

# ╔═╡ f6ff0f0b-05f2-42e4-ae86-1672f017edf9
#=╠═╡
let
	measurements = FF(p_trans(res.trace[i_opti].metadata["x"]))
	p1 = plot(size=(480, 370))
	for i in 1:length(extraction_locations)
		p1 = plot!(measurements[:, i] .- true_measurements[:, i], color=i, label=nothing)
	end
	
	p2 = plot_solution(x -> FEFunction(FF_true.M, true_m_pars)(x) - FEFunction(FF.M, p_trans(res.trace[i_opti].metadata["x"]))(x), (-0.5, 0.5))
	p2 = plot!(size=(480, 480))

	@htl("<table><tr><th>measurement residuals</th><th>material residuals</th></tr><tr><th>$(p1)</th><th>$(p2)</th></tr></table>")
end
  ╠═╡ =#

# ╔═╡ e4928bb3-70d2-4dc2-a56a-eac2a01b2dca
html"""<style>
main {
    max-width: 1600px;
}
"""

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
Distributions = "31c24e10-a181-5473-b8eb-7969acd0382f"
FiniteDifferences = "26cc04aa-876d-5657-8c51-4c34ba976000"
Gridap = "56d4f2e9-7ea1-5844-9cf6-b9c51ca7ce8e"
GridapGmsh = "3025c34a-b394-11e9-2a55-3fee550c04c8"
HypertextLiteral = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
Interpolations = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
IterativeSolvers = "42fd0dbc-a981-5370-80f2-aaf504508153"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
Lux = "b2108857-7c20-44ae-9111-449ecde12c47"
Optim = "429524aa-4258-5aef-a3af-852621145aeb"
Optimisers = "3bd65402-5787-11e9-1adc-39752487f4e2"
Pardiso = "46dd5b70-b6fb-5a00-ae2d-e8fea33afaf2"
Plots = "91a5bcdd-55d7-5caf-9e0b-520d859cae80"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
StatsFuns = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
Zygote = "e88e6eb3-aa80-5325-afca-941959d7151f"

[compat]
BenchmarkTools = "~1.5.0"
Distributions = "~0.25.107"
FiniteDifferences = "~0.12.31"
Gridap = "~0.18.1"
GridapGmsh = "~0.7.1"
HypertextLiteral = "~0.9.5"
Interpolations = "~0.15.1"
IterativeSolvers = "~0.9.4"
Lux = "~0.5.28"
Optim = "~1.9.4"
Optimisers = "~0.3.3"
Pardiso = "~0.5.6"
Plots = "~1.40.4"
PlutoUI = "~0.7.58"
StatsFuns = "~1.3.1"
Zygote = "~0.6.69"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.10.3"
manifest_format = "2.0"
project_hash = "54d3bc424bdc56c4739119a7ff037e5a40b4ec1f"

[[deps.ADTypes]]
git-tree-sha1 = "daf26bbdec60d9ca1c0003b70f389d821ddb4224"
uuid = "47edcb42-4c32-4615-8424-f2b9edc5f35b"
version = "1.2.1"
weakdeps = ["ChainRulesCore", "EnzymeCore"]

    [deps.ADTypes.extensions]
    ADTypesChainRulesCoreExt = "ChainRulesCore"
    ADTypesEnzymeCoreExt = "EnzymeCore"

[[deps.AbstractFFTs]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "d92ad398961a3ed262d8bf04a1a2b8340f915fef"
uuid = "621f4979-c628-5d54-868e-fcf4e3e8185c"
version = "1.5.0"
weakdeps = ["ChainRulesCore", "Test"]

    [deps.AbstractFFTs.extensions]
    AbstractFFTsChainRulesCoreExt = "ChainRulesCore"
    AbstractFFTsTestExt = "Test"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "6e1d2a35f2f90a4bc7c2ed98079b2ba09c35b83a"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.3.2"

[[deps.AbstractTrees]]
git-tree-sha1 = "2d9c9a55f9c93e8887ad391fbae72f8ef55e1177"
uuid = "1520ce14-60c1-5f80-bbc7-55ef81b5835c"
version = "0.4.5"

[[deps.Accessors]]
deps = ["CompositionsBase", "ConstructionBase", "Dates", "InverseFunctions", "LinearAlgebra", "MacroTools", "Markdown", "Test"]
git-tree-sha1 = "c0d491ef0b135fd7d63cbc6404286bc633329425"
uuid = "7d9f7c33-5ae7-4f3b-8dc6-eff91059b697"
version = "0.1.36"

    [deps.Accessors.extensions]
    AccessorsAxisKeysExt = "AxisKeys"
    AccessorsIntervalSetsExt = "IntervalSets"
    AccessorsStaticArraysExt = "StaticArrays"
    AccessorsStructArraysExt = "StructArrays"
    AccessorsUnitfulExt = "Unitful"

    [deps.Accessors.weakdeps]
    AxisKeys = "94b1ba4f-4ee9-5380-92f1-94cde586c3c5"
    IntervalSets = "8197267c-284f-5f27-9208-e0e47529a953"
    Requires = "ae029012-a4dd-5104-9daa-d747884805df"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.Adapt]]
deps = ["LinearAlgebra", "Requires"]
git-tree-sha1 = "6a55b747d1812e699320963ffde36f1ebdda4099"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "4.0.4"
weakdeps = ["StaticArrays"]

    [deps.Adapt.extensions]
    AdaptStaticArraysExt = "StaticArrays"

[[deps.AliasTables]]
deps = ["PtrArrays", "Random"]
git-tree-sha1 = "9876e1e164b144ca45e9e3198d0b689cadfed9ff"
uuid = "66dad0bd-aa9a-41b7-9441-69ab47430ed8"
version = "1.1.3"

[[deps.ArgCheck]]
git-tree-sha1 = "a3a402a35a2f7e0b87828ccabbd5ebfbebe356b4"
uuid = "dce04be8-c92d-5529-be00-80e4d2c0e197"
version = "2.3.0"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.1"

[[deps.ArrayInterface]]
deps = ["Adapt", "LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "133a240faec6e074e07c31ee75619c90544179cf"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.10.0"

    [deps.ArrayInterface.extensions]
    ArrayInterfaceBandedMatricesExt = "BandedMatrices"
    ArrayInterfaceBlockBandedMatricesExt = "BlockBandedMatrices"
    ArrayInterfaceCUDAExt = "CUDA"
    ArrayInterfaceCUDSSExt = "CUDSS"
    ArrayInterfaceChainRulesExt = "ChainRules"
    ArrayInterfaceGPUArraysCoreExt = "GPUArraysCore"
    ArrayInterfaceReverseDiffExt = "ReverseDiff"
    ArrayInterfaceStaticArraysCoreExt = "StaticArraysCore"
    ArrayInterfaceTrackerExt = "Tracker"

    [deps.ArrayInterface.weakdeps]
    BandedMatrices = "aae01518-5342-5314-be14-df237901396f"
    BlockBandedMatrices = "ffab5731-97b5-5995-9138-79e8c1846df0"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    CUDSS = "45b445bb-4962-46a0-9369-b4df9d0f772e"
    ChainRules = "082447d4-558c-5d27-93f4-14fc19e9eca2"
    GPUArraysCore = "46192b85-c4d5-4398-a991-12ede77f4527"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    StaticArraysCore = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.ArrayLayouts]]
deps = ["FillArrays", "LinearAlgebra"]
git-tree-sha1 = "29649b61e0313db0a7ad5ecf41210e4e85aea234"
uuid = "4c555306-a7a7-4459-81d9-ec55ddd5c99a"
version = "1.9.3"
weakdeps = ["SparseArrays"]

    [deps.ArrayLayouts.extensions]
    ArrayLayoutsSparseArraysExt = "SparseArrays"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"

[[deps.Atomix]]
deps = ["UnsafeAtomics"]
git-tree-sha1 = "c06a868224ecba914baa6942988e2f2aade419be"
uuid = "a9b6321e-bd34-4604-b9c9-b65b8de01458"
version = "0.1.0"

[[deps.AutoHashEquals]]
deps = ["Pkg"]
git-tree-sha1 = "daaeb6f7f77b88c072a83a2451801818acb5c63b"
uuid = "15f4f7f2-30c1-5605-9d31-71845cf9641f"
version = "2.1.0"

[[deps.AxisAlgorithms]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "WoodburyMatrices"]
git-tree-sha1 = "01b8ccb13d68535d73d2b0c23e39bd23155fb712"
uuid = "13072b0f-2c55-5437-9ae7-d433b7a33950"
version = "1.1.0"

[[deps.BSON]]
git-tree-sha1 = "4c3e506685c527ac6a54ccc0c8c76fd6f91b42fb"
uuid = "fbb218c0-5317-5bc6-957e-2ee96dd4b1f0"
version = "0.3.9"

[[deps.BangBang]]
deps = ["Accessors", "Compat", "ConstructionBase", "InitialValues", "LinearAlgebra", "Requires"]
git-tree-sha1 = "08e5fc6620a8d83534bf6149795054f1b1e8370a"
uuid = "198e06fe-97b7-11e9-32a5-e1d131e6ad66"
version = "0.4.2"

    [deps.BangBang.extensions]
    BangBangChainRulesCoreExt = "ChainRulesCore"
    BangBangDataFramesExt = "DataFrames"
    BangBangStaticArraysExt = "StaticArrays"
    BangBangStructArraysExt = "StructArrays"
    BangBangTablesExt = "Tables"
    BangBangTypedTablesExt = "TypedTables"

    [deps.BangBang.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
    Tables = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
    TypedTables = "9d95f2ec-7b3d-5a63-8d20-e2491e220bb9"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"

[[deps.BenchmarkTools]]
deps = ["JSON", "Logging", "Printf", "Profile", "Statistics", "UUIDs"]
git-tree-sha1 = "f1dff6729bc61f4d49e140da1af55dcd1ac97b2f"
uuid = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
version = "1.5.0"

[[deps.BitFlags]]
git-tree-sha1 = "2dc09997850d68179b69dafb58ae806167a32b1b"
uuid = "d1d4a3ce-64b1-5f1a-9ba4-7e7e69966f35"
version = "0.1.8"

[[deps.BitTwiddlingConvenienceFunctions]]
deps = ["Static"]
git-tree-sha1 = "0c5f81f47bbbcf4aea7b2959135713459170798b"
uuid = "62783981-4cbd-42fc-bca8-16325de8dc4b"
version = "0.1.5"

[[deps.BlockArrays]]
deps = ["ArrayLayouts", "FillArrays", "LinearAlgebra"]
git-tree-sha1 = "9a9610fbe5779636f75229e423e367124034af41"
uuid = "8e7c35d0-a365-5155-bbbb-fb81a777f24e"
version = "0.16.43"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9e2a6b69137e6969bab0152632dcb3bc108c8bdd"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.8+1"

[[deps.CEnum]]
git-tree-sha1 = "389ad5c84de1ae7cf0e28e381131c98ea87d54fc"
uuid = "fa961155-64e5-5f13-b03f-caf6b980ea82"
version = "0.5.0"

[[deps.CPUSummary]]
deps = ["CpuId", "IfElse", "PrecompileTools", "Static"]
git-tree-sha1 = "585a387a490f1c4bd88be67eea15b93da5e85db7"
uuid = "2a0fbf3d-bb9c-48f3-b0a9-814d99fd7ab9"
version = "0.2.5"

[[deps.Cairo_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "JLLWrappers", "LZO_jll", "Libdl", "Pixman_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "a2f1c8c668c8e3cb4cca4e57a8efdb09067bb3fd"
uuid = "83423d85-b0ee-5818-9007-b63ccbeb887a"
version = "1.18.0+2"

[[deps.Calculus]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f641eb0a4f00c343bbc32346e1217b86f3ce9dad"
uuid = "49dc2e85-a5d0-5ad3-a950-438e2897f1b9"
version = "0.5.1"

[[deps.ChainRules]]
deps = ["Adapt", "ChainRulesCore", "Compat", "Distributed", "GPUArraysCore", "IrrationalConstants", "LinearAlgebra", "Random", "RealDot", "SparseArrays", "SparseInverseSubset", "Statistics", "StructArrays", "SuiteSparse"]
git-tree-sha1 = "291821c1251486504f6bae435227907d734e94d2"
uuid = "082447d4-558c-5d27-93f4-14fc19e9eca2"
version = "1.66.0"

[[deps.ChainRulesCore]]
deps = ["Compat", "LinearAlgebra"]
git-tree-sha1 = "575cd02e080939a33b6df6c5853d14924c08e35b"
uuid = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
version = "1.23.0"
weakdeps = ["SparseArrays"]

    [deps.ChainRulesCore.extensions]
    ChainRulesCoreSparseArraysExt = "SparseArrays"

[[deps.ChunkSplitters]]
deps = ["Compat", "TestItems"]
git-tree-sha1 = "c7962ce1b964bde2867808235d1c521781df191e"
uuid = "ae650224-84b6-46f8-82ea-d812ca08434e"
version = "2.4.2"

[[deps.CircularArrays]]
deps = ["OffsetArrays"]
git-tree-sha1 = "e24a6f390e5563583bb4315c73035b5b3f3e7ab4"
uuid = "7a955b69-7140-5f4e-a0ed-f168c5e2e749"
version = "1.4.0"

[[deps.CloseOpenIntervals]]
deps = ["Static", "StaticArrayInterface"]
git-tree-sha1 = "70232f82ffaab9dc52585e0dd043b5e0c6b714f1"
uuid = "fb6a15b2-703c-40df-9091-08a04967cfa9"
version = "0.1.12"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "59939d8a997469ee05c4b4944560a820f9ba0d73"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.4"

[[deps.ColorSchemes]]
deps = ["ColorTypes", "ColorVectorSpace", "Colors", "FixedPointNumbers", "PrecompileTools", "Random"]
git-tree-sha1 = "4b270d6465eb21ae89b732182c20dc165f8bf9f2"
uuid = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
version = "3.25.0"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "b10d0b65641d57b8b4d5e234446582de5047050d"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.11.5"

[[deps.ColorVectorSpace]]
deps = ["ColorTypes", "FixedPointNumbers", "LinearAlgebra", "Requires", "Statistics", "TensorCore"]
git-tree-sha1 = "a1f44953f2382ebb937d60dafbe2deea4bd23249"
uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
version = "0.10.0"
weakdeps = ["SpecialFunctions"]

    [deps.ColorVectorSpace.extensions]
    SpecialFunctionsExt = "SpecialFunctions"

[[deps.Colors]]
deps = ["ColorTypes", "FixedPointNumbers", "Reexport"]
git-tree-sha1 = "362a287c3aa50601b0bc359053d5c2468f0e7ce0"
uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"
version = "0.12.11"

[[deps.Combinatorics]]
git-tree-sha1 = "08c8b6831dc00bfea825826be0bc8336fc369860"
uuid = "861a8166-3701-5b0c-9a16-15d98fcdc6aa"
version = "1.0.2"

[[deps.CommonSubexpressions]]
deps = ["MacroTools", "Test"]
git-tree-sha1 = "7b8a93dba8af7e3b42fecabf646260105ac373f7"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.0"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "b1c55339b7c6c350ee89f2c1604299660525b248"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.15.0"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.1.1+0"

[[deps.CompositionsBase]]
git-tree-sha1 = "802bb88cd69dfd1509f6670416bd4434015693ad"
uuid = "a33af91c-f02d-484b-be07-31d278c5ca2b"
version = "0.1.2"
weakdeps = ["InverseFunctions"]

    [deps.CompositionsBase.extensions]
    CompositionsBaseInverseFunctionsExt = "InverseFunctions"

[[deps.ConcreteStructs]]
git-tree-sha1 = "f749037478283d372048690eb3b5f92a79432b34"
uuid = "2569d6c7-a4a2-43d3-a901-331e8e4be471"
version = "0.2.3"

[[deps.ConcurrentUtilities]]
deps = ["Serialization", "Sockets"]
git-tree-sha1 = "6cbbd4d241d7e6579ab354737f4dd95ca43946e1"
uuid = "f0e56b4a-5159-44fe-b623-3e5288b988bb"
version = "2.4.1"

[[deps.ConstructionBase]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "260fd2400ed2dab602a7c15cf10c1933c59930a2"
uuid = "187b0558-2788-49d3-abe0-74a17ed4e7c9"
version = "1.5.5"

    [deps.ConstructionBase.extensions]
    ConstructionBaseIntervalSetsExt = "IntervalSets"
    ConstructionBaseStaticArraysExt = "StaticArrays"

    [deps.ConstructionBase.weakdeps]
    IntervalSets = "8197267c-284f-5f27-9208-e0e47529a953"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.Contour]]
git-tree-sha1 = "439e35b0b36e2e5881738abc8857bd92ad6ff9a8"
uuid = "d38c429a-6771-53c6-b99e-75d170b6e991"
version = "0.6.3"

[[deps.CpuId]]
deps = ["Markdown"]
git-tree-sha1 = "fcbb72b032692610bfbdb15018ac16a36cf2e406"
uuid = "adafc99b-e345-5852-983c-f28acb93d879"
version = "0.3.1"

[[deps.DataAPI]]
git-tree-sha1 = "abe83f3a2f1b857aac70ef8b269080af17764bbe"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.16.0"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "1d0a14036acb104d9e89698bd408f63ab58cdc82"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.20"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[deps.DelimitedFiles]]
deps = ["Mmap"]
git-tree-sha1 = "9e2f36d3c96a820c678f2f1f1782582fcf685bae"
uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab"
version = "1.9.1"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "23163d55f885173722d1e4cf0f6110cdbaf7e272"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.15.1"

[[deps.Distances]]
deps = ["LinearAlgebra", "Statistics", "StatsAPI"]
git-tree-sha1 = "66c4c81f259586e8f002eacebc177e1fb06363b0"
uuid = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
version = "0.10.11"
weakdeps = ["ChainRulesCore", "SparseArrays"]

    [deps.Distances.extensions]
    DistancesChainRulesCoreExt = "ChainRulesCore"
    DistancesSparseArraysExt = "SparseArrays"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"

[[deps.Distributions]]
deps = ["AliasTables", "FillArrays", "LinearAlgebra", "PDMats", "Printf", "QuadGK", "Random", "SpecialFunctions", "Statistics", "StatsAPI", "StatsBase", "StatsFuns"]
git-tree-sha1 = "22c595ca4146c07b16bcf9c8bea86f731f7109d2"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.108"

    [deps.Distributions.extensions]
    DistributionsChainRulesCoreExt = "ChainRulesCore"
    DistributionsDensityInterfaceExt = "DensityInterface"
    DistributionsTestExt = "Test"

    [deps.Distributions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DensityInterface = "b429d917-457f-4dbc-8f4c-0cc954292b1d"
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "2fb1e02f2b635d0845df5d7c167fec4dd739b00d"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.3"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.DualNumbers]]
deps = ["Calculus", "NaNMath", "SpecialFunctions"]
git-tree-sha1 = "5837a837389fccf076445fce071c8ddaea35a566"
uuid = "fa6b7ba4-c1ee-5f82-b5fc-ecf0adba8f74"
version = "0.6.8"

[[deps.EnzymeCore]]
git-tree-sha1 = "18394bc78ac2814ff38fe5e0c9dc2cd171e2810c"
uuid = "f151be2c-9106-41f4-ab19-57ee4f262869"
version = "0.7.2"
weakdeps = ["Adapt"]

    [deps.EnzymeCore.extensions]
    AdaptExt = "Adapt"

[[deps.EpollShim_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8e9441ee83492030ace98f9789a654a6d0b1f643"
uuid = "2702e6a9-849d-5ed8-8c21-79e8b8f9ee43"
version = "0.0.20230411+0"

[[deps.ExceptionUnwrapping]]
deps = ["Test"]
git-tree-sha1 = "dcb08a0d93ec0b1cdc4af184b26b591e9695423a"
uuid = "460bff9d-24e4-43bc-9d9f-a8973cb893f4"
version = "0.1.10"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1c6317308b9dc757616f0b5cb379db10494443a7"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.6.2+0"

[[deps.FFMPEG]]
deps = ["FFMPEG_jll"]
git-tree-sha1 = "b57e3acbe22f8484b4b5ff66a7499717fe1a9cc8"
uuid = "c87230d0-a227-11e9-1b43-d7ebe4e7570a"
version = "0.4.1"

[[deps.FFMPEG_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "JLLWrappers", "LAME_jll", "Libdl", "Ogg_jll", "OpenSSL_jll", "Opus_jll", "PCRE2_jll", "Zlib_jll", "libaom_jll", "libass_jll", "libfdk_aac_jll", "libvorbis_jll", "x264_jll", "x265_jll"]
git-tree-sha1 = "466d45dc38e15794ec7d5d63ec03d776a9aff36e"
uuid = "b22a6f82-2f65-5046-a5b2-351ab43fb4e5"
version = "4.4.4+1"

[[deps.FFTW]]
deps = ["AbstractFFTs", "FFTW_jll", "LinearAlgebra", "MKL_jll", "Preferences", "Reexport"]
git-tree-sha1 = "4820348781ae578893311153d69049a93d05f39d"
uuid = "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"
version = "1.8.0"

[[deps.FFTW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c6033cc3892d0ef5bb9cd29b7f2f0331ea5184ea"
uuid = "f5851436-0d7a-5f13-b9de-f02708fd171a"
version = "3.3.10+0"

[[deps.FLTK_jll]]
deps = ["Artifacts", "Fontconfig_jll", "FreeType2_jll", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libglvnd_jll", "Pkg", "Xorg_libX11_jll", "Xorg_libXext_jll", "Xorg_libXfixes_jll", "Xorg_libXft_jll", "Xorg_libXinerama_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "72a4842f93e734f378cf381dae2ca4542f019d23"
uuid = "4fce6fc7-ba6a-5f4c-898f-77e99806d6f8"
version = "1.3.8+0"

[[deps.FastBroadcast]]
deps = ["ArrayInterface", "LinearAlgebra", "Polyester", "Static", "StaticArrayInterface", "StrideArraysCore"]
git-tree-sha1 = "a6e756a880fc419c8b41592010aebe6a5ce09136"
uuid = "7034ab61-46d4-4ed7-9d0f-46aef9175898"
version = "0.2.8"

[[deps.FastClosures]]
git-tree-sha1 = "acebe244d53ee1b461970f8910c235b259e772ef"
uuid = "9aa1b823-49e4-5ca5-8b0f-3971ec8bab6a"
version = "0.3.2"

[[deps.FastGaussQuadrature]]
deps = ["LinearAlgebra", "SpecialFunctions", "StaticArrays"]
git-tree-sha1 = "fd923962364b645f3719855c88f7074413a6ad92"
uuid = "442a2c76-b920-505d-bb47-c5924d526838"
version = "1.0.2"

[[deps.FileIO]]
deps = ["Pkg", "Requires", "UUIDs"]
git-tree-sha1 = "82d8afa92ecf4b52d78d869f038ebfb881267322"
uuid = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
version = "1.16.3"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"

[[deps.FillArrays]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "0653c0a2396a6da5bc4766c43041ef5fd3efbe57"
uuid = "1a297f60-69ca-5386-bcde-b61e274b549b"
version = "1.11.0"
weakdeps = ["PDMats", "SparseArrays", "Statistics"]

    [deps.FillArrays.extensions]
    FillArraysPDMatsExt = "PDMats"
    FillArraysSparseArraysExt = "SparseArrays"
    FillArraysStatisticsExt = "Statistics"

[[deps.FiniteDiff]]
deps = ["ArrayInterface", "LinearAlgebra", "Requires", "Setfield", "SparseArrays"]
git-tree-sha1 = "2de436b72c3422940cbe1367611d137008af7ec3"
uuid = "6a86dc24-6348-571c-b903-95158fe2bd41"
version = "2.23.1"

    [deps.FiniteDiff.extensions]
    FiniteDiffBandedMatricesExt = "BandedMatrices"
    FiniteDiffBlockBandedMatricesExt = "BlockBandedMatrices"
    FiniteDiffStaticArraysExt = "StaticArrays"

    [deps.FiniteDiff.weakdeps]
    BandedMatrices = "aae01518-5342-5314-be14-df237901396f"
    BlockBandedMatrices = "ffab5731-97b5-5995-9138-79e8c1846df0"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.FiniteDifferences]]
deps = ["ChainRulesCore", "LinearAlgebra", "Printf", "Random", "Richardson", "SparseArrays", "StaticArrays"]
git-tree-sha1 = "d77e4697046989f44dce3ed66269aaf1611a3406"
uuid = "26cc04aa-876d-5657-8c51-4c34ba976000"
version = "0.12.31"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "05882d6995ae5c12bb5f36dd2ed3f61c98cbb172"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.5"

[[deps.Fontconfig_jll]]
deps = ["Artifacts", "Bzip2_jll", "Expat_jll", "FreeType2_jll", "JLLWrappers", "Libdl", "Libuuid_jll", "Zlib_jll"]
git-tree-sha1 = "db16beca600632c95fc8aca29890d83788dd8b23"
uuid = "a3f928ae-7b40-5064-980b-68af3947d34b"
version = "2.13.96+0"

[[deps.Format]]
git-tree-sha1 = "9c68794ef81b08086aeb32eeaf33531668d5f5fc"
uuid = "1fa38f19-a742-5d3f-a2b9-30dd87b9d5f8"
version = "1.3.7"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions"]
git-tree-sha1 = "cf0fe81336da9fb90944683b8c41984b08793dad"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "0.10.36"
weakdeps = ["StaticArrays"]

    [deps.ForwardDiff.extensions]
    ForwardDiffStaticArraysExt = "StaticArrays"

[[deps.FreeType2_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "5c1d8ae0efc6c2e7b1fc502cbe25def8f661b7bc"
uuid = "d7e528f0-a631-5988-bf34-fe36492bcfd7"
version = "2.13.2+0"

[[deps.FriBidi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1ed150b39aebcc805c26b93a8d0122c940f64ce2"
uuid = "559328eb-81f9-559d-9380-de523a88c83c"
version = "1.0.14+0"

[[deps.Functors]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "d3e63d9fa13f8eaa2f06f64949e2afc593ff52c2"
uuid = "d9f16b24-f501-4c13-a1f2-28368ffc5196"
version = "0.4.10"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"

[[deps.GLFW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libglvnd_jll", "Xorg_libXcursor_jll", "Xorg_libXi_jll", "Xorg_libXinerama_jll", "Xorg_libXrandr_jll"]
git-tree-sha1 = "ff38ba61beff76b8f4acad8ab0c97ef73bb670cb"
uuid = "0656b61e-2033-5cc2-a64a-77c0f6c09b89"
version = "3.3.9+0"

[[deps.GLU_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libglvnd_jll", "Pkg"]
git-tree-sha1 = "65af046f4221e27fb79b28b6ca89dd1d12bc5ec7"
uuid = "bd17208b-e95e-5925-bf81-e2f59b3e5c61"
version = "9.0.1+0"

[[deps.GMP_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "781609d7-10c4-51f6-84f2-b8444358ff6d"
version = "6.2.1+6"

[[deps.GPUArrays]]
deps = ["Adapt", "GPUArraysCore", "LLVM", "LinearAlgebra", "Printf", "Random", "Reexport", "Serialization", "Statistics"]
git-tree-sha1 = "38cb19b8a3e600e509dc36a6396ac74266d108c1"
uuid = "0c68f7d7-f131-5f86-a1c3-88cf8149b2d7"
version = "10.1.1"

[[deps.GPUArraysCore]]
deps = ["Adapt"]
git-tree-sha1 = "ec632f177c0d990e64d955ccc1b8c04c485a0950"
uuid = "46192b85-c4d5-4398-a991-12ede77f4527"
version = "0.1.6"

[[deps.GR]]
deps = ["Artifacts", "Base64", "DelimitedFiles", "Downloads", "GR_jll", "HTTP", "JSON", "Libdl", "LinearAlgebra", "Preferences", "Printf", "Random", "Serialization", "Sockets", "TOML", "Tar", "Test", "p7zip_jll"]
git-tree-sha1 = "ddda044ca260ee324c5fc07edb6d7cf3f0b9c350"
uuid = "28b8d3ca-fb5f-59d9-8090-bfdbd6d07a71"
version = "0.73.5"

[[deps.GR_jll]]
deps = ["Artifacts", "Bzip2_jll", "Cairo_jll", "FFMPEG_jll", "Fontconfig_jll", "FreeType2_jll", "GLFW_jll", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libtiff_jll", "Pixman_jll", "Qt6Base_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "278e5e0f820178e8a26df3184fcb2280717c79b1"
uuid = "d2c73de3-f751-5644-a686-071e5b155ba9"
version = "0.73.5+0"

[[deps.Gettext_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "9b02998aba7bf074d14de89f9d37ca24a1a0b046"
uuid = "78b55507-aeef-58d4-861c-77aaff3498b1"
version = "0.21.0+0"

[[deps.Glib_jll]]
deps = ["Artifacts", "Gettext_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Libiconv_jll", "Libmount_jll", "PCRE2_jll", "Zlib_jll"]
git-tree-sha1 = "7c82e6a6cd34e9d935e9aa4051b66c6ff3af59ba"
uuid = "7746bdde-850d-59dc-9ae8-88ece973131d"
version = "2.80.2+0"

[[deps.Graphite2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "344bf40dcab1073aca04aa0df4fb092f920e4011"
uuid = "3b182d85-2403-5c21-9c21-1e1f0cc25472"
version = "1.3.14+0"

[[deps.Gridap]]
deps = ["AbstractTrees", "BSON", "BlockArrays", "Combinatorics", "DataStructures", "DocStringExtensions", "FastGaussQuadrature", "FileIO", "FillArrays", "ForwardDiff", "JLD2", "JSON", "LineSearches", "LinearAlgebra", "NLsolve", "NearestNeighbors", "PolynomialBases", "QuadGK", "Random", "SparseArrays", "SparseMatricesCSR", "StaticArrays", "Statistics", "Test", "WriteVTK"]
git-tree-sha1 = "4918159105057659c25508ea2729fa7b5e4990ae"
uuid = "56d4f2e9-7ea1-5844-9cf6-b9c51ca7ce8e"
version = "0.18.2"

[[deps.GridapDistributed]]
deps = ["BlockArrays", "FillArrays", "Gridap", "LinearAlgebra", "MPI", "PartitionedArrays", "SparseArrays", "SparseMatricesCSR", "WriteVTK"]
git-tree-sha1 = "53c27134cd80fabb3a845cbc588486444a2f0571"
uuid = "f9701e48-63b3-45aa-9a63-9bc6c271f355"
version = "0.4.0"

[[deps.GridapGmsh]]
deps = ["Gridap", "GridapDistributed", "Libdl", "Metis", "PartitionedArrays", "gmsh_jll"]
git-tree-sha1 = "d57e69bba40c1e77bcf3a781aadbd846199ea251"
uuid = "3025c34a-b394-11e9-2a55-3fee550c04c8"
version = "0.7.1"

[[deps.Grisu]]
git-tree-sha1 = "53bb909d1151e57e2484c3d1b53e19552b887fb2"
uuid = "42e2da0e-8278-4e71-bc24-59509adca0fe"
version = "1.0.2"

[[deps.HDF5_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LazyArtifacts", "LibCURL_jll", "Libdl", "MPICH_jll", "MPIPreferences", "MPItrampoline_jll", "MicrosoftMPI_jll", "OpenMPI_jll", "OpenSSL_jll", "TOML", "Zlib_jll", "libaec_jll"]
git-tree-sha1 = "82a471768b513dc39e471540fdadc84ff80ff997"
uuid = "0234f1f7-429e-5d53-9886-15a909be8d59"
version = "1.14.3+3"

[[deps.HTTP]]
deps = ["Base64", "CodecZlib", "ConcurrentUtilities", "Dates", "ExceptionUnwrapping", "Logging", "LoggingExtras", "MbedTLS", "NetworkOptions", "OpenSSL", "Random", "SimpleBufferStream", "Sockets", "URIs", "UUIDs"]
git-tree-sha1 = "d1d712be3164d61d1fb98e7ce9bcbc6cc06b45ed"
uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"
version = "1.10.8"

[[deps.HarfBuzz_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "Graphite2_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg"]
git-tree-sha1 = "129acf094d168394e80ee1dc4bc06ec835e510a3"
uuid = "2e76f6c2-a576-52d4-95c1-20adfe4de566"
version = "2.8.1+1"

[[deps.Hwloc_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "ca0f6bf568b4bfc807e7537f081c81e35ceca114"
uuid = "e33a78d0-f292-5ffc-b300-72abe9b543c8"
version = "2.10.0+0"

[[deps.HypergeometricFunctions]]
deps = ["DualNumbers", "LinearAlgebra", "OpenLibm_jll", "SpecialFunctions"]
git-tree-sha1 = "f218fe3736ddf977e0e772bc9a586b2383da2685"
uuid = "34004b35-14d8-5ef3-9330-4cdb6864b03a"
version = "0.3.23"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "179267cfa5e712760cd43dcae385d7ea90cc25a4"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.5"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "7134810b1afce04bbc1045ca1985fbe81ce17653"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "0.9.5"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "8b72179abc660bfab5e28472e019392b97d0985c"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "0.2.4"

[[deps.IRTools]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "950c3717af761bc3ff906c2e8e52bd83390b6ec2"
uuid = "7869d1d1-7146-5819-86e3-90919afe41df"
version = "0.4.14"

[[deps.IfElse]]
git-tree-sha1 = "debdd00ffef04665ccbb3e150747a77560e8fad1"
uuid = "615f187c-cbe4-4ef1-ba3b-2fcf58d6d173"
version = "0.1.1"

[[deps.InitialValues]]
git-tree-sha1 = "4da0f88e9a39111c2fa3add390ab15f3a44f3ca3"
uuid = "22cec73e-a1b8-11e9-2c92-598750a2cf9c"
version = "0.3.1"

[[deps.IntelOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "be50fe8df3acbffa0274a744f1a99d29c45a57f4"
uuid = "1d5cc7b8-4909-519e-a0f8-d0f5ad9712d0"
version = "2024.1.0+0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"

[[deps.Interpolations]]
deps = ["Adapt", "AxisAlgorithms", "ChainRulesCore", "LinearAlgebra", "OffsetArrays", "Random", "Ratios", "Requires", "SharedArrays", "SparseArrays", "StaticArrays", "WoodburyMatrices"]
git-tree-sha1 = "88a101217d7cb38a7b481ccd50d21876e1d1b0e0"
uuid = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
version = "0.15.1"
weakdeps = ["Unitful"]

    [deps.Interpolations.extensions]
    InterpolationsUnitfulExt = "Unitful"

[[deps.InverseFunctions]]
deps = ["Test"]
git-tree-sha1 = "e7cbed5032c4c397a6ac23d1493f3289e01231c4"
uuid = "3587e190-3f89-42d0-90ee-14403ec27112"
version = "0.1.14"
weakdeps = ["Dates"]

    [deps.InverseFunctions.extensions]
    DatesExt = "Dates"

[[deps.IrrationalConstants]]
git-tree-sha1 = "630b497eafcc20001bba38a4651b327dcfc491d2"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.2"

[[deps.IterativeSolvers]]
deps = ["LinearAlgebra", "Printf", "Random", "RecipesBase", "SparseArrays"]
git-tree-sha1 = "59545b0a2b27208b0650df0a46b8e3019f85055b"
uuid = "42fd0dbc-a981-5370-80f2-aaf504508153"
version = "0.9.4"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLD2]]
deps = ["FileIO", "MacroTools", "Mmap", "OrderedCollections", "Pkg", "PrecompileTools", "Reexport", "Requires", "TranscodingStreams", "UUIDs", "Unicode"]
git-tree-sha1 = "bdbe8222d2f5703ad6a7019277d149ec6d78c301"
uuid = "033835bb-8acc-5ee8-8aae-3f567f8a3819"
version = "0.4.48"

[[deps.JLFzf]]
deps = ["Pipe", "REPL", "Random", "fzf_jll"]
git-tree-sha1 = "a53ebe394b71470c7f97c2e7e170d51df21b17af"
uuid = "1019f520-868f-41f5-a6de-eb00f4b6a39c"
version = "0.1.7"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "7e5d6779a1e09a36db2a7b6cff50942a0a7d0fca"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.5.0"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "31e996f0a15c7b280ba9f76636b3ff9e2ae58c9a"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.4"

[[deps.JpegTurbo_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "c84a835e1a09b289ffcd2271bf2a337bbdda6637"
uuid = "aacddb02-875f-59d6-b918-886e6ef4fbf8"
version = "3.0.3+0"

[[deps.KernelAbstractions]]
deps = ["Adapt", "Atomix", "InteractiveUtils", "LinearAlgebra", "MacroTools", "PrecompileTools", "Requires", "SparseArrays", "StaticArrays", "UUIDs", "UnsafeAtomics", "UnsafeAtomicsLLVM"]
git-tree-sha1 = "db02395e4c374030c53dc28f3c1d33dec35f7272"
uuid = "63c18a36-062a-441e-b654-da1e3ab1ce7c"
version = "0.9.19"
weakdeps = ["EnzymeCore"]

    [deps.KernelAbstractions.extensions]
    EnzymeExt = "EnzymeCore"

[[deps.LAME_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "170b660facf5df5de098d866564877e119141cbd"
uuid = "c1c5ebd0-6772-5130-a774-d5fcae4a789d"
version = "3.100.2+0"

[[deps.LERC_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "bf36f528eec6634efc60d7ec062008f171071434"
uuid = "88015f11-f218-50d7-93a8-a6af411a945d"
version = "3.0.0+1"

[[deps.LLVM]]
deps = ["CEnum", "LLVMExtra_jll", "Libdl", "Preferences", "Printf", "Requires", "Unicode"]
git-tree-sha1 = "065c36f95709dd4a676dc6839a35d6fa6f192f24"
uuid = "929cbde3-209d-540e-8aea-75f648917ca0"
version = "7.1.0"

    [deps.LLVM.extensions]
    BFloat16sExt = "BFloat16s"

    [deps.LLVM.weakdeps]
    BFloat16s = "ab4f0b2a-ad5b-11e8-123f-65d77653426b"

[[deps.LLVMExtra_jll]]
deps = ["Artifacts", "JLLWrappers", "LazyArtifacts", "Libdl", "TOML"]
git-tree-sha1 = "88b916503aac4fb7f701bb625cd84ca5dd1677bc"
uuid = "dad2f222-ce93-54a1-a47d-0025e8a3acab"
version = "0.0.29+0"

[[deps.LLVMOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "d986ce2d884d49126836ea94ed5bfb0f12679713"
uuid = "1d63c593-3942-5779-bab2-d838dc0a180e"
version = "15.0.7+0"

[[deps.LZO_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "70c5da094887fd2cae843b8db33920bac4b6f07d"
uuid = "dd4b983a-f0e5-5f8d-a1b7-129d4a5fb1ac"
version = "2.10.2+0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "50901ebc375ed41dbf8058da26f9de442febbbec"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.3.1"

[[deps.Latexify]]
deps = ["Format", "InteractiveUtils", "LaTeXStrings", "MacroTools", "Markdown", "OrderedCollections", "Requires"]
git-tree-sha1 = "e0b5cd21dc1b44ec6e64f351976f961e6f31d6c4"
uuid = "23fbe1c1-3f47-55db-b15f-69d7ec21a316"
version = "0.16.3"

    [deps.Latexify.extensions]
    DataFramesExt = "DataFrames"
    SymEngineExt = "SymEngine"

    [deps.Latexify.weakdeps]
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    SymEngine = "123dc426-2d89-5057-bbad-38513e3affd8"

[[deps.LayoutPointers]]
deps = ["ArrayInterface", "LinearAlgebra", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "62edfee3211981241b57ff1cedf4d74d79519277"
uuid = "10f19ff3-798f-405d-979b-55457f8fc047"
version = "0.1.15"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.4.0+0"

[[deps.LibGit2]]
deps = ["Base64", "LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.6.4+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.0+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"

[[deps.Libffi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "0b4a5d71f3e5200a7dff793393e09dfc2d874290"
uuid = "e9f186c6-92d2-5b65-8a66-fee21dc1b490"
version = "3.2.2+1"

[[deps.Libgcrypt_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgpg_error_jll"]
git-tree-sha1 = "9fd170c4bbfd8b935fdc5f8b7aa33532c991a673"
uuid = "d4300ac3-e22c-5743-9152-c294e39db1e4"
version = "1.8.11+0"

[[deps.Libglvnd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll", "Xorg_libXext_jll"]
git-tree-sha1 = "6f73d1dd803986947b2c750138528a999a6c7733"
uuid = "7e76a0d4-f3c7-5321-8279-8d96eeed0f29"
version = "1.6.0+0"

[[deps.Libgpg_error_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "fbb1f2bef882392312feb1ede3615ddc1e9b99ed"
uuid = "7add5ba3-2f88-524e-9cd5-f83b8a55f7b8"
version = "1.49.0+0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "f9557a255370125b405568f9767d6d195822a175"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.17.0+0"

[[deps.Libmount_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "0c4f9c4f1a50d8f35048fa0532dabbadf702f81e"
uuid = "4b2f31a3-9ecc-558c-b454-b3730dcb73e9"
version = "2.40.1+0"

[[deps.Libtiff_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "LERC_jll", "Libdl", "XZ_jll", "Zlib_jll", "Zstd_jll"]
git-tree-sha1 = "2da088d113af58221c52828a80378e16be7d037a"
uuid = "89763e89-9b03-5906-acba-b20f662cd828"
version = "4.5.1+1"

[[deps.Libuuid_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "5ee6203157c120d79034c748a2acba45b82b8807"
uuid = "38a345b3-de98-5d2b-a5d3-14cd9215e700"
version = "2.40.1+0"

[[deps.LightXML]]
deps = ["Libdl", "XML2_jll"]
git-tree-sha1 = "3a994404d3f6709610701c7dabfc03fed87a81f8"
uuid = "9c8b4983-aa76-5018-a973-4c85ecc9e179"
version = "0.9.1"

[[deps.LineSearches]]
deps = ["LinearAlgebra", "NLSolversBase", "NaNMath", "Parameters", "Printf"]
git-tree-sha1 = "7bbea35cec17305fc70a0e5b4641477dc0789d9d"
uuid = "d3d80556-e9d4-5f37-9878-2ab0fcc64255"
version = "7.2.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[[deps.LinearElasticity_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "71e8ee0f9fe0e86a8f8c7f28361e5118eab2f93f"
uuid = "18c40d15-f7cd-5a6d-bc92-87468d86c5db"
version = "5.0.0+0"

[[deps.LogExpFunctions]]
deps = ["DocStringExtensions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "18144f3e9cbe9b15b070288eef858f71b291ce37"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "0.3.27"

    [deps.LogExpFunctions.extensions]
    LogExpFunctionsChainRulesCoreExt = "ChainRulesCore"
    LogExpFunctionsChangesOfVariablesExt = "ChangesOfVariables"
    LogExpFunctionsInverseFunctionsExt = "InverseFunctions"

    [deps.LogExpFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ChangesOfVariables = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"

[[deps.LoggingExtras]]
deps = ["Dates", "Logging"]
git-tree-sha1 = "c1dd6d7978c12545b4179fb6153b9250c96b0075"
uuid = "e6f89c97-d47a-5376-807f-9c37f3926c36"
version = "1.0.3"

[[deps.Lux]]
deps = ["ADTypes", "Adapt", "ArgCheck", "ArrayInterface", "ChainRulesCore", "ConcreteStructs", "ConstructionBase", "FastClosures", "Functors", "GPUArraysCore", "LinearAlgebra", "LuxCore", "LuxDeviceUtils", "LuxLib", "MacroTools", "Markdown", "OhMyThreads", "PrecompileTools", "Preferences", "Random", "Reexport", "Setfield", "WeightInitializers"]
git-tree-sha1 = "93c0d182dbcf2dfe1e8f3e68751979f949fca5e6"
uuid = "b2108857-7c20-44ae-9111-449ecde12c47"
version = "0.5.51"

    [deps.Lux.extensions]
    LuxComponentArraysExt = "ComponentArrays"
    LuxDynamicExpressionsExt = "DynamicExpressions"
    LuxDynamicExpressionsForwardDiffExt = ["DynamicExpressions", "ForwardDiff"]
    LuxEnzymeExt = "Enzyme"
    LuxFluxExt = "Flux"
    LuxForwardDiffExt = "ForwardDiff"
    LuxLuxAMDGPUExt = "LuxAMDGPU"
    LuxMLUtilsExt = "MLUtils"
    LuxMPIExt = "MPI"
    LuxMPINCCLExt = ["CUDA", "MPI", "NCCL"]
    LuxOptimisersExt = "Optimisers"
    LuxReverseDiffExt = "ReverseDiff"
    LuxSimpleChainsExt = "SimpleChains"
    LuxTrackerExt = "Tracker"
    LuxZygoteExt = "Zygote"

    [deps.Lux.weakdeps]
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    ComponentArrays = "b0b7db55-cfe3-40fc-9ded-d10e2dbeff66"
    DynamicExpressions = "a40a106e-89c9-4ca8-8020-a735e8728b6b"
    Enzyme = "7da242da-08ed-463a-9acd-ee780be4f1d9"
    Flux = "587475ba-b771-5e3f-ad9e-33799f191a9c"
    ForwardDiff = "f6369f11-7733-5829-9624-2563aa707210"
    LuxAMDGPU = "83120cb1-ca15-4f04-bf3b-6967d2e6b60b"
    MLUtils = "f1d291b0-491e-4a28-83b9-f70985020b54"
    MPI = "da04e1cc-30fd-572f-bb4f-1f8673147195"
    NCCL = "3fe64909-d7a1-4096-9b7d-7a0f12cf0f6b"
    Optimisers = "3bd65402-5787-11e9-1adc-39752487f4e2"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    SimpleChains = "de6bee2f-e2f4-4ec7-b6ed-219cc6f6e9e5"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"
    Zygote = "e88e6eb3-aa80-5325-afca-941959d7151f"

[[deps.LuxCore]]
deps = ["Functors", "Random", "Setfield"]
git-tree-sha1 = "c96985555a9fe41d7ec2bd5625d6c2077e05e33e"
uuid = "bb33d45b-7691-41d6-9220-0943567d0623"
version = "0.1.15"

[[deps.LuxDeviceUtils]]
deps = ["Adapt", "ChainRulesCore", "FastClosures", "Functors", "LuxCore", "PrecompileTools", "Preferences", "Random"]
git-tree-sha1 = "bbcf12d598b8ef6d2b12e506b1d18125552c3b27"
uuid = "34f89e08-e1d5-43b4-8944-0b49ac560553"
version = "0.1.20"

    [deps.LuxDeviceUtils.extensions]
    LuxDeviceUtilsAMDGPUExt = "AMDGPU"
    LuxDeviceUtilsCUDAExt = "CUDA"
    LuxDeviceUtilsFillArraysExt = "FillArrays"
    LuxDeviceUtilsGPUArraysExt = "GPUArrays"
    LuxDeviceUtilsLuxAMDGPUExt = "LuxAMDGPU"
    LuxDeviceUtilsLuxCUDAExt = "LuxCUDA"
    LuxDeviceUtilsMetalGPUArraysExt = ["GPUArrays", "Metal"]
    LuxDeviceUtilsRecursiveArrayToolsExt = "RecursiveArrayTools"
    LuxDeviceUtilsSparseArraysExt = "SparseArrays"
    LuxDeviceUtilsZygoteExt = "Zygote"

    [deps.LuxDeviceUtils.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    FillArrays = "1a297f60-69ca-5386-bcde-b61e274b549b"
    GPUArrays = "0c68f7d7-f131-5f86-a1c3-88cf8149b2d7"
    LuxAMDGPU = "83120cb1-ca15-4f04-bf3b-6967d2e6b60b"
    LuxCUDA = "d0bbae9a-e099-4d5b-a835-1c6931763bda"
    Metal = "dde4c033-4e86-420c-a63e-0dd931031962"
    RecursiveArrayTools = "731186ca-8d62-57ce-b412-fbd966d074cd"
    SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
    Zygote = "e88e6eb3-aa80-5325-afca-941959d7151f"

[[deps.LuxLib]]
deps = ["ArrayInterface", "ChainRulesCore", "EnzymeCore", "FastBroadcast", "FastClosures", "GPUArraysCore", "LinearAlgebra", "LuxCore", "Markdown", "NNlib", "PrecompileTools", "Random", "Reexport", "Statistics"]
git-tree-sha1 = "02920ad8b5f7c8a24cb32fb29dd990eac944cd71"
uuid = "82251201-b29d-42c6-8e01-566dec8acb11"
version = "0.3.26"

    [deps.LuxLib.extensions]
    LuxLibAMDGPUExt = "AMDGPU"
    LuxLibCUDAExt = "CUDA"
    LuxLibForwardDiffExt = "ForwardDiff"
    LuxLibReverseDiffExt = "ReverseDiff"
    LuxLibTrackerAMDGPUExt = ["AMDGPU", "Tracker"]
    LuxLibTrackerExt = "Tracker"
    LuxLibTrackercuDNNExt = ["CUDA", "Tracker", "cuDNN"]
    LuxLibcuDNNExt = ["CUDA", "cuDNN"]

    [deps.LuxLib.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    ForwardDiff = "f6369f11-7733-5829-9624-2563aa707210"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.METIS_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "1fd0a97409e418b78c53fac671cf4622efdf0f21"
uuid = "d00139f3-1899-568f-a2f0-47f597d42d70"
version = "5.1.2+0"

[[deps.MIMEs]]
git-tree-sha1 = "65f28ad4b594aebe22157d6fac869786a255b7eb"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "0.1.4"

[[deps.MKL_jll]]
deps = ["Artifacts", "IntelOpenMP_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "oneTBB_jll"]
git-tree-sha1 = "80b2833b56d466b3858d565adcd16a4a05f2089b"
uuid = "856f044c-d86e-5d09-b602-aeab76dc8ba7"
version = "2024.1.0+0"

[[deps.MMG_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "LinearElasticity_jll", "Pkg", "SCOTCH_jll"]
git-tree-sha1 = "70a59df96945782bb0d43b56d0fbfdf1ce2e4729"
uuid = "86086c02-e288-5929-a127-40944b0018b7"
version = "5.6.0+0"

[[deps.MPI]]
deps = ["Distributed", "DocStringExtensions", "Libdl", "MPICH_jll", "MPIPreferences", "MPItrampoline_jll", "MicrosoftMPI_jll", "OpenMPI_jll", "PkgVersion", "PrecompileTools", "Requires", "Serialization", "Sockets"]
git-tree-sha1 = "4e3136db3735924f96632a5b40a5979f1f53fa07"
uuid = "da04e1cc-30fd-572f-bb4f-1f8673147195"
version = "0.20.19"

    [deps.MPI.extensions]
    AMDGPUExt = "AMDGPU"
    CUDAExt = "CUDA"

    [deps.MPI.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"

[[deps.MPICH_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Hwloc_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "MPIPreferences", "TOML"]
git-tree-sha1 = "4099bb6809ac109bfc17d521dad33763bcf026b7"
uuid = "7cb0a576-ebde-5e09-9194-50597f1243b4"
version = "4.2.1+1"

[[deps.MPIPreferences]]
deps = ["Libdl", "Preferences"]
git-tree-sha1 = "c105fe467859e7f6e9a852cb15cb4301126fac07"
uuid = "3da0fdf6-3ccc-4f1b-acd9-58baa6c99267"
version = "0.1.11"

[[deps.MPItrampoline_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "MPIPreferences", "TOML"]
git-tree-sha1 = "ce0ca3dd147c43de175c5aff161315a424f4b8ac"
uuid = "f1f71cc9-e9ae-5b93-9b94-4fe0e1ad3748"
version = "5.3.3+1"

[[deps.MacroTools]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "2fa9ee3e63fd3a4f7a9a4f4744a52f4856de82df"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.13"

[[deps.ManualMemory]]
git-tree-sha1 = "bcaef4fc7a0cfe2cba636d84cda54b5e4e4ca3cd"
uuid = "d125e4d3-2237-4719-b19c-fa641b8a4667"
version = "0.1.8"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"

[[deps.MbedTLS]]
deps = ["Dates", "MbedTLS_jll", "MozillaCACerts_jll", "NetworkOptions", "Random", "Sockets"]
git-tree-sha1 = "c067a280ddc25f196b5e7df3877c6b226d390aaf"
uuid = "739be429-bea8-5141-9913-cc70e7f3736d"
version = "1.1.9"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.2+1"

[[deps.Measures]]
git-tree-sha1 = "c13304c81eec1ed3af7fc20e75fb6b26092a1102"
uuid = "442fdcdd-2543-5da2-b0f3-8c86c306513e"
version = "0.3.2"

[[deps.Metis]]
deps = ["CEnum", "LinearAlgebra", "METIS_jll", "SparseArrays"]
git-tree-sha1 = "5582d3b0d794280c9b818ba56ce2b35b108aca41"
uuid = "2679e427-3c69-5b7f-982b-ece356f1e94b"
version = "1.4.1"

    [deps.Metis.extensions]
    MetisGraphs = "Graphs"
    MetisLightGraphs = "LightGraphs"
    MetisSimpleWeightedGraphs = ["SimpleWeightedGraphs", "Graphs"]

    [deps.Metis.weakdeps]
    Graphs = "86223c79-3864-5bf0-83f7-82e725a168b6"
    LightGraphs = "093fc24a-ae57-5d10-9952-331d41423f4d"
    SimpleWeightedGraphs = "47aef6b3-ad0c-573a-a1e2-d07658019622"

[[deps.MicrosoftMPI_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f12a29c4400ba812841c6ace3f4efbb6dbb3ba01"
uuid = "9237b28f-5490-5468-be7b-bb81f5f5e6cf"
version = "10.1.4+2"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "ec4f7fbeab05d7747bdf98eb74d130a2a2ed298d"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.2.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2023.1.10"

[[deps.NLSolversBase]]
deps = ["DiffResults", "Distributed", "FiniteDiff", "ForwardDiff"]
git-tree-sha1 = "a0b464d183da839699f4c79e7606d9d186ec172c"
uuid = "d41bc354-129a-5804-8e4c-c37616107c6c"
version = "7.8.3"

[[deps.NLsolve]]
deps = ["Distances", "LineSearches", "LinearAlgebra", "NLSolversBase", "Printf", "Reexport"]
git-tree-sha1 = "019f12e9a1a7880459d0173c182e6a99365d7ac1"
uuid = "2774e3e8-f4cf-5e23-947b-6d7e65073b56"
version = "4.5.1"

[[deps.NNlib]]
deps = ["Adapt", "Atomix", "ChainRulesCore", "GPUArraysCore", "KernelAbstractions", "LinearAlgebra", "Pkg", "Random", "Requires", "Statistics"]
git-tree-sha1 = "3d4617f943afe6410206a5294a95948c8d1b35bd"
uuid = "872c559c-99b0-510c-b3b7-b6c96a88d5cd"
version = "0.9.17"

    [deps.NNlib.extensions]
    NNlibAMDGPUExt = "AMDGPU"
    NNlibCUDACUDNNExt = ["CUDA", "cuDNN"]
    NNlibCUDAExt = "CUDA"
    NNlibEnzymeCoreExt = "EnzymeCore"

    [deps.NNlib.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    EnzymeCore = "f151be2c-9106-41f4-ab19-57ee4f262869"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "0877504529a3e5c3343c6f8b4c0381e57e4387e4"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.0.2"

[[deps.NearestNeighbors]]
deps = ["Distances", "StaticArrays"]
git-tree-sha1 = "ded64ff6d4fdd1cb68dfcbb818c69e144a5b2e4c"
uuid = "b8a86587-4115-5ab1-83bc-aa920d37bbce"
version = "0.4.16"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.OCCT_jll]]
deps = ["Artifacts", "FreeType2_jll", "JLLWrappers", "Libdl", "Libglvnd_jll", "Pkg", "Xorg_libX11_jll", "Xorg_libXext_jll", "Xorg_libXfixes_jll", "Xorg_libXft_jll", "Xorg_libXinerama_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "acc8099ae8ed10226dc8424fb256ec9fe367a1f0"
uuid = "baad4e97-8daa-5946-aac2-2edac59d34e1"
version = "7.6.2+2"

[[deps.OffsetArrays]]
git-tree-sha1 = "e64b4f5ea6b7389f6f046d13d4896a8f9c1ba71e"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.14.0"
weakdeps = ["Adapt"]

    [deps.OffsetArrays.extensions]
    OffsetArraysAdaptExt = "Adapt"

[[deps.Ogg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "887579a3eb005446d514ab7aeac5d1d027658b8f"
uuid = "e7412a2a-1a6e-54c0-be00-318e2571c051"
version = "1.3.5+1"

[[deps.OhMyThreads]]
deps = ["BangBang", "ChunkSplitters", "StableTasks", "TaskLocalValues"]
git-tree-sha1 = "4b43015960c9e1b660cfae4c1b19c7ed9c86b92c"
uuid = "67456a42-1dca-4109-a031-0a68de7e3ad5"
version = "0.5.2"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.23+4"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.1+2"

[[deps.OpenMPI_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "MPIPreferences", "TOML"]
git-tree-sha1 = "e25c1778a98e34219a00455d6e4384e017ea9762"
uuid = "fe0851c0-eecd-5654-98d4-656369965a5c"
version = "4.1.6+0"

[[deps.OpenSSL]]
deps = ["BitFlags", "Dates", "MozillaCACerts_jll", "OpenSSL_jll", "Sockets"]
git-tree-sha1 = "38cb508d080d21dc1128f7fb04f20387ed4c0af4"
uuid = "4d8831e6-92b7-49fb-bdf8-b643e874388c"
version = "1.4.3"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "3da7367955dcc5c54c1ba4d402ccdc09a1a3e046"
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.0.13+1"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "13652491f6856acfd2db29360e1bbcd4565d04f1"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.5+0"

[[deps.Optim]]
deps = ["Compat", "FillArrays", "ForwardDiff", "LineSearches", "LinearAlgebra", "NLSolversBase", "NaNMath", "Parameters", "PositiveFactorizations", "Printf", "SparseArrays", "StatsBase"]
git-tree-sha1 = "d9b79c4eed437421ac4285148fcadf42e0700e89"
uuid = "429524aa-4258-5aef-a3af-852621145aeb"
version = "1.9.4"

    [deps.Optim.extensions]
    OptimMOIExt = "MathOptInterface"

    [deps.Optim.weakdeps]
    MathOptInterface = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"

[[deps.Optimisers]]
deps = ["ChainRulesCore", "Functors", "LinearAlgebra", "Random", "Statistics"]
git-tree-sha1 = "6572fe0c5b74431aaeb0b18a4aa5ef03c84678be"
uuid = "3bd65402-5787-11e9-1adc-39752487f4e2"
version = "0.3.3"

[[deps.Opus_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51a08fb14ec28da2ec7a927c4337e4332c2a4720"
uuid = "91d4177d-7536-5919-b921-800302f37372"
version = "1.3.2+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "dfdf5519f235516220579f949664f1bf44e741c5"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.6.3"

[[deps.PCRE2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "efcefdf7-47ab-520b-bdef-62a2eaa19f15"
version = "10.42.0+1"

[[deps.PDMats]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "949347156c25054de2db3b166c52ac4728cbad65"
uuid = "90014a1f-27ba-587c-ab20-58faa44d9150"
version = "0.11.31"

[[deps.Parameters]]
deps = ["OrderedCollections", "UnPack"]
git-tree-sha1 = "34c0e9ad262e5f7fc75b10a9952ca7692cfc5fbe"
uuid = "d96e819e-fc66-5662-9728-84c9c7592b0a"
version = "0.12.3"

[[deps.Pardiso]]
deps = ["Libdl", "LinearAlgebra", "MKL_jll", "SparseArrays"]
git-tree-sha1 = "4b618484bf94a52f02595cd73ac8a6417f4c0c70"
uuid = "46dd5b70-b6fb-5a00-ae2d-e8fea33afaf2"
version = "0.5.7"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "8489905bcdbcfac64d1daa51ca07c0d8f0283821"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.1"

[[deps.PartialFunctions]]
deps = ["MacroTools"]
git-tree-sha1 = "47b49a4dbc23b76682205c646252c0f9e1eb75af"
uuid = "570af359-4316-4cb7-8c74-252c00c2016b"
version = "1.2.0"

[[deps.PartitionedArrays]]
deps = ["CircularArrays", "Distances", "FillArrays", "IterativeSolvers", "LinearAlgebra", "MPI", "Printf", "Random", "SparseArrays", "SparseMatricesCSR"]
git-tree-sha1 = "149d2287770c6a533507d74beaa73d76c0727922"
uuid = "5a9dfac6-5c52-46f7-8278-5e2210713be9"
version = "0.3.4"

[[deps.Pipe]]
git-tree-sha1 = "6842804e7867b115ca9de748a0cf6b364523c16d"
uuid = "b98c9c47-44ae-5843-9183-064241ee97a0"
version = "1.3.0"

[[deps.Pixman_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LLVMOpenMP_jll", "Libdl"]
git-tree-sha1 = "35621f10a7531bc8fa58f74610b1bfb70a3cfc6b"
uuid = "30392449-352a-5448-841d-b1acce4e97dc"
version = "0.43.4+0"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "FileWatching", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "REPL", "Random", "SHA", "Serialization", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.10.0"

[[deps.PkgVersion]]
deps = ["Pkg"]
git-tree-sha1 = "f9501cc0430a26bc3d156ae1b5b0c1b47af4d6da"
uuid = "eebad327-c553-4316-9ea0-9fa01ccd7688"
version = "0.3.3"

[[deps.PlotThemes]]
deps = ["PlotUtils", "Statistics"]
git-tree-sha1 = "1f03a2d339f42dca4a4da149c7e15e9b896ad899"
uuid = "ccf2f8ad-2431-5c83-bf29-c5338b663b6a"
version = "3.1.0"

[[deps.PlotUtils]]
deps = ["ColorSchemes", "Colors", "Dates", "PrecompileTools", "Printf", "Random", "Reexport", "Statistics"]
git-tree-sha1 = "7b1a9df27f072ac4c9c7cbe5efb198489258d1f5"
uuid = "995b91a9-d308-5afd-9ec6-746e21dbc043"
version = "1.4.1"

[[deps.Plots]]
deps = ["Base64", "Contour", "Dates", "Downloads", "FFMPEG", "FixedPointNumbers", "GR", "JLFzf", "JSON", "LaTeXStrings", "Latexify", "LinearAlgebra", "Measures", "NaNMath", "Pkg", "PlotThemes", "PlotUtils", "PrecompileTools", "Printf", "REPL", "Random", "RecipesBase", "RecipesPipeline", "Reexport", "RelocatableFolders", "Requires", "Scratch", "Showoff", "SparseArrays", "Statistics", "StatsBase", "UUIDs", "UnicodeFun", "UnitfulLatexify", "Unzip"]
git-tree-sha1 = "442e1e7ac27dd5ff8825c3fa62fbd1e86397974b"
uuid = "91a5bcdd-55d7-5caf-9e0b-520d859cae80"
version = "1.40.4"

    [deps.Plots.extensions]
    FileIOExt = "FileIO"
    GeometryBasicsExt = "GeometryBasics"
    IJuliaExt = "IJulia"
    ImageInTerminalExt = "ImageInTerminal"
    UnitfulExt = "Unitful"

    [deps.Plots.weakdeps]
    FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    GeometryBasics = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
    IJulia = "7073ff75-c697-5162-941a-fcdaad2a7d2a"
    ImageInTerminal = "d8c32880-2388-543b-8c61-d9f865259254"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "JSON", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "ab55ee1510ad2af0ff674dbcced5e94921f867a9"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.59"

[[deps.Polyester]]
deps = ["ArrayInterface", "BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "ManualMemory", "PolyesterWeave", "Requires", "Static", "StaticArrayInterface", "StrideArraysCore", "ThreadingUtilities"]
git-tree-sha1 = "b3e2bae88cf07baf0a051fe09666b8ef97aefe93"
uuid = "f517fe37-dbe3-4b94-8317-1923a5111588"
version = "0.7.14"

[[deps.PolyesterWeave]]
deps = ["BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "Static", "ThreadingUtilities"]
git-tree-sha1 = "240d7170f5ffdb285f9427b92333c3463bf65bf6"
uuid = "1d0040c9-8b98-4ee7-8388-3f51789ca0ad"
version = "0.2.1"

[[deps.PolynomialBases]]
deps = ["ArgCheck", "AutoHashEquals", "FFTW", "FastGaussQuadrature", "LinearAlgebra", "Requires", "SimpleUnPack", "SpecialFunctions"]
git-tree-sha1 = "aa1877430a7e8b0c7a35ea095c415d462af0870f"
uuid = "c74db56a-226d-5e98-8bb0-a6049094aeea"
version = "0.4.21"

[[deps.PositiveFactorizations]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "17275485f373e6673f7e7f97051f703ed5b15b20"
uuid = "85a6dd25-e78a-55b7-8502-1745935b8125"
version = "0.2.4"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "5aa36f7049a63a1528fe8f7c3f2113413ffd4e1f"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.2.1"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "9306f6085165d270f7e3db02af26a400d580f5c6"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.4.3"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[[deps.Profile]]
deps = ["Printf"]
uuid = "9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"

[[deps.PtrArrays]]
git-tree-sha1 = "f011fbb92c4d401059b2212c05c0601b70f8b759"
uuid = "43287f4e-b6f4-7ad1-bb20-aadabca52c3d"
version = "1.2.0"

[[deps.Qt6Base_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Fontconfig_jll", "Glib_jll", "JLLWrappers", "Libdl", "Libglvnd_jll", "OpenSSL_jll", "Vulkan_Loader_jll", "Xorg_libSM_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Xorg_libxcb_jll", "Xorg_xcb_util_cursor_jll", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_keysyms_jll", "Xorg_xcb_util_renderutil_jll", "Xorg_xcb_util_wm_jll", "Zlib_jll", "libinput_jll", "xkbcommon_jll"]
git-tree-sha1 = "37b7bb7aabf9a085e0044307e1717436117f2b3b"
uuid = "c0090381-4147-56d7-9ebc-da0b1113ec56"
version = "6.5.3+1"

[[deps.QuadGK]]
deps = ["DataStructures", "LinearAlgebra"]
git-tree-sha1 = "9b23c31e76e333e6fb4c1595ae6afa74966a729e"
uuid = "1fd47b50-473d-5c70-9696-f719f8f3bcdc"
version = "2.9.4"

[[deps.REPL]]
deps = ["InteractiveUtils", "Markdown", "Sockets", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"

[[deps.Ratios]]
deps = ["Requires"]
git-tree-sha1 = "1342a47bf3260ee108163042310d26f2be5ec90b"
uuid = "c84ed2f1-dad5-54f0-aa8e-dbefe2724439"
version = "0.4.5"
weakdeps = ["FixedPointNumbers"]

    [deps.Ratios.extensions]
    RatiosFixedPointNumbersExt = "FixedPointNumbers"

[[deps.RealDot]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "9f0a1b71baaf7650f4fa8a1d168c7fb6ee41f0c9"
uuid = "c1ae055f-0cd5-4b69-90a6-9a35b1a98df9"
version = "0.1.0"

[[deps.RecipesBase]]
deps = ["PrecompileTools"]
git-tree-sha1 = "5c3d09cc4f31f5fc6af001c250bf1278733100ff"
uuid = "3cdcf5f2-1ef4-517c-9805-6587b60abb01"
version = "1.3.4"

[[deps.RecipesPipeline]]
deps = ["Dates", "NaNMath", "PlotUtils", "PrecompileTools", "RecipesBase"]
git-tree-sha1 = "45cf9fd0ca5839d06ef333c8201714e888486342"
uuid = "01d81517-befc-4cb6-b9ec-a95719d0359c"
version = "0.6.12"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.RelocatableFolders]]
deps = ["SHA", "Scratch"]
git-tree-sha1 = "ffdaf70d81cf6ff22c2b6e733c900c3321cab864"
uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"
version = "1.0.1"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "838a3a4188e2ded87a4f9f184b4b0d78a1e91cb7"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.3.0"

[[deps.Richardson]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "48f038bfd83344065434089c2a79417f38715c41"
uuid = "708f8203-808e-40c0-ba2d-98a6953ed40d"
version = "1.4.2"

[[deps.Rmath]]
deps = ["Random", "Rmath_jll"]
git-tree-sha1 = "f65dcb5fa46aee0cf9ed6274ccbd597adc49aa7b"
uuid = "79098fc4-a85e-5d69-aa6a-4863f24498fa"
version = "0.7.1"

[[deps.Rmath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "d483cd324ce5cf5d61b77930f0bbd6cb61927d21"
uuid = "f50d1b31-88e8-58de-be2c-1cc44531875f"
version = "0.4.2+0"

[[deps.SCOTCH_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "7110b749766853054ce8a2afaa73325d72d32129"
uuid = "a8d0f55d-b80e-548d-aff6-1a04c175f0f9"
version = "6.1.3+0"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SIMDTypes]]
git-tree-sha1 = "330289636fb8107c5f32088d2741e9fd7a061a5c"
uuid = "94e857df-77ce-4151-89e5-788b33177be4"
version = "0.1.0"

[[deps.Scratch]]
deps = ["Dates"]
git-tree-sha1 = "3bac05bc7e74a75fd9cba4295cde4045d9fe2386"
uuid = "6c6a2e73-6563-6170-7368-637461726353"
version = "1.2.1"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"

[[deps.Setfield]]
deps = ["ConstructionBase", "Future", "MacroTools", "StaticArraysCore"]
git-tree-sha1 = "e2cc6d8c88613c05e1defb55170bf5ff211fbeac"
uuid = "efcf1570-3423-57d1-acb7-fd33fddbac46"
version = "1.1.1"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.Showoff]]
deps = ["Dates", "Grisu"]
git-tree-sha1 = "91eddf657aca81df9ae6ceb20b959ae5653ad1de"
uuid = "992d4aef-0814-514b-bc4d-f2e9a6c4116f"
version = "1.0.3"

[[deps.SimpleBufferStream]]
git-tree-sha1 = "874e8867b33a00e784c8a7e4b60afe9e037b74e1"
uuid = "777ac1f9-54b0-4bf8-805c-2214025038e7"
version = "1.1.0"

[[deps.SimpleUnPack]]
git-tree-sha1 = "58e6353e72cde29b90a69527e56df1b5c3d8c437"
uuid = "ce78b400-467f-4804-87d8-8f486da07d0a"
version = "1.1.0"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "66e0a8e672a0bdfca2c3f5937efb8538b9ddc085"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.2.1"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.10.0"

[[deps.SparseInverseSubset]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "52962839426b75b3021296f7df242e40ecfc0852"
uuid = "dc90abb0-5640-4711-901d-7e5b23a2fada"
version = "0.1.2"

[[deps.SparseMatricesCSR]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "38677ca58e80b5cad2382e5a1848f93b054ad28d"
uuid = "a0a7dd2c-ebf4-11e9-1f05-cf50bc540ca1"
version = "0.6.7"

[[deps.SpecialFunctions]]
deps = ["IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "2f5d4697f21388cbe1ff299430dd169ef97d7e14"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.4.0"
weakdeps = ["ChainRulesCore"]

    [deps.SpecialFunctions.extensions]
    SpecialFunctionsChainRulesCoreExt = "ChainRulesCore"

[[deps.StableTasks]]
git-tree-sha1 = "073d5c20d44129b20fe954720b97069579fa403b"
uuid = "91464d47-22a1-43fe-8b7f-2d57ee82463f"
version = "0.1.5"

[[deps.Static]]
deps = ["IfElse"]
git-tree-sha1 = "d2fdac9ff3906e27f7a618d47b676941baa6c80c"
uuid = "aedffcd0-7271-4cad-89d0-dc628f76c6d3"
version = "0.8.10"

[[deps.StaticArrayInterface]]
deps = ["ArrayInterface", "Compat", "IfElse", "LinearAlgebra", "PrecompileTools", "Requires", "SparseArrays", "Static", "SuiteSparse"]
git-tree-sha1 = "5d66818a39bb04bf328e92bc933ec5b4ee88e436"
uuid = "0d7ed370-da01-4f52-bd93-41d350b8b718"
version = "1.5.0"
weakdeps = ["OffsetArrays", "StaticArrays"]

    [deps.StaticArrayInterface.extensions]
    StaticArrayInterfaceOffsetArraysExt = "OffsetArrays"
    StaticArrayInterfaceStaticArraysExt = "StaticArrays"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "PrecompileTools", "Random", "StaticArraysCore"]
git-tree-sha1 = "9ae599cd7529cfce7fea36cf00a62cfc56f0f37c"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.9.4"
weakdeps = ["ChainRulesCore", "Statistics"]

    [deps.StaticArrays.extensions]
    StaticArraysChainRulesCoreExt = "ChainRulesCore"
    StaticArraysStatisticsExt = "Statistics"

[[deps.StaticArraysCore]]
git-tree-sha1 = "36b3d696ce6366023a0ea192b4cd442268995a0d"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.2"

[[deps.Statistics]]
deps = ["LinearAlgebra", "SparseArrays"]
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.10.0"

[[deps.StatsAPI]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1ff449ad350c9c4cbc756624d6f8a8c3ef56d3ed"
uuid = "82ae8749-77ed-4fe6-ae5f-f523153014b0"
version = "1.7.0"

[[deps.StatsBase]]
deps = ["DataAPI", "DataStructures", "LinearAlgebra", "LogExpFunctions", "Missings", "Printf", "Random", "SortingAlgorithms", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "5cf7606d6cef84b543b483848d4ae08ad9832b21"
uuid = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
version = "0.34.3"

[[deps.StatsFuns]]
deps = ["HypergeometricFunctions", "IrrationalConstants", "LogExpFunctions", "Reexport", "Rmath", "SpecialFunctions"]
git-tree-sha1 = "cef0472124fab0695b58ca35a77c6fb942fdab8a"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.3.1"
weakdeps = ["ChainRulesCore", "InverseFunctions"]

    [deps.StatsFuns.extensions]
    StatsFunsChainRulesCoreExt = "ChainRulesCore"
    StatsFunsInverseFunctionsExt = "InverseFunctions"

[[deps.StrideArraysCore]]
deps = ["ArrayInterface", "CloseOpenIntervals", "IfElse", "LayoutPointers", "LinearAlgebra", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface", "ThreadingUtilities"]
git-tree-sha1 = "25349bf8f63aa36acbff5e3550a86e9f5b0ef682"
uuid = "7792a7ef-975c-4747-a70f-980b88e8d1da"
version = "0.5.6"

[[deps.StructArrays]]
deps = ["ConstructionBase", "DataAPI", "Tables"]
git-tree-sha1 = "f4dc295e983502292c4c3f951dbb4e985e35b3be"
uuid = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
version = "0.6.18"
weakdeps = ["Adapt", "GPUArraysCore", "SparseArrays", "StaticArrays"]

    [deps.StructArrays.extensions]
    StructArraysAdaptExt = "Adapt"
    StructArraysGPUArraysCoreExt = "GPUArraysCore"
    StructArraysSparseArraysExt = "SparseArrays"
    StructArraysStaticArraysExt = "StaticArrays"

[[deps.SuiteSparse]]
deps = ["Libdl", "LinearAlgebra", "Serialization", "SparseArrays"]
uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.2.1+1"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "LinearAlgebra", "OrderedCollections", "TableTraits"]
git-tree-sha1 = "cb76cf677714c095e535e3501ac7954732aeea2d"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.11.1"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.0"

[[deps.TaskLocalValues]]
git-tree-sha1 = "eb0b8d147eb907a9ad3fd952da7c6a053b29ae28"
uuid = "ed4db957-447d-4319-bfb6-7fa9ae7ecf34"
version = "0.1.1"

[[deps.TensorCore]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1feb45f88d133a655e001435632f019a9a1bcdb6"
uuid = "62fd8b95-f654-4bbd-a8a5-9c27f68ccd50"
version = "0.1.1"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.TestItems]]
git-tree-sha1 = "8621ba2637b49748e2dc43ba3d84340be2938022"
uuid = "1c621080-faea-4a02-84b6-bbd5e436b8fe"
version = "0.1.1"

[[deps.ThreadingUtilities]]
deps = ["ManualMemory"]
git-tree-sha1 = "eda08f7e9818eb53661b3deb74e3159460dfbc27"
uuid = "8290d209-cae3-49c0-8002-c8c24d57dab5"
version = "0.5.2"

[[deps.TranscodingStreams]]
git-tree-sha1 = "5d54d076465da49d6746c647022f3b3674e64156"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.10.8"
weakdeps = ["Random", "Test"]

    [deps.TranscodingStreams.extensions]
    TestExt = ["Test", "Random"]

[[deps.Tricks]]
git-tree-sha1 = "eae1bb484cd63b36999ee58be2de6c178105112f"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.8"

[[deps.URIs]]
git-tree-sha1 = "67db6cc7b3821e19ebe75791a9dd19c9b1188f2b"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.5.1"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

[[deps.UnPack]]
git-tree-sha1 = "387c1f73762231e86e0c9c5443ce3b4a0a9a0c2b"
uuid = "3a884ed6-31ef-47d7-9d2a-63182c4928ed"
version = "1.0.2"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"

[[deps.UnicodeFun]]
deps = ["REPL"]
git-tree-sha1 = "53915e50200959667e78a92a418594b428dffddf"
uuid = "1cfade01-22cf-5700-b092-accc4b62d6e1"
version = "0.4.1"

[[deps.Unitful]]
deps = ["Dates", "LinearAlgebra", "Random"]
git-tree-sha1 = "dd260903fdabea27d9b6021689b3cd5401a57748"
uuid = "1986cc42-f94f-5a68-af5c-568840ba703d"
version = "1.20.0"
weakdeps = ["ConstructionBase", "InverseFunctions"]

    [deps.Unitful.extensions]
    ConstructionBaseUnitfulExt = "ConstructionBase"
    InverseFunctionsUnitfulExt = "InverseFunctions"

[[deps.UnitfulLatexify]]
deps = ["LaTeXStrings", "Latexify", "Unitful"]
git-tree-sha1 = "e2d817cc500e960fdbafcf988ac8436ba3208bfd"
uuid = "45397f5d-5981-4c77-b2b3-fc36d6e9b728"
version = "1.6.3"

[[deps.UnsafeAtomics]]
git-tree-sha1 = "6331ac3440856ea1988316b46045303bef658278"
uuid = "013be700-e6cd-48c3-b4a1-df204f14c38f"
version = "0.2.1"

[[deps.UnsafeAtomicsLLVM]]
deps = ["LLVM", "UnsafeAtomics"]
git-tree-sha1 = "d9f5962fecd5ccece07db1ff006fb0b5271bdfdd"
uuid = "d80eeb9a-aca5-4d75-85e5-170c8b632249"
version = "0.1.4"

[[deps.Unzip]]
git-tree-sha1 = "ca0969166a028236229f63514992fc073799bb78"
uuid = "41fe7b60-77ed-43a1-b4f0-825fd5a5650d"
version = "0.2.0"

[[deps.VTKBase]]
git-tree-sha1 = "c2d0db3ef09f1942d08ea455a9e252594be5f3b6"
uuid = "4004b06d-e244-455f-a6ce-a5f9919cc534"
version = "1.0.1"

[[deps.Vulkan_Loader_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Wayland_jll", "Xorg_libX11_jll", "Xorg_libXrandr_jll", "xkbcommon_jll"]
git-tree-sha1 = "2f0486047a07670caad3a81a075d2e518acc5c59"
uuid = "a44049a8-05dd-5a78-86c9-5fde0876e88c"
version = "1.3.243+0"

[[deps.Wayland_jll]]
deps = ["Artifacts", "EpollShim_jll", "Expat_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "7558e29847e99bc3f04d6569e82d0f5c54460703"
uuid = "a2964d1f-97da-50d4-b82a-358c7fce9d89"
version = "1.21.0+1"

[[deps.Wayland_protocols_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "93f43ab61b16ddfb2fd3bb13b3ce241cafb0e6c9"
uuid = "2381bf8a-dfd0-557d-9999-79630e7b1b91"
version = "1.31.0+0"

[[deps.WeightInitializers]]
deps = ["ChainRulesCore", "LinearAlgebra", "PartialFunctions", "PrecompileTools", "Random", "SpecialFunctions", "Statistics"]
git-tree-sha1 = "f0e6760ef9d22f043710289ddf29e4a4048c4822"
uuid = "d49dbf32-c5c2-4618-8acc-27bb2598ef2d"
version = "0.1.7"

    [deps.WeightInitializers.extensions]
    WeightInitializersCUDAExt = "CUDA"

    [deps.WeightInitializers.weakdeps]
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"

[[deps.WoodburyMatrices]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "c1a7aa6219628fcd757dede0ca95e245c5cd9511"
uuid = "efce3f68-66dc-5838-9240-27a6d6f5f9b6"
version = "1.0.0"

[[deps.WriteVTK]]
deps = ["Base64", "CodecZlib", "FillArrays", "LightXML", "TranscodingStreams", "VTKBase"]
git-tree-sha1 = "48b9e8e9c83865e99e57f027d4edfa94e0acddae"
uuid = "64499a7a-5c06-52f2-abe2-ccb03c286192"
version = "1.19.1"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Zlib_jll"]
git-tree-sha1 = "52ff2af32e591541550bd753c0da8b9bc92bb9d9"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.12.7+0"

[[deps.XSLT_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgcrypt_jll", "Libgpg_error_jll", "Libiconv_jll", "Pkg", "XML2_jll", "Zlib_jll"]
git-tree-sha1 = "91844873c4085240b95e795f692c4cec4d805f8a"
uuid = "aed1982a-8fda-507f-9586-7b0439959a61"
version = "1.1.34+0"

[[deps.XZ_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "ac88fb95ae6447c8dda6a5503f3bafd496ae8632"
uuid = "ffd25f8a-64ca-5728-b0f7-c24cf3aae800"
version = "5.4.6+0"

[[deps.Xorg_libICE_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "326b4fea307b0b39892b3e85fa451692eda8d46c"
uuid = "f67eecfb-183a-506d-b269-f58e52b52d7c"
version = "1.1.1+0"

[[deps.Xorg_libSM_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libICE_jll"]
git-tree-sha1 = "3796722887072218eabafb494a13c963209754ce"
uuid = "c834827a-8449-5923-a945-d239c165b7dd"
version = "1.2.4+0"

[[deps.Xorg_libX11_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxcb_jll", "Xorg_xtrans_jll"]
git-tree-sha1 = "afead5aba5aa507ad5a3bf01f58f82c8d1403495"
uuid = "4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"
version = "1.8.6+0"

[[deps.Xorg_libXau_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "6035850dcc70518ca32f012e46015b9beeda49d8"
uuid = "0c0b7dd1-d40b-584c-a123-a41640f87eec"
version = "1.0.11+0"

[[deps.Xorg_libXcursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXfixes_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "12e0eb3bc634fa2080c1c37fccf56f7c22989afd"
uuid = "935fb764-8cf2-53bf-bb30-45bb1f8bf724"
version = "1.2.0+4"

[[deps.Xorg_libXdmcp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "34d526d318358a859d7de23da945578e8e8727b7"
uuid = "a3789734-cfe1-5b06-b2d0-1dd0d9d62d05"
version = "1.1.4+0"

[[deps.Xorg_libXext_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libX11_jll"]
git-tree-sha1 = "d2d1a5c49fae4ba39983f63de6afcbea47194e85"
uuid = "1082639a-0dae-5f34-9b06-72781eeb8cb3"
version = "1.3.6+0"

[[deps.Xorg_libXfixes_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "0e0dc7431e7a0587559f9294aeec269471c991a4"
uuid = "d091e8ba-531a-589c-9de9-94069b037ed8"
version = "5.0.3+4"

[[deps.Xorg_libXft_jll]]
deps = ["Fontconfig_jll", "Libdl", "Pkg", "Xorg_libXrender_jll"]
git-tree-sha1 = "754b542cdc1057e0a2f1888ec5414ee17a4ca2a1"
uuid = "2c808117-e144-5220-80d1-69d4eaa9352c"
version = "2.3.3+1"

[[deps.Xorg_libXi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXfixes_jll"]
git-tree-sha1 = "89b52bc2160aadc84d707093930ef0bffa641246"
uuid = "a51aa0fd-4e3c-5386-b890-e753decda492"
version = "1.7.10+4"

[[deps.Xorg_libXinerama_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll"]
git-tree-sha1 = "26be8b1c342929259317d8b9f7b53bf2bb73b123"
uuid = "d1454406-59df-5ea1-beac-c340f2130bc3"
version = "1.1.4+4"

[[deps.Xorg_libXrandr_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "34cea83cb726fb58f325887bf0612c6b3fb17631"
uuid = "ec84b674-ba8e-5d96-8ba1-2a689ba10484"
version = "1.5.2+4"

[[deps.Xorg_libXrender_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libX11_jll"]
git-tree-sha1 = "47e45cd78224c53109495b3e324df0c37bb61fbe"
uuid = "ea2f1a96-1ddc-540d-b46f-429655e07cfa"
version = "0.9.11+0"

[[deps.Xorg_libpthread_stubs_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8fdda4c692503d44d04a0603d9ac0982054635f9"
uuid = "14d82f49-176c-5ed1-bb49-ad3f5cbd8c74"
version = "0.1.1+0"

[[deps.Xorg_libxcb_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "XSLT_jll", "Xorg_libXau_jll", "Xorg_libXdmcp_jll", "Xorg_libpthread_stubs_jll"]
git-tree-sha1 = "b4bfde5d5b652e22b9c790ad00af08b6d042b97d"
uuid = "c7cfdc94-dc32-55de-ac96-5a1b8d977c5b"
version = "1.15.0+0"

[[deps.Xorg_libxkbfile_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libX11_jll"]
git-tree-sha1 = "730eeca102434283c50ccf7d1ecdadf521a765a4"
uuid = "cc61e674-0454-545c-8b26-ed2c68acab7a"
version = "1.1.2+0"

[[deps.Xorg_xcb_util_cursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_jll", "Xorg_xcb_util_renderutil_jll"]
git-tree-sha1 = "04341cb870f29dcd5e39055f895c39d016e18ccd"
uuid = "e920d4aa-a673-5f3a-b3d7-f755a4d47c43"
version = "0.1.4+0"

[[deps.Xorg_xcb_util_image_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "0fab0a40349ba1cba2c1da699243396ff8e94b97"
uuid = "12413925-8142-5f55-bb0e-6d7ca50bb09b"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libxcb_jll"]
git-tree-sha1 = "e7fd7b2881fa2eaa72717420894d3938177862d1"
uuid = "2def613f-5ad1-5310-b15b-b15d46f528f5"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_keysyms_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "d1151e2c45a544f32441a567d1690e701ec89b00"
uuid = "975044d2-76e6-5fbe-bf08-97ce7c6574c7"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_renderutil_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "dfd7a8f38d4613b6a575253b3174dd991ca6183e"
uuid = "0d47668e-0667-5a69-a72c-f761630bfb7e"
version = "0.3.9+1"

[[deps.Xorg_xcb_util_wm_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "e78d10aab01a4a154142c5006ed44fd9e8e31b67"
uuid = "c22f9ab0-d5fe-5066-847c-f4bb1cd4e361"
version = "0.4.1+1"

[[deps.Xorg_xkbcomp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxkbfile_jll"]
git-tree-sha1 = "330f955bc41bb8f5270a369c473fc4a5a4e4d3cb"
uuid = "35661453-b289-5fab-8a00-3d9160c6a3a4"
version = "1.4.6+0"

[[deps.Xorg_xkeyboard_config_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xkbcomp_jll"]
git-tree-sha1 = "691634e5453ad362044e2ad653e79f3ee3bb98c3"
uuid = "33bec58e-1273-512f-9401-5d533626f822"
version = "2.39.0+0"

[[deps.Xorg_xtrans_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "e92a1a012a10506618f10b7047e478403a046c77"
uuid = "c5fb5394-a638-5e4d-96e5-b29de1b5cf10"
version = "1.5.0+0"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.2.13+1"

[[deps.Zstd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "e678132f07ddb5bfa46857f0d7620fb9be675d3b"
uuid = "3161d3a3-bdf6-5164-811a-617609db77b4"
version = "1.5.6+0"

[[deps.Zygote]]
deps = ["AbstractFFTs", "ChainRules", "ChainRulesCore", "DiffRules", "Distributed", "FillArrays", "ForwardDiff", "GPUArrays", "GPUArraysCore", "IRTools", "InteractiveUtils", "LinearAlgebra", "LogExpFunctions", "MacroTools", "NaNMath", "PrecompileTools", "Random", "Requires", "SparseArrays", "SpecialFunctions", "Statistics", "ZygoteRules"]
git-tree-sha1 = "19c586905e78a26f7e4e97f81716057bd6b1bc54"
uuid = "e88e6eb3-aa80-5325-afca-941959d7151f"
version = "0.6.70"

    [deps.Zygote.extensions]
    ZygoteColorsExt = "Colors"
    ZygoteDistancesExt = "Distances"
    ZygoteTrackerExt = "Tracker"

    [deps.Zygote.weakdeps]
    Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
    Distances = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.ZygoteRules]]
deps = ["ChainRulesCore", "MacroTools"]
git-tree-sha1 = "27798139afc0a2afa7b1824c206d5e87ea587a00"
uuid = "700de1a5-db45-46bc-99cf-38207098b444"
version = "0.2.5"

[[deps.eudev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "gperf_jll"]
git-tree-sha1 = "431b678a28ebb559d224c0b6b6d01afce87c51ba"
uuid = "35ca27e7-8b34-5b7f-bca9-bdc33f59eb06"
version = "3.2.9+0"

[[deps.fzf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "a68c9655fbe6dfcab3d972808f1aafec151ce3f8"
uuid = "214eeab7-80f7-51ab-84ad-2988db7cef09"
version = "0.43.0+0"

[[deps.gmsh_jll]]
deps = ["Artifacts", "Cairo_jll", "CompilerSupportLibraries_jll", "FLTK_jll", "FreeType2_jll", "GLU_jll", "GMP_jll", "HDF5_jll", "JLLWrappers", "JpegTurbo_jll", "LLVMOpenMP_jll", "Libdl", "Libglvnd_jll", "METIS_jll", "MMG_jll", "OCCT_jll", "Xorg_libX11_jll", "Xorg_libXext_jll", "Xorg_libXfixes_jll", "Xorg_libXft_jll", "Xorg_libXinerama_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "bdc2fa0a123008ad941cabb0ad88c571e696af2e"
uuid = "630162c2-fc9b-58b3-9910-8442a8a132e6"
version = "4.13.0+1"

[[deps.gperf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3516a5630f741c9eecb3720b1ec9d8edc3ecc033"
uuid = "1a1c6b14-54f6-533d-8383-74cd7377aa70"
version = "3.1.1+0"

[[deps.libaec_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "46bf7be2917b59b761247be3f317ddf75e50e997"
uuid = "477f73a3-ac25-53e9-8cc3-50b2fa2566f0"
version = "1.1.2+0"

[[deps.libaom_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1827acba325fdcdf1d2647fc8d5301dd9ba43a9d"
uuid = "a4ae2306-e953-59d6-aa16-d00cac43593b"
version = "3.9.0+0"

[[deps.libass_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "5982a94fcba20f02f42ace44b9894ee2b140fe47"
uuid = "0ac62f75-1d6f-5e53-bd7c-93b484bb37c0"
version = "0.15.1+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.8.0+1"

[[deps.libevdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "141fe65dc3efabb0b1d5ba74e91f6ad26f84cc22"
uuid = "2db6ffa8-e38f-5e21-84af-90c45d0032cc"
version = "1.11.0+0"

[[deps.libfdk_aac_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "daacc84a041563f965be61859a36e17c4e4fcd55"
uuid = "f638f0a6-7fb0-5443-88ba-1cc74229b280"
version = "2.0.2+0"

[[deps.libinput_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "eudev_jll", "libevdev_jll", "mtdev_jll"]
git-tree-sha1 = "ad50e5b90f222cfe78aa3d5183a20a12de1322ce"
uuid = "36db933b-70db-51c0-b978-0f229ee0e533"
version = "1.18.0+0"

[[deps.libpng_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "d7015d2e18a5fd9a4f47de711837e980519781a4"
uuid = "b53b4c65-9356-5827-b1ea-8c7a1a84506f"
version = "1.6.43+1"

[[deps.libvorbis_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ogg_jll", "Pkg"]
git-tree-sha1 = "b910cb81ef3fe6e78bf6acee440bda86fd6ae00c"
uuid = "f27f6e37-5d2b-51aa-960f-b287f2bc3b7a"
version = "1.3.7+1"

[[deps.mtdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "814e154bdb7be91d78b6802843f76b6ece642f11"
uuid = "009596ad-96f7-51b1-9f1b-5ce2d5e8a71e"
version = "1.1.6+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.52.0+1"

[[deps.oneTBB_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "7d0ea0f4895ef2f5cb83645fa689e52cb55cf493"
uuid = "1317d2d5-d96f-522e-a858-c73665f53c3e"
version = "2021.12.0+0"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.4.0+2"

[[deps.x264_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fea590b89e6ec504593146bf8b988b2c00922b2"
uuid = "1270edf5-f2f9-52d2-97e9-ab00b5d0237a"
version = "2021.5.5+0"

[[deps.x265_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ee567a171cce03570d77ad3a43e90218e38937a9"
uuid = "dfaa095f-4041-5dcd-9319-2fabd8486b76"
version = "3.5.0+0"

[[deps.xkbcommon_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Wayland_jll", "Wayland_protocols_jll", "Xorg_libxcb_jll", "Xorg_xkeyboard_config_jll"]
git-tree-sha1 = "9c304562909ab2bab0262639bd4f444d7bc2be37"
uuid = "d8fb68d0-12a3-5cfd-a85a-d49703b185fd"
version = "1.4.1+1"
"""

# ╔═╡ Cell order:
# ╠═7e849952-e7f7-416c-b008-2078172dd26e
# ╟─91bd4b96-3381-401f-80c8-ab22b42ccd69
# ╟─aedee969-e868-4c4b-88dc-3eda6f05b8c3
# ╟─f4fadc84-f802-11ee-20c1-e5e52daf6688
# ╠═2f14bfb7-5811-4092-9675-cb9f80a8a16d
# ╠═5e1cda6d-e06b-4160-9fb9-fe19125faccc
# ╠═9631b4e0-9583-4b3d-863c-fb2a97b8c8de
# ╠═982c4f4e-3ffe-48cd-8786-ffdc0d009c54
# ╠═ae53dffa-eee9-4ceb-8722-43eb95252a2e
# ╠═4958b150-19b7-4a28-b88f-9087bdafaa0a
# ╠═a552c91e-0aa6-4666-acd4-3b6d5a39176f
# ╠═1dfee3b9-47da-43bb-9578-15a384c8654f
# ╠═605d877f-925e-42aa-9680-0046b30ec565
# ╠═1fb005ba-ba3c-40da-8132-86bd9368a210
# ╠═280ea22e-eef9-436a-bd1f-a9fc1b640437
# ╠═8700eb22-d2f5-4750-8fb9-51d443f16422
# ╠═7c7c6bde-3e75-4c49-ab18-87f28a7db82c
# ╠═0dcbb440-b3af-450d-98f4-2f39acc87ab2
# ╠═5cbcdb73-437c-435f-8d34-efeb2a69926e
# ╠═a17d22f8-c625-4b3f-a235-369cb5fb655d
# ╠═dc9219f0-dbfe-42b5-b47b-10afd03b95b0
# ╠═fc00caf8-a1b1-4153-9b3c-f127b0aed0d7
# ╠═1cc2d2b1-b711-45db-a661-07c77fe6cb77
# ╠═f20bdad5-eeda-44ab-8fb7-97407dbbf4b4
# ╠═9317ca6a-04e9-49f0-b66b-41e179ff9228
# ╠═d0464f28-06df-4237-8de8-63cc7cd886b3
# ╠═3f92bb62-00e4-4e7f-8be4-e9a23acb8f56
# ╟─79f5d795-1da0-4a7a-8657-fd7d492a9d8c
# ╠═4ee2f3ce-72c7-4740-81e5-9e48c3b58e30
# ╠═2a71be41-20f8-4e3b-9981-066458639ba4
# ╟─f2f37ad9-f24a-4423-99a1-44fe1bd287b8
# ╠═d0e5e872-0ba6-4019-8133-380b442d223c
# ╠═bf70a619-509a-424e-9f55-77cf99df7d55
# ╠═79b34a3e-02fd-4888-927f-fa552b55e44e
# ╠═1aa9d66a-00f3-4a95-a37b-25066b790460
# ╠═77478768-20be-4b40-a491-4eff4c2aeb5c
# ╠═b92ad479-953d-44cf-9983-c0b808ee370b
# ╠═8c419a5c-f98e-4a55-86c1-d1442e492a32
# ╠═9f450eca-40bf-4d41-ba2e-de7ee336813d
# ╠═24a7fd22-4169-4cb1-a038-8e3864cd5079
# ╠═8eb9aac0-0999-4e43-b4cb-6ff9724c9d7c
# ╠═21fb6e44-a465-4a75-8ad6-f8b52540edbc
# ╠═39a88b33-438f-4b42-b5f4-011eb11f7521
# ╠═8a15d18c-b7da-4cb2-83ca-9f2c11d427bf
# ╠═6050d1d1-71ab-4d27-a25e-47e8b6b7ad77
# ╠═d52e3930-82ee-4e69-8569-da89ff44bf56
# ╟─2156d0cf-6ffb-4920-8217-f8e581428a12
# ╠═cd53e724-62d6-4b53-9501-307f7dae419c
# ╠═88f5488a-a0d9-4ca0-8158-5d3a0433385f
# ╠═f271d049-9cb1-47b7-af74-31f83898aebd
# ╠═563a57bc-af31-47bd-a84a-4308a7372a3d
# ╠═840ebab9-8c5a-40cd-9b58-313b56dfd79f
# ╠═4ffad3ed-d91c-4d2f-ba45-9cc3d83ebfee
# ╠═5dd8f3b3-f412-4b86-834b-86b43ab35f2a
# ╠═f6ff0f0b-05f2-42e4-ae86-1672f017edf9
# ╟─e4928bb3-70d2-4dc2-a56a-eac2a01b2dca
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
