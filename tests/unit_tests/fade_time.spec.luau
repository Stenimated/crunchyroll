local animation_solver = require("@src/animation_solver")
local process = require("@lune/process")
local TEST, CASE, CHECK, FINISH = require("@vendor/testkit").test()

local function eq(a: number, b: number, elipson: number): boolean
	return math.abs(a - b) < elipson
end

TEST("animation track solver", function()
	for _, case in
		{
			{ time = 0, eq = 1, length = 1, start = 0, stop = 0 }, -- should be one
			{ time = 1, eq = 1, length = 1, start = 0, stop = 0 }, -- should be one

			{ time = 0, eq = 0, length = 1, start = 0.1, stop = 0.1 }, -- should be zero

			-- fade in
			{ time = 0.05, eq = 0.5, length = 1, start = 0.1, stop = 0.1 },
			{ time = 0.025, eq = 0.25, length = 1, start = 0.1, stop = 0.1 },
			{ time = 0.5, eq = 1, length = 1, start = 0.1, stop = 0.1 },

			{ time = 1, eq = 0, length = 1, start = 0.1, stop = 0.1 }, -- should be zero

			-- fade out
			{ time = 1 - 0.05, eq = 0.5, length = 1, start = 0.1, stop = 0.1 },
			{ time = 1 - 0.025, eq = 0.25, length = 1, start = 0.1, stop = 0.1 },
			{ time = 1 - 0.15, eq = 0.5, length = 1, start = 0.3, stop = 0.3 },
		}
	do
		CASE(`time={case.time} length={case.length} expects={case.eq}`)
		local alpha = animation_solver.solve_fade_time_influence(
			case.time,
			case.length,
			case.start,
			case.stop
		)
		CHECK(eq(alpha, case.eq, 0.0001))
	end

	CASE("nan case: alpha==1 length==1")
	do
		local alpha = animation_solver.solve_fade_time_influence(1, 1, 0, 0)

		CHECK(alpha == alpha)
	end

	CASE("nan case: alpha==0 length==0")
	do
		local alpha = animation_solver.solve_fade_time_influence(0, 0, 0, 0)

		CHECK(alpha == alpha)
	end

	CASE("nan case: alpha==1 length==0")
	do
		local alpha = animation_solver.solve_fade_time_influence(1, 0, 0, 0)

		CHECK(alpha == alpha)
	end

	CASE("nan case: alpha==0 length==1")
	do
		local alpha = animation_solver.solve_fade_time_influence(0, 1, 0, 0)

		CHECK(alpha == alpha)
	end

	CASE("nan case: alpha==1 length==1")
	do
		local alpha = animation_solver.solve_fade_time_influence(1, 1, 0, 0)

		CHECK(alpha == alpha)
	end
end)

if not FINISH() then
	process.exit(1)
end

return true
