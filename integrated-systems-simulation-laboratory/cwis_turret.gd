extends Node3D
class_name CwisTurret

enum TrackingMode {
	PERFECT,
	RAW_RADAR,
	ALPHA,
	ALPHA_BETA,
	ALPHA_BETA_GAMMA
}

@export_group("Components")
@export var yaw_pivot: Node3D
@export var pitch_pivot: Node3D
@export var radar_sensor: Area3D
@export var target: Node3D  # Ground truth for debugging only

@export_group("Tracking Settings")
@export var tracking_mode: TrackingMode = TrackingMode.ALPHA_BETA
@export_range(0.01, 1.0) var alpha: float = 0.6
@export_range(0.0, 1.0) var beta: float = 0.3
@export_range(0.0,1.0,0.001) var gamma: float = 0.01
@export var contact_timeout: float = 1.0

@export_group("Prediction")
@export var prediction_enabled: bool = true
@export_range(0.0, 2.0, 0.05) var prediction_horizon: float = 0.5

@export_group("Diagnostics")
@export var show_prediction_marker: bool = false
@export var prediction_marker: Node3D

@export_group("Game Firing")
@export var firing_enabled: bool = false
@export var muzzle: Marker3D
@export var projectile_scene: PackedScene

@export_range(1.0, 100.0, 1.0) var rounds_per_second: float = 20.0
@export_range(1, 10, 1) var max_shots_per_frame: int = 4
@export var max_active_projectiles: int = 150

var fire_timer: float = 0.0

var observed_position: Vector3 = Vector3.ZERO
var filtered_position: Vector3 = Vector3.ZERO
var filtered_velocity: Vector3 = Vector3.ZERO
var filtered_acceleration: Vector3 = Vector3.ZERO

var observed_iff: String = "UNKNOWN"
var has_observation: bool = false
var time_since_observation: float = 0.0

var previous_mode: TrackingMode

func _ready() -> void:
	previous_mode = tracking_mode

	if radar_sensor == null:
		push_error("CWIS: No radar sensor assigned!")
		return

	radar_sensor.connect("observation_received",_on_observation_received)

func reset_filter() -> void:
	has_observation = false
	time_since_observation = 0.0
	filtered_position = Vector3.ZERO
	filtered_velocity = Vector3.ZERO
	filtered_acceleration = Vector3.ZERO

func _on_observation_received(measured_position: Vector3, identification: String) -> void:

	# Reinitialize when changing tracking modes.
	if tracking_mode != previous_mode:
		reset_filter()
		previous_mode = tracking_mode

	observed_position = measured_position
	observed_iff = identification

	# Initialize the state from our first observation.
	if not has_observation:
		filtered_position = measured_position
		filtered_velocity = Vector3.ZERO
		has_observation = true
		time_since_observation = 0.0
		return

	var dt = maxf(time_since_observation, 0.0001)

	match tracking_mode:

		TrackingMode.PERFECT:
			pass

		TrackingMode.RAW_RADAR:
			filtered_position = measured_position

		TrackingMode.ALPHA:
			filtered_position = (
				alpha * measured_position
				+ (1.0 - alpha) * filtered_position
			)

		TrackingMode.ALPHA_BETA:
			# Predict using estimated velocity.
			var predicted_position = (
				filtered_position + filtered_velocity * dt
			)

			# Compare predicted and measured positions.
			var residual = measured_position - predicted_position

			# Correct position.
			filtered_position = (
				predicted_position + alpha * residual
			)

			# Correct velocity.
			filtered_velocity += (beta / dt) * residual
			
		TrackingMode.ALPHA_BETA_GAMMA:
			# Predict position with velocity and acceleration.
			var predicted_position = (
			filtered_position
			+ filtered_velocity * dt
			+ 0.5 * filtered_acceleration * dt * dt
			)

			# Predict velocity using acceleration.
			var predicted_velocity = (
			filtered_velocity
			+ filtered_acceleration * dt
			)

			# Difference between the radar measurement
			# and our predicted position.
			var residual = measured_position - predicted_position

			# Correct position.
			filtered_position = (
			predicted_position + alpha * residual
			)

			# Correct velocity.
			filtered_velocity = (
			predicted_velocity + (beta / dt) * residual
			)

			# Correct acceleration.
			filtered_acceleration += (
			(2.0 * gamma / (dt * dt)) * residual
			)
			
	time_since_observation = 0.0

func _physics_process(delta: float) -> void:
	if yaw_pivot == null or pitch_pivot == null:
		return

	if tracking_mode != previous_mode:
		reset_filter()
		previous_mode = tracking_mode

	time_since_observation += delta

	var tracking_position: Vector3

	match tracking_mode:

		TrackingMode.PERFECT:
			if target == null:
				return

			tracking_position = target.global_position

		TrackingMode.RAW_RADAR:
			if not has_observation:
				return
			tracking_position = observed_position

		TrackingMode.ALPHA:
			if not has_observation:
				return
			tracking_position = filtered_position

		TrackingMode.ALPHA_BETA:
			if not has_observation:
				return

			# Stop using an excessively stale contact.
			if time_since_observation > contact_timeout:
				reset_filter()
				return

			# Estimate position between observations.
			tracking_position = (filtered_position + filtered_velocity * time_since_observation)
			
		TrackingMode.ALPHA_BETA_GAMMA:
			if not has_observation:
				return
				
			if time_since_observation > contact_timeout:
				reset_filter()
				return

			tracking_position = (filtered_position + filtered_velocity * time_since_observation 
			+ 0.5 * filtered_acceleration * time_since_observation ** 2
			)

	# YAW
	var yaw_direction = (yaw_pivot.get_parent().to_local(tracking_position) - yaw_pivot.position)

	var desired_yaw = -atan2(yaw_direction.z,yaw_direction.x)

	yaw_pivot.rotation.y = desired_yaw

	# PITCH
	var pitch_direction = ( pitch_pivot.get_parent().to_local(tracking_position) - pitch_pivot.position)

	var horizontal_distance = sqrt( pitch_direction.x ** 2 + pitch_direction.z ** 2)

	var desired_pitch = atan2(pitch_direction.y, horizontal_distance)

	pitch_pivot.rotation.z = desired_pitch

	update_prediction_marker()

	# GAME FIRING
	var contact_is_fresh = (has_observation and time_since_observation <= contact_timeout)
	
	var can_fire = (firing_enabled and contact_is_fresh and observed_iff != "Friendly" and is_instance_valid(target))

	if can_fire:
		can_fire = (not target.is_queued_for_deletion() and target.has_method("permits_engagement") and target.permits_engagement())

	if not can_fire:
		fire_timer = 0.0
		return

	var fire_interval = 1.0 / rounds_per_second

	fire_timer += delta

	var shots_this_frame = 0

	while fire_timer >= fire_interval:
		if shots_this_frame >= max_shots_per_frame:
			break

		var active_count = get_tree().get_nodes_in_group("sim_projectiles").size()

		if active_count >= max_active_projectiles:
			break

		fire_projectile()

		shots_this_frame += 1
		fire_timer -= fire_interval

	# Discard excessive backlog after a slow frame.
	fire_timer = minf(fire_timer, fire_interval)
	
func update_prediction_marker() -> void:
	if prediction_marker == null:
		return

	var should_show = (
		show_prediction_marker
		and prediction_enabled
		and has_observation
		and (tracking_mode == TrackingMode.ALPHA_BETA or tracking_mode == TrackingMode.ALPHA_BETA_GAMMA)
		and time_since_observation <= contact_timeout
	)

	prediction_marker.visible = should_show

	if should_show:
		prediction_marker.global_position = (
			get_predicted_position()
		)

func get_estimated_position() -> Vector3:
	match tracking_mode:
		TrackingMode.PERFECT:
			if target != null:
				return target.global_position

		TrackingMode.RAW_RADAR:
			return observed_position

		TrackingMode.ALPHA:
			return filtered_position

		TrackingMode.ALPHA_BETA:
			return (filtered_position + filtered_velocity * time_since_observation)
			
		TrackingMode.ALPHA_BETA_GAMMA:
			return (filtered_position + filtered_velocity * time_since_observation
			+ 0.5 * filtered_acceleration * time_since_observation ** 2
			)

	return Vector3.ZERO

func fire_projectile() -> void:
	if projectile_scene == null or muzzle == null:
		return

	var projectile = projectile_scene.instantiate()

	get_tree().current_scene.add_child(projectile)

	projectile.add_to_group("sim_projectiles")

	# Copy position and rotation from the muzzle
	projectile.global_transform = muzzle.global_transform

	# Projectile moves along the barrel's +X axis
	projectile.direction = (muzzle.global_transform.basis.x.normalized())
	

func get_predicted_position() -> Vector3:
	var current_estimate = get_estimated_position()

	if not prediction_enabled:
		return current_estimate

	if not has_observation:
		return current_estimate

	if time_since_observation > contact_timeout:
		return current_estimate

	var h = prediction_horizon

	match tracking_mode:
		TrackingMode.ALPHA_BETA:
			return current_estimate + filtered_velocity * h

		TrackingMode.ALPHA_BETA_GAMMA:
			var estimated_velocity_now = (
			filtered_velocity + filtered_acceleration * time_since_observation
			)

			return (current_estimate + estimated_velocity_now * h + 0.5 * filtered_acceleration 
			* h * h
			)

	return current_estimate
