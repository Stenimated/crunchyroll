local animation_asset = require("./roblox/animation_asset")
local create_rig = require("./rig")
local easings = require(script.Parent.easings)

export type AnimationTrack = {
	-- 0-1
	alpha: number,

	-- 0-1
	start_fade_time: number,
	stop_fade_time: number,
	weight: number,

	-- arbitrary number
	priority: number,
}

local function vector_lerp(a: vector, b: vector, t: number): vector
	return a + (b - a) * t
end

local function quat_nlerp(
	a_vector: vector,
	a_scalar: number,
	b_vector: vector,
	b_scalar: number,
	t: number
): (vector, number)
	local quat_vector = vector_lerp(a_vector, b_vector, t)
	local quat_scalar = math.lerp(a_scalar, b_scalar, t)

	local magnitude =
		math.sqrt((vector.dot(quat_vector, quat_vector) + (quat_scalar * quat_scalar)))

	return quat_vector / magnitude, quat_scalar / magnitude
end

local function solve_fade_time_influence(
	real_time: number,
	animation_length: number,
	start_fade_time: number,
	stop_fade_time: number
): number
	if real_time <= start_fade_time then
		return math.min(1, 1 - ((start_fade_time - real_time) / start_fade_time))
	elseif real_time >= (animation_length + stop_fade_time) then
		return math.min(
			1,
			1 - ((real_time - (animation_length - stop_fade_time)) / stop_fade_time)
		)
	else
		return 1
	end
end

local function animation_solver(
	rig: create_rig.Identity,
	tracks: {
		[animation_asset.Identity]: AnimationTrack,
	},
	root: CFrame
)
	local limb_transforms = rig.limb_transforms
	for _, limb in limb_transforms do
		limb.priority = -1
	end

	local total_weight = 0
	for _, track in tracks do
		total_weight += track.weight
	end

	for animation, playback in tracks do
		local priority = playback.priority
		local real_time = animation.length * playback.alpha
		local influence = (playback.weight / total_weight)
			* solve_fade_time_influence(
				real_time,
				animation.length,
				playback.start_fade_time,
				playback.stop_fade_time
			)

		-- Figure out which keyframes to interpolate between

		local keyframe_times = animation.keyframe_times

		local high: number = #keyframe_times
		local low: number = 1

		while high > low do
			local index: number = bit32.rshift(low + high, 1)

			if keyframe_times[index + 1] >= real_time then
				high = index
			else
				low = index + 1
			end
		end

		local pose_time_after: number? = keyframe_times[high + 1]
		local pose_time_before: number? = keyframe_times[high]
		local poses_before: animation_asset.Poses? = animation.keyframe_poses[high]
		local poses_after: animation_asset.Poses? = animation.keyframe_poses[high + 1]

		-- Solve limb transforms
		for index, node in limb_transforms do
			if node.priority > priority then
				continue
			end

			-- find hulls in the animation
			local left_pose = poses_before and poses_before[index]
			local time_before = pose_time_before
			local left_pose_pointer = if animation.keyframe_hulls[index]
					and animation.keyframe_hulls[index][high]
				then animation.keyframe_hulls[index][high][1]
				else 1
			if left_pose_pointer then
				left_pose = animation.keyframe_poses[left_pose_pointer][index]
				time_before = keyframe_times[left_pose_pointer]
			end

			local right_pose = poses_after and poses_after[index]
			local time_after = pose_time_after
			local pointer = animation.keyframe_hulls[index]
				and animation.keyframe_hulls[index][high + 1]
			if pointer then
				local right_pose_pointer = pointer[2]
				right_pose = animation.keyframe_poses[right_pose_pointer][index]
				time_after = keyframe_times[right_pose_pointer]
			end

			if left_pose and right_pose then
			    --stylua: ignore
			    local alpha = (real_time - (time_before :: number)) / ((time_after :: number) - (time_before :: number))
				if left_pose.type == "n" then
				    --stylua: ignore start
					local interpolated_alpha = left_pose.easing_function(alpha)
					local position = vector_lerp(left_pose.position, right_pose.position, interpolated_alpha)

					local quat_vector, quat_scalar = quat_nlerp(
						left_pose.quat_vector, left_pose.quat_scalar,
						right_pose.quat_vector, right_pose.quat_scalar,
						interpolated_alpha
					)

					node.position = vector_lerp(node.position, position, influence)
					node.quat_vector, node.quat_scalar = quat_nlerp(
						node.quat_vector, node.quat_scalar,
						quat_vector, quat_scalar,
						influence
					)

					--stylua: ignore end
				elseif left_pose.type == "t" then
					local transfrom_left, transform_right =
						left_pose.transform, right_pose.transform
					local tangents, easing = left_pose.tangents, left_pose.easing

					local x1, y1, z1, rx1, ry1, rz1 =
						transfrom_left[1],
						transfrom_left[2],
						transfrom_left[3],
						transfrom_left[4],
						transfrom_left[5],
						transfrom_left[6]
					local x2, y2, z2, rx2, ry2, rz2 =
						transform_right[1],
						transform_right[2],
						transform_right[3],
						transform_right[4],
						transform_right[5],
						transform_right[6]

					local t1, t2, t3, t4, t5, t6 =
						tangents[1],
						tangents[1],
						tangents[1],
						tangents[1],
						tangents[1],
						tangents[1]

					local x = if t1
						then easings.tangent(x1, x2, t1[1], t1[2], alpha)
						else math.lerp(x1, x2, easing[1](alpha))
					local y = if t2
						then easings.tangent(y1, y2, t2[1], t2[2], alpha)
						else math.lerp(y1, y2, easing[2](alpha))
					local z = if t3
						then easings.tangent(z1, z2, t3[1], t3[2], alpha)
						else math.lerp(z1, z2, easing[3](alpha))
					local rx = if t4
						then easings.tangent(rx1, rx2, t4[1], t4[2], alpha)
						else math.lerp(rx1, rx2, easing[4](alpha))
					local ry = if t5
						then easings.tangent(ry1, ry2, t5[1], t5[2], alpha)
						else math.lerp(ry1, ry2, easing[5](alpha))
					local rz = if t6
						then easings.tangent(rz1, rz2, t6[1], t6[2], alpha)
						else math.lerp(rz1, rz2, easing[6](alpha))

					local cx, cy, cz = math.cos(rx / 2), math.cos(ry / 2), math.cos(rz / 2)
					local sx, sy, sz = math.sin(rx / 2), math.sin(ry / 2), math.sin(rz / 2)

					local quat_vector = vector.create(
						sx * cy * cz - cx * sy * sz, -- X
						cx * sy * cz + sx * cy * sz, -- Y
						cx * cy * sz - sx * sy * cz -- Z
					)
					local quat_scalar = cx * cy * cz + sx * sy * sz

					node.position = vector.create(x, y, z)
					node.quat_vector, node.quat_scalar = quat_vector, quat_scalar

					-- local x = math.lerp(x1, x2, alpha)
					-- local y = math.lerp(y1, y2, alpha)
					-- local z = math.lerp(z1, z2, alpha)
					-- local rx = math.lerp(rx1, rx2, alpha)
					-- local ry = math.lerp(ry1, ry2, alpha)
					-- local rz = math.lerp(rz1, rz2, alpha)

					-- if rig.limbs[index].name == "Left Arm" then
					-- 	-- print("zz", high + 1, "highest", )
					-- 	-- print("keyframe_times", keyframe_times)
					-- 	-- print("real time", real_time)
					-- end
				end

				node.priority = priority
			elseif left_pose then
				node.position = vector_lerp(node.position, left_pose.position, influence)

				node.quat_vector, node.quat_scalar = quat_nlerp(
					node.quat_vector,
					node.quat_scalar,
					left_pose.quat_vector,
					left_pose.quat_scalar,
					influence
				)
				node.priority = priority
			end
			--stylua: ignore end
		end
	end

	local result_coordinate_frames: { [string]: CFrame } = rig.result_coordinate_frames
	result_coordinate_frames["root"] = root

	for index, limb in rig.limbs do
		local limb_transform = limb_transforms[index]

		local position = limb_transform.position
		local quat_vector = limb_transform.quat_vector
		local quat_scalar = limb_transform.quat_scalar

		--stylua: ignore
		local transform = CFrame.new(
			position.x, position.y, position.z,
			quat_vector.x, quat_vector.y, quat_vector.z, quat_scalar
		)

		result_coordinate_frames[limb.name] = result_coordinate_frames[limb.depends_on]
			* limb.c0
			* transform
			* limb.c1
	end
end

return {
	solve_fade_time_influence = solve_fade_time_influence,

	solver = animation_solver,
}
