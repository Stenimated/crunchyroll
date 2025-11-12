local animation_asset = require("./roblox/animation_asset")
local create_rig = require("./rig")

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
type total_weight = {
	previous: total_weight?,
	total: number,
	tracks: { [animation_asset.Identity]: number },
}

local function quat_nlerp(
	a_vector: vector,
	a_scalar: number,
	b_vector: vector,
	b_scalar: number,
	t: number
): (vector, number)
	local quat_vector = vector.lerp(a_vector, b_vector, t)
	local quat_scalar = math.lerp(a_scalar, b_scalar, t)

	local magnitude =
		math.sqrt((vector.dot(quat_vector, quat_vector) + (quat_scalar * quat_scalar)))

	return quat_vector / magnitude, quat_scalar / magnitude
end

--- https://www.desmos.com/calculator/9wt45xeilg
--- difference is you pass in the time with animation length, not alpha
local function solve_fade_time_influence(
	time: number,
	animation_length: number,
	start_fade_time: number,
	stop_fade_time: number
): number
	if time <= start_fade_time then
		return math.min(1, 1 - ((start_fade_time - time) / start_fade_time))
	elseif time >= (animation_length - stop_fade_time) then
		return math.min(1, 1 - ((time - (animation_length - stop_fade_time)) / stop_fade_time))
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
	-- local id = math.random()

	--- [limb_index][priority] = [singly linked list]
	--- linked list starts from the highest priority and ends at the lowest priority
	local limbs_total_weights: { [number]: { [number]: total_weight, highest_priority: number } } =
		{}

	-- local isDebug = false
	-- if tracks["debug"] then
	-- 	isDebug = true
	-- 	tracks["debug"] = nil
	-- end

	for limb_index, weight in rig.limbs do
		local previously_created

		for animation, track in tracks do
			local animation_weight = track.weight
				* solve_fade_time_influence(
					animation.length * track.alpha,
					animation.length,
					track.start_fade_time,
					track.stop_fade_time
				)

			local limb_weight = animation_weight
			if not animation.animated[limb_index] then
				limb_weight = 0
			end

			local total_weights: { [number]: total_weight, highest_priority: number } =
				limbs_total_weights[limb_index]
			if not total_weights then
				total_weights = { highest_priority = -math.huge }
				limbs_total_weights[limb_index] = total_weights
			end

			if not total_weights[track.priority] then
				local info = {
					previous = nil,
					total = limb_weight,
					tracks = { [animation] = limb_weight },
					priority = track.priority,
				}
				total_weights[track.priority] = info

				if track.priority > total_weights.highest_priority then
					total_weights.highest_priority = track.priority
				end
				if previously_created then
					if previously_created.priority > track.priority then
						if previously_created.previous then
							if previously_created.previous.priority < track.priority then
								local splice = previously_created.previous
								previously_created.previous = info
								info.previous = splice
								-- print("insert")
								-- print("existing + splice scenario", id)
							else
								info.previous = previously_created.previous
								-- print("ah")
								-- print("existing + lower priority", id)
							end
						else
							if previously_created.priority < track.priority then
								info.previous = previously_created
								-- print("none + lower priority", id)
								-- print("b")
							else
								previously_created.previous = info
								-- print("none + higher priority", id)
								-- print(
								-- 	"ga",
								-- 	previously_created.priority,
								-- 	info.priority,
								-- 	total_weights,
								-- 	animation_weight,
								-- 	track.weight,
								-- 	limb_weight,
								-- 	info
								-- )
							end
						end
					end
				end
				previously_created = info

				-- if limb_index == 6 and isDebug then
				-- 	if info.priority == 1 then
				-- 		print("priorityy one", limbs_total_weights[6], info)
				-- 	elseif info.priority == 2 then
				-- 		print(
				-- 			"priorityy twoo",
				-- 			limbs_total_weights[6],
				-- 			info,
				-- 			previously_created
				-- 		)
				-- 	end
				-- end
			else
				total_weights[track.priority].total += limb_weight
				total_weights[track.priority].tracks[animation] = limb_weight
			end
		end
	end

	for index, joint in limbs_total_weights do
		local hp = joint[joint.highest_priority]
		if hp and hp.total < 1 then
			-- this is the precentage we have to fill
			local left = 1 - hp.total

			-- if index == 6 and isDebug then
			-- 	print("joints", joint, "id", id)
			-- end

			local leaf = hp
			while leaf and left > 0 do
				local next = leaf.previous

				if next then
					if next.total <= left then
						left -= next.total -- just eat this up
						-- if isDebug then
						-- 	print(next.total)
						-- end
					else
						-- map the new inflence
						local new_precentage, total_current = left, next.total
						for animation, weight in next.tracks do
							local track_inflence = weight / total_current
							next.tracks[animation] = new_precentage * track_inflence
						end
						next.total = new_precentage
						-- if isDebug then
						-- 	print(next.total)
						-- end
					end
				end
				leaf = next
			end
		else
			local leaf = hp
			while leaf do
				local next = leaf.previous
				if next then
					next.total = 0
				end
				leaf = next
			end
		end
	end

	-- if isDebug then
	-- 	for _, v in tracks do
	-- 		if v.priority == 2 then
	-- 			-- print(limbs_total_weights[6])
	-- 			-- print(limbs_total_weights[rig.limb_name_to_index["Left Arm"]][2].total)
	-- 		end
	-- 	end
	-- end

	for animation, playback in tracks do
		local priority = playback.priority
		local real_time = animation.length * playback.alpha

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
			local kaioken = limbs_total_weights[index]
			if not kaioken then
				continue
			end

			local priority_list = kaioken[priority]
			if not priority_list or priority_list.total == 0 then
				continue
			end

			local influence = priority_list.tracks[animation]
			if influence == 0 then -- this is not playing
				continue
			end
			-- if isDebug and priority == 2 then
			-- 	print("ok", influence, priority_list)
			-- elseif isDebug and priority == 1 then
			-- 	print("bruh", influence)
			-- end

			-- find holes in the animation
			local left_pose = poses_before and poses_before[index]
			local time_before = pose_time_before
			if left_pose == nil then
				local left_pose_pointer = if animation.keyframe_holes[index]
					then animation.keyframe_holes[index][high][1]
					else 1

				left_pose = animation.keyframe_poses[left_pose_pointer][index]
				time_before = keyframe_times[left_pose_pointer]
			end

			local right_pose = poses_after and poses_after[index]
			local time_after = pose_time_after
			local pointer = animation.keyframe_holes[index]
				and animation.keyframe_holes[index][high + 1]
			if pointer then
				local right_pose_pointer = pointer[2]
				right_pose = animation.keyframe_poses[right_pose_pointer][index]
				time_after = keyframe_times[right_pose_pointer]
			end

			--stylua: ignore start
			if left_pose and right_pose  then
				local alpha = left_pose.easing_function((real_time - (time_before :: number)) / ((time_after :: number) - (time_before :: number)))
				local position = vector.lerp(left_pose.position, right_pose.position, alpha)

				local quat_vector, quat_scalar = quat_nlerp(
					left_pose.quat_vector, left_pose.quat_scalar,
					right_pose.quat_vector, right_pose.quat_scalar,
					alpha
				)

				node.position = vector.lerp(node.position, position, influence)
				node.quat_vector, node.quat_scalar = quat_nlerp(
					node.quat_vector, node.quat_scalar,
					quat_vector, quat_scalar,
					influence
				)

				-- node.priority = priority
			elseif left_pose then
				node.position = vector.lerp(node.position, left_pose.position, influence)

				node.quat_vector, node.quat_scalar = quat_nlerp(
					node.quat_vector, node.quat_scalar,
					left_pose.quat_vector, left_pose.quat_scalar, influence
				)
				-- node.priority = priority
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
