
extends Node3D

enum Affiliation {
	FRIENDLY,
	HOSTILE,
	NEUTRAL
}

enum FlightProfile {
	CONSTANT_VELOCITY,
	SINUSOIDAL,
	RANDOM_ACCELERATION,
	CHAOTIC,
	ORBIT
}
enum ThreatKind {
	PRACTICE_DRONE,
	FAST_TARGET,
	HEAVY_TARGET
}

@export_group("Threat Settings")
@export var threat_kind: ThreatKind = ThreatKind.PRACTICE_DRONE
@export var is_threat: bool = true
@export var hit_points: int = 3

@export_group("Flight Settings")
@export var flight_profile: FlightProfile = FlightProfile.CONSTANT_VELOCITY
@export var speed: float = 5.0
@export var horizontal_edge: float = 20.0
@export var vertical_edge: float = 15.0
@export var floor_height: float = 0.0
@export var ball_radius: float = 0.5

@export_group("Sinusoidal Settings")
@export var horizontal_frequency: float = 0.4
@export var vertical_frequency: float = 0.7
@export var vertical_amplitude: float = 5.0

@export_group("Random Acceleration Settings")
@export var acceleration: float = 3.0
@export var max_speed: float = 10.0

@export_group("Orbit Settings")
@export_range(1.0, 100.0, 0.5) var orbit_radius: float = 15.0
@export var orbit_clockwise: bool = false

@export_group("Identification")
@export var affiliation: Affiliation = Affiliation.NEUTRAL
@export var iff_enabled: bool = true

# Movement variables
var horizontal_direction: float = 1.0
var vertical_direction: float = 1.0

var change_timer: float = 0.0
var change_interval: float = 2.0
var current_speed: float = 5.0

var flight_time: float = 0.0
var starting_position: Vector3

# Random acceleration variables
var current_velocity: Vector3 = Vector3.ZERO
var desired_velocity: Vector3 = Vector3.ZERO

func _ready() -> void:
	starting_position = position
	current_speed = speed

	current_velocity = Vector3(
		0.0, 1.0, 1.0
	).normalized() * speed

	desired_velocity = current_velocity

func get_iff_response() -> bool:
	return iff_enabled and affiliation == Affiliation.FRIENDLY
	
func permits_engagement() -> bool:
	return (
		affiliation == Affiliation.HOSTILE
		and is_threat
	)
	
func is_simulated_threat() -> bool:
	return is_threat


func take_hit() -> void:
	hit_points -= 1

	print("Target hit! Remaining HP: ", hit_points)

	if hit_points <= 0:
		print("Target destroyed!")
		queue_free()


func _physics_process(delta: float) -> void:
	flight_time += delta

	match flight_profile:
		FlightProfile.CONSTANT_VELOCITY:
			constant_velocity_movement(delta)

		FlightProfile.SINUSOIDAL:
			sinusoidal_movement()

		FlightProfile.RANDOM_ACCELERATION:
			random_acceleration_movement(delta)

		FlightProfile.CHAOTIC:
			chaotic_movement(delta)
			
		FlightProfile.ORBIT:
			orbital_movement()


# PROFILE 1: Constant velocity
func constant_velocity_movement(delta: float) -> void:
	var movement = Vector3(
		0.0,
		vertical_direction,
		horizontal_direction
	).normalized()

	position += movement * speed * delta
	enforce_boundaries()


# PROFILE 2: Sinusoidal movement
func sinusoidal_movement() -> void:
	position.z = starting_position.z + (
		sin(flight_time * TAU * horizontal_frequency)
		* horizontal_edge
	)

	position.y = starting_position.y + (
		sin(flight_time * TAU * vertical_frequency)
		* vertical_amplitude
	)

	# Keep the target above the floor
	position.y = clampf(
		position.y,
		floor_height + ball_radius,
		vertical_edge
	)


# PROFILE 3: Random acceleration
func random_acceleration_movement(delta: float) -> void:
	change_timer += delta

	if change_timer >= change_interval:
		change_timer = 0.0
		change_interval = randf_range(1.0, 3.0)

		var random_direction = Vector3(
			0.0,
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		).normalized()

		desired_velocity = (
			random_direction * randf_range(2.0, max_speed)
		)

	# Gradually approach the desired velocity
	current_velocity = current_velocity.move_toward(
		desired_velocity,
		acceleration * delta
	)

	position += current_velocity * delta

	# Bounce using actual velocity
	enforce_velocity_boundaries()


# PROFILE 4: Chaotic movement
func chaotic_movement(delta: float) -> void:
	change_timer += delta

	if change_timer >= change_interval:
		change_timer = 0.0
		change_interval = randf_range(0.5, 3.0)

		current_speed = randf_range(3.0, 12.0)

		if randf() < 0.35:
			horizontal_direction *= -1.0

		if randf() < 0.35:
			vertical_direction *= -1.0

	var movement = Vector3(
		0.0,
		vertical_direction,
		horizontal_direction
	).normalized()

	position += movement * current_speed * delta
	enforce_boundaries()
	
#PROFILE 5: Orbit
func orbital_movement() -> void:
	var angular_speed = speed / orbit_radius
	var direction = -1.0 if orbit_clockwise else 1.0

	var angle = flight_time * angular_speed * direction

	position = starting_position + Vector3(
		(cos(angle) - 1.0) * orbit_radius,
		0.0,
		sin(angle) * orbit_radius
	)


# Boundary handling for constant and chaotic movement
func enforce_boundaries() -> void:
	if position.z >= horizontal_edge:
		position.z = horizontal_edge
		horizontal_direction = -1.0

	elif position.z <= -horizontal_edge:
		position.z = -horizontal_edge
		horizontal_direction = 1.0

	var minimum_height = floor_height + ball_radius

	if position.y >= vertical_edge:
		position.y = vertical_edge
		vertical_direction = -1.0

	elif position.y <= minimum_height:
		position.y = minimum_height
		vertical_direction = 1.0


# Boundary handling for acceleration movement
func enforce_velocity_boundaries() -> void:
	if position.z >= horizontal_edge:
		position.z = horizontal_edge
		current_velocity.z = -abs(current_velocity.z)
		desired_velocity.z = -abs(desired_velocity.z)

	elif position.z <= -horizontal_edge:
		position.z = -horizontal_edge
		current_velocity.z = abs(current_velocity.z)
		desired_velocity.z = abs(desired_velocity.z)

	var minimum_height = floor_height + ball_radius

	if position.y >= vertical_edge:
		position.y = vertical_edge
		current_velocity.y = -abs(current_velocity.y)
		desired_velocity.y = -abs(desired_velocity.y)

	elif position.y <= minimum_height:
		position.y = minimum_height
		current_velocity.y = abs(current_velocity.y)
		desired_velocity.y = abs(desired_velocity.y)
