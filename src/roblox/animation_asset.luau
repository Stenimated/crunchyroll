local easing = require("../easings")
local easing_enum_map = require("./easing_enum_map")
local rig = require("../rig")

export type Axises = "x" | "y" | "z" | "rx" | "ry" | "rz"
local axises: { Axises } = { "x", "y", "z", "rx", "ry", "rz" }

export type EasingFunction = (alpha: number) -> number
export type Tangent = { number } -- [left tangent, right tangent]

export type PoseNode = {
	position: vector,
	quat_vector: vector,
	quat_scalar: number,
	transform: { number },

	type: "n", -- normal
	easing_function: EasingFunction,
} | {
	position: vector,
	quat_vector: vector,
	quat_scalar: number,
	transform: { number },

	type: "t", --tangent
	tangents: { [number]: Tangent },
	easing: { [number]: EasingFunction },
}
export type KeyframeHull = { number } -- range[left, right] -> keyframe_time index
export type Poses = { PoseNode }

type KeyframeNode = {
	time: number,
	poses: { [string]: PoseNode },
}

export type Identity = {
	keyframe_times: { number },
	keyframe_poses: { Poses },
	keyframe_hulls: { [number]: { KeyframeHull } },
	length: number,
}

type CurveAnimationJoint = Folder & {
	Position: Vector3Curve,
	Rotation: RotationCurve | EulerRotationCurve,
}
type MarkerCurveValue = {
	Time: number,
	Value: string,
}
type CurveAnimationTimeframe = { [number]: { [string]: PoseNode } }

local function serialize_cframe(cframe: CFrame)
	local axis, angle = cframe:ToAxisAngle()

	local half_angle = angle / 2
	local position = cframe.Position :: any
	local quat_vector = axis * math.sin(half_angle)
	local quat_scalar = math.cos(half_angle)

	return position, quat_vector, quat_scalar
end

local function keyframe_sequence_recursive_tree_from_pose(
	poses: { [string]: PoseNode },
	root_pose: Pose
)
	local sub_poses = root_pose:GetSubPoses() :: { Pose }

	for _, sub_pose in sub_poses do
		keyframe_sequence_recursive_tree_from_pose(poses, sub_pose)
	end

	-- example, a keyframe that is deeply nested. but ancestor(s) is not animated, roblox will indicate this with .Weight == 0
	if root_pose.Weight == 0 then
		return
	end
	local cframe = root_pose.CFrame
	local position, quat_vector, quat_scalar = serialize_cframe(cframe)

	local rx, ry, rz = cframe:ToEulerAngles(Enum.RotationOrder.ZYX)
	-- TODO weird type erro
	poses[root_pose.Name] = {
		type = "n",
		position = position,
		quat_vector = quat_vector,
		quat_scalar = quat_scalar,
		transform = { cframe.X, cframe.Y, cframe.Z, rx, ry, rz },
		easing_function = easing_enum_map[root_pose.EasingStyle][root_pose.EasingDirection],
	} :: any
end

local function curve_animation_recursive_tree_from_pose(
	poses: CurveAnimationTimeframe,
	root_pose: CurveAnimationJoint
)
	for _, sub_pose in root_pose:GetChildren() do
		if sub_pose:IsA("Folder") then
			curve_animation_recursive_tree_from_pose(poses, sub_pose :: any)
		end
	end

	-- local position, quat_vector, quat_scalar = serialize_cframe(root_pose.CFrame)
	local vector3_curve = root_pose:FindFirstChild("Position") :: Vector3Curve?
	local rotation_curve =
		root_pose:FindFirstChild("Rotation") :: (EulerRotationCurve | RotationCurve)?

	if not vector3_curve or not rotation_curve then
		return
	end

	-- gotta collect these curves and bunch them up into packages
	local vector3_keys: { [Axises]: FloatCurve } = {
		x = vector3_curve:X(),
		y = vector3_curve:Y(),
		z = vector3_curve:Z(),
	}
	if rotation_curve:IsA("EulerRotationCurve") then
		vector3_keys.rx = rotation_curve:X()
		vector3_keys.ry = rotation_curve:Y()
		vector3_keys.rz = rotation_curve:Z()
	end

	local timeline: {
		[number]: {
			transform: { number },
			t: { [number]: Tangent },
			e: { [number]: EasingFunction },
		},
	} =
		{}

	local function insert_float_curve(
		timeline: typeof(timeline),
		axis: Axises,
		key_point: FloatCurveKey
	)
		local existing = timeline[key_point.Time]
		if not existing then
			existing = {
				transform = {},
				t = {},
				e = {},
			}
			timeline[key_point.Time] = existing
		end

		local value = key_point.Value
		local axis_index = table.find(axises, axis)
		assert(axis_index)

		existing.transform[axis_index] = value

		if key_point.Interpolation == Enum.KeyInterpolationMode.Cubic then
			existing.t[axis_index] = {
				key_point.LeftTangent or 0,
				key_point.RightTangent or 0,
			}
		else
			existing.e[axis_index] = easing_enum_map[key_point.Interpolation]
		end
	end

	for axis, value in vector3_keys :: { [Axises]: FloatCurve } do
		local keys = value:GetKeys()
		if #keys > 0 then
			for _, key: FloatCurveKey in value:GetKeys() do
				insert_float_curve(timeline, axis, key)
			end
		else
			local float = FloatCurveKey.new(0, 0, Enum.KeyInterpolationMode.Linear)
			insert_float_curve(timeline, axis, float)
		end
	end

	if rotation_curve:IsA("RotationCurve") then
		for _, rotation_curve_key in rotation_curve:GetKeys() :: { RotationCurveKey } do
			local existing = timeline[rotation_curve_key.Time]
			if not existing then
				existing = {
					transform = {},
					t = {},
					e = {},
				}
				timeline[rotation_curve_key.Time] = existing
			end

			existing.transform[4] = rotation_curve_key.Value

			if rotation_curve_key.Interpolation == Enum.KeyInterpolationMode.Cubic then
				local int = {
					rotation_curve_key.LeftTangent or 0,
					rotation_curve_key.RightTangent or 0,
				}

				existing.t[4] = int
				existing.t[5] = int
				existing.t[6] = int
			else
				existing.e[4] = easing_enum_map[rotation_curve_key.Interpolation]
				existing.e[5] = easing_enum_map[rotation_curve_key.Interpolation]
				existing.e[6] = easing_enum_map[rotation_curve_key.Interpolation]
			end
		end
	end

	local pose_key = root_pose.Name

	-- after collecting we can create a cframe
	for elapsed, inter in timeline do
		local elapsed_folder = poses[elapsed]
		if not elapsed_folder then
			elapsed_folder = {}
			poses[elapsed] = elapsed_folder
		end

		assert(not elapsed_folder[pose_key], "this should be unqiue everytime")

		local transform = inter.transform

		local cframe = CFrame.new(transform[1] or 0, transform[2] or 0, transform[3] or 0)

		if rotation_curve:IsA("RotationCurve") then
			cframe *= transform[4] :: any
		else
			cframe *= CFrame.fromEulerAngles(
				transform[4] or 0,
				transform[5] or 0,
				transform[6] or 0,
				rotation_curve.RotationOrder
			)
		end

		local position, quat_vector, quat_scalar = serialize_cframe(cframe)
		local rx, ry, rz = cframe:ToEulerAngles(Enum.RotationOrder.ZYX)

		for i = 1, 6 do
			if inter.t[i] == nil and inter.e[i] == nil then
				inter.e[i] = easing_enum_map[Enum.KeyInterpolationMode.Linear] :: any
			end
		end

		transform[4], transform[5], transform[6] = rx, ry, rz
		elapsed_folder[pose_key] = {
			type = "t",
			position = position,
			quat_vector = quat_vector,
			quat_scalar = quat_scalar,
			transform = { position.X, position.Y, position.Z, rx, ry, rz },
			tangents = inter.t,
			easing = inter.e,
		}
	end
end

local function load_keyframe_nodes(rig: rig.Identity, keyframe_nodes: { KeyframeNode })
	table.sort(keyframe_nodes, function(left: KeyframeNode, right: KeyframeNode)
		return left.time < right.time
	end)

	local limb_name_to_index = rig._limb_name_to_index
	local hulls: { [number]: { KeyframeHull } } = {}

	-- previous keyframe that had no hulls, [limb_index]: keyframe_node_index
	local no_hull: { [number]: number } = {}
	local future_right: { [number]: true | nil } = {}

	local len_nodes = #keyframe_nodes
	for index, node in keyframe_nodes do
		for limb_name, limb_index in limb_name_to_index do
			-- if we are the first keyframe, we should fill in the default pose
			if index == 1 and node.poses[limb_name] == nil then
				node.poses[limb_name] = {
					t = "n",
					position = vector.zero,
					quat_vector = vector.zero,
					quat_scalar = 1,
					easing_function = easing.linear,
				} :: any
			end

			if node.poses[limb_name] then
				no_hull[limb_index] = index
				future_right[limb_index] = nil
			elseif not node.poses[limb_name] and future_right[limb_index] == nil then
				-- there's a hull, find the left and right keyframes and fill the indexes between
				-- left should always be avaliable

				local left_pointer = no_hull[limb_index]
				assert(left_pointer, "there should always be a left pointer keyframe")

				local right_pointer
				for right_pose_counter = index + 1, #keyframe_nodes do
					if keyframe_nodes[right_pose_counter].poses[limb_name] then
						right_pointer = right_pose_counter
						break
					end
				end
				future_right[limb_index] = true

				-- if this is nil, the limb does not have any future keyframes
				if right_pointer then
					local hull = {
						left_pointer,
						right_pointer or left_pointer,
					}

					local limb_hull = hulls[limb_index]
					if limb_hull == nil then
						limb_hull = {}
						hulls[limb_index] = limb_hull
					end

					for fill_in = left_pointer + 1, if right_pointer then right_pointer else len_nodes do
						limb_hull[fill_in] = hull
					end
				end
			end
		end
	end

	local length = keyframe_nodes[#keyframe_nodes].time
	local keyframe_times = {}
	local keyframe_poses = {}

	for index, keyframe_node in keyframe_nodes do
		local mapped_poses: Poses = {}
		for name, pose in keyframe_node.poses do
			local limb_index = limb_name_to_index[name]
			if limb_index ~= nil then
				mapped_poses[limb_index] = pose
			end
		end

		keyframe_poses[index] = mapped_poses
		keyframe_times[index] = keyframe_node.time
	end

	return {
		keyframe_times = keyframe_times,
		keyframe_poses = keyframe_poses,
		length = length,
		keyframe_hulls = hulls,
	}
end

local animation_asset = {}

function animation_asset.load_keyframe_sequence(
	keyframe_sequence: KeyframeSequence,
	rig: rig.Identity
): Identity
	local keyframes = keyframe_sequence:GetKeyframes() :: { Keyframe }

	local markers = {} -- to be used?
	local keyframe_nodes: { KeyframeNode } = {}

	for keyframe_index, keyframe in keyframes do
		for _, marker in keyframe:GetMarkers() :: { KeyframeMarker } do
			markers[marker.Name] = keyframe_index
		end

		local poses: { [string]: PoseNode } = {}
		for _, pose_instance in keyframe:GetPoses() do
			keyframe_sequence_recursive_tree_from_pose(poses, pose_instance :: Pose)
		end

		table.insert(keyframe_nodes, {
			time = keyframe.Time,
			poses = poses,
		})
	end

	return load_keyframe_nodes(rig, keyframe_nodes)
end

function animation_asset.load_curve_animation(curve_animation: CurveAnimation, rig: rig.Identity)
	assert(curve_animation:IsA("CurveAnimation"))

	-- to be used?
	local markers: {
		[string]: { { time: number, value: string } },
	} = {}
	local curve_aniamtiontimeline: CurveAnimationTimeframe = {}

	for _, instance in curve_animation:GetChildren() do
		if instance:IsA("MarkerCurve") then
			local key = instance.Name
			for _, marker in instance:GetMarkers() :: { MarkerCurveValue } do
				local array = markers[key]
				if array == nil then
					array = {}
					markers[key] = array
				end
				table.insert(array, { time = marker.Time, value = marker.Value })
			end
		elseif instance:IsA("Folder") then
			curve_animation_recursive_tree_from_pose(curve_aniamtiontimeline, instance :: any)
		end
	end

	local keyframe_nodes: { KeyframeNode } = {}

	for time, joints in curve_aniamtiontimeline do
		table.insert(keyframe_nodes, {
			time = time,
			poses = joints,
		})
	end

	return load_keyframe_nodes(rig, keyframe_nodes)
end

return animation_asset
