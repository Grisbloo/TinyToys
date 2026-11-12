extends CharacterBody3D

enum State {
	IDLE,
	WALKING,
	GETTING_INTO_BED,
	LYING_DOWN,
	GETTING_UP,
	SITTING_DOWN,
	SITTING,
	STANDING_UP
}

@export var move_speed: float = 1.0
@export var gravity: float = 9.8
@export var bed_transition_time: float = 1.2

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

@onready var visuals: SamanthaVisuals = $SamanthaVisuals


var pending_chair_seat: Marker3D = null

var standing_visual_transform: Transform3D
var standing_left_hip_rotation: Vector3
var standing_right_hip_rotation: Vector3
var standing_left_knee_rotation: Vector3
var standing_right_knee_rotation: Vector3

var state: State = State.IDLE

var pending_bed_position: Marker3D = null
var standing_transform: Transform3D

var original_collision_layer: int
var original_collision_mask: int


func _ready() -> void:
	original_collision_layer = collision_layer
	original_collision_mask = collision_mask


func move_to(destination: Vector3) -> void:
	if state in [
		State.LYING_DOWN,
		State.GETTING_INTO_BED,
		State.GETTING_UP,
		State.SITTING_DOWN,
		State.SITTING,
		State.STANDING_UP
	]:
		return

	pending_bed_position = null
	navigation_agent.target_position = destination
	state = State.WALKING


func go_to_bed(approach: Marker3D, lying_position: Marker3D) -> void:
	if state == State.LYING_DOWN \
	or state == State.GETTING_INTO_BED \
	or state == State.GETTING_UP:
		return

	pending_bed_position = lying_position
	navigation_agent.target_position = approach.global_position
	state = State.WALKING


func _physics_process(delta: float) -> void:
	if state in [
		State.LYING_DOWN,
		State.GETTING_INTO_BED,
		State.GETTING_UP,
		State.SITTING_DOWN,
		State.SITTING,
		State.STANDING_UP
	]:
		velocity = Vector3.ZERO
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if state == State.WALKING:
		var next_position := navigation_agent.get_next_path_position()

		if navigation_agent.is_navigation_finished():
			velocity.x = 0.0
			velocity.z = 0.0

			if pending_bed_position != null:
				lie_down()
			elif pending_chair_seat != null:
				sit_down()
			else:
				state = State.IDLE
		else:
			var direction := next_position - global_position
			direction.y = 0.0
			direction = direction.normalized()

			velocity.x = direction.x * move_speed
			velocity.z = direction.z * move_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	if state != State.GETTING_INTO_BED:
		move_and_slide()


func lie_down() -> void:
	if pending_bed_position == null:
		return

	state = State.GETTING_INTO_BED
	velocity = Vector3.ZERO

	# Remember exactly where Samantha was standing.
	standing_transform = global_transform

	var target_transform := pending_bed_position.global_transform
	pending_bed_position = null

	# Temporarily disable physics collisions.
	collision_layer = 0
	collision_mask = 0

	var tween := create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		self,
		"global_position",
		target_transform.origin,
		bed_transition_time
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(
		self,
		"quaternion",
		target_transform.basis.get_rotation_quaternion(),
		bed_transition_time
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	await tween.finished

	state = State.LYING_DOWN
	print("Samantha is lying down!")


func get_up() -> void:
	if state != State.LYING_DOWN:
		return

	state = State.GETTING_UP
	velocity = Vector3.ZERO

	var tween := create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		self,
		"global_position",
		standing_transform.origin,
		bed_transition_time
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(
		self,
		"quaternion",
		standing_transform.basis.get_rotation_quaternion(),
		bed_transition_time
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	await tween.finished

	# Finish at the exact position and orientation we saved.
	global_transform = standing_transform

	# Restore the collision settings Samantha had before sleeping.
	collision_layer = original_collision_layer
	collision_mask = original_collision_mask

	state = State.IDLE
	print("Samantha got out of bed!")
	
func go_to_chair(approach: Marker3D, seat: Marker3D) -> void:
	if state != State.IDLE and state != State.WALKING:
		return

	pending_bed_position = null
	pending_chair_seat = seat

	navigation_agent.target_position = approach.global_position
	state = State.WALKING


func sit_down() -> void:
	if pending_chair_seat == null:
		return

	state = State.SITTING_DOWN
	velocity = Vector3.ZERO

	# Save the mannequin's original standing pose.
	standing_visual_transform = visuals.transform

	standing_left_hip_rotation = visuals.left_hip.rotation
	standing_right_hip_rotation = visuals.right_hip.rotation
	standing_left_knee_rotation = visuals.left_knee.rotation
	standing_right_knee_rotation = visuals.right_knee.rotation

	# Sitting target.
	var seat := pending_chair_seat
	pending_chair_seat = null

	# Convert world-space chair marker into Samantha's local space.
	var target_position := to_local(seat.global_position)

	var target_rotation := (
		global_transform.basis.inverse() * seat.global_transform.basis
	).get_rotation_quaternion()

	var tween := create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		visuals, "position", target_position, 1.2
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(
		visuals, "quaternion", target_rotation, 1.2
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Bend at the hips.
	tween.tween_property(
		visuals.left_hip, "rotation",
		standing_left_hip_rotation + Vector3(deg_to_rad(90), 0, 0),
		1.2
	)

	tween.tween_property(
		visuals.right_hip, "rotation",
		standing_right_hip_rotation + Vector3(deg_to_rad(90), 0, 0),
		1.2
	)

	# Bend knees in the opposite direction.
	tween.tween_property(
		visuals.left_knee, "rotation",
		standing_left_knee_rotation + Vector3(deg_to_rad(-90), 0, 0),
		1.2
	)

	tween.tween_property(
		visuals.right_knee, "rotation",
		standing_right_knee_rotation + Vector3(deg_to_rad(-90), 0, 0),
		1.2
	)

	await tween.finished

	state = State.SITTING
	print("Samantha is sitting!")
	

func stand_from_chair() -> void:
	if state != State.SITTING:
		return

	state = State.STANDING_UP

	var tween := create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		visuals, "position",
		standing_visual_transform.origin, 1.2
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(
		visuals, "quaternion",
		standing_visual_transform.basis.get_rotation_quaternion(), 1.2
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(
		visuals.left_hip, "rotation",
		standing_left_hip_rotation, 1.2
	)

	tween.tween_property(
		visuals.right_hip, "rotation",
		standing_right_hip_rotation, 1.2
	)

	tween.tween_property(
		visuals.left_knee, "rotation",
		standing_left_knee_rotation, 1.2
	)

	tween.tween_property(
		visuals.right_knee, "rotation",
		standing_right_knee_rotation, 1.2
	)

	await tween.finished

	visuals.transform = standing_visual_transform

	state = State.IDLE
	print("Samantha stood up!")
