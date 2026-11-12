extends Node3D
class_name TrackingManager

enum EstimatorMode {
	ALPHA_BETA,
	ALPHA_BETA_GAMMA,
	ADAPTIVE
}

@export_group("References")
@export var radar_sensor: Node

@export_group("Tracking")
@export var enabled: bool = true
@export var estimator_mode: EstimatorMode = EstimatorMode.ADAPTIVE

@export_group("Filter Gains")
@export_range(0.0, 1.0, 0.01) var alpha: float = 0.6
@export_range(0.0, 1.0, 0.01) var beta: float = 0.3
@export_range(0.0, 0.1, 0.001) var gamma: float = 0.025

@export_group("Adaptive Sensor Health")
@export var degraded_threshold: float = 0.85
@export var recovered_threshold: float = 0.25

@export_range(1, 20, 1)
var confirm_degradation: int = 5

@export_range(1, 20, 1)
var confirm_recovery: int = 3

@export_group("Debug")
@export var print_filter_switches: bool = true

@export_group("Debug")
@export var print_observations: bool = false

var latest_measurement: Vector3 = Vector3.ZERO
var latest_iff: String = "UNKNOWN"

var has_observation: bool = false
var observation_count: int = 0


class FilterState:
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var acceleration: Vector3 = Vector3.ZERO

	var initialized: bool = false
	var use_acceleration: bool = false

	func _init(acceleration_enabled: bool) -> void:
		use_acceleration = acceleration_enabled

	func update(
		measurement: Vector3,
		dt: float,
		alpha_gain: float,
		beta_gain: float,
		gamma_gain: float
	) -> Vector3:
		if not initialized:
			position = measurement
			initialized = true
			return Vector3.ZERO

		var predicted_position: Vector3 = position + velocity * dt
		var predicted_velocity: Vector3 = velocity

		if use_acceleration:
			predicted_position += 0.5 * acceleration * dt ** 2
			predicted_velocity += acceleration * dt

		var residual: Vector3 = measurement - predicted_position

		position = predicted_position + alpha_gain * residual
		velocity = predicted_velocity + (beta_gain / dt) * residual

		if use_acceleration:
			acceleration += (2.0 * gamma_gain / dt ** 2) * residual

		return residual

	func forecast(horizon: float) -> Vector3:
		var result: Vector3 = position + velocity * horizon

		if use_acceleration:
			result += 0.5 * acceleration * horizon ** 2

		return result

var ab_filter := FilterState.new(false)
var abg_filter := FilterState.new(true)

var selected_estimator: String = "ABG"
var innovation_ema: float = 0.0

var proposed_estimator: String = ""
var consecutive_confirmations: int = 0

var filter_switch_count: int = 0
var sensor_health_status: String = "INITIALIZING"


func update_sensor_health(innovation: Vector3) -> void:
	# The radar's measurement disagreement is used as a
	# proxy for sensor consistency.
	innovation_ema = lerpf(
		innovation_ema,
		innovation.length_squared(),
		0.12
	)

	var candidate: String = selected_estimator
	var required_confirmations: int = confirm_degradation

	if innovation_ema > degraded_threshold:
		candidate = "AB"
		required_confirmations = confirm_degradation
		sensor_health_status = "DEGRADED"

	elif innovation_ema < recovered_threshold:
		candidate = "ABG"
		required_confirmations = confirm_recovery
		sensor_health_status = "NOMINAL"

	else:
		sensor_health_status = "TRANSITIONAL"

	# Avoid rapidly switching estimators.
	if candidate != selected_estimator:
		if candidate == proposed_estimator:
			consecutive_confirmations += 1
		else:
			proposed_estimator = candidate
			consecutive_confirmations = 1

		if consecutive_confirmations >= required_confirmations:
			var previous: String = selected_estimator

			selected_estimator = candidate
			proposed_estimator = ""
			consecutive_confirmations = 0

			filter_switch_count += 1

			if print_filter_switches:
				print(
					"[TrackingManager] Filter switch: ",
					previous, " -> ", selected_estimator,
					" | Innovation EMA: ",
					snappedf(innovation_ema, 0.001),
					" | Status: ", sensor_health_status
				)
	else:
		proposed_estimator = ""
		consecutive_confirmations = 0

func _ready() -> void:
	if radar_sensor == null:
		push_warning("TrackingManager: RadarSensor is not assigned.")
		return

	if not radar_sensor.has_signal("observation_received"):
		push_error("TrackingManager: Radar signal not found.")
		return

	radar_sensor.connect(
		"observation_received",
		Callable(self, "_on_observation_received")
	)

	print("TrackingManager initialized.")



func _on_observation_received(
	measured_position: Vector3,
	identification: String
) -> void:
	if not enabled:
		return

	latest_measurement = measured_position
	latest_iff = identification

	has_observation = true
	observation_count += 1

# Use the configured radar scan interval.
# This is appropriate for our current fixed-interval test scene.
	var dt: float = float(
	radar_sensor.get("scan_interval")
	)

	if dt <= 0.0:
		push_error("TrackingManager: Invalid radar scan interval.")
		return

	# Update Alpha-Beta and retain its prediction residual.
	var innovation: Vector3 = ab_filter.update(
		measured_position,
		dt,
		alpha,
		beta,
		0.0
	)

	# Update Alpha-Beta-Gamma independently.
	abg_filter.update(
		measured_position,
		dt,
		alpha,
		beta,
		gamma
	)

	# The first observation initializes the estimators.
	# Begin evaluating consistency from observation two.
	if observation_count > 1:
		update_sensor_health(innovation)
	if print_observations:
		print(
		"[Sensor Health] ",
		"Status: ", sensor_health_status,
		" | Innovation EMA: ",
		snappedf(innovation_ema, 0.001),
		" | Selected: ", selected_estimator
		)


	if print_observations:
		print(
			"[TrackingManager] Filter dt: ", dt,
			"[TrackingManager] Observation #",
			observation_count,
			" | Position: ", latest_measurement,
			" | IFF: ", latest_iff
		)

		print(
			"[Filters] AB: ",
			ab_filter.forecast(0.5),
			" | ABG: ",
			abg_filter.forecast(0.5)
		)


func get_estimated_position() -> Vector3:
	if not has_observation:
		return Vector3.ZERO

	match estimator_mode:
		EstimatorMode.ALPHA_BETA:
			return ab_filter.position

		EstimatorMode.ALPHA_BETA_GAMMA:
			return abg_filter.position

		EstimatorMode.ADAPTIVE:
			if selected_estimator == "AB":
				return ab_filter.position
			return abg_filter.position

	return Vector3.ZERO



func get_predicted_position(horizon: float) -> Vector3:
	if not has_observation:
		return Vector3.ZERO

	match estimator_mode:
		EstimatorMode.ALPHA_BETA:
			return ab_filter.forecast(horizon)

		EstimatorMode.ALPHA_BETA_GAMMA:
			return abg_filter.forecast(horizon)

		EstimatorMode.ADAPTIVE:
			if selected_estimator == "AB":
				return ab_filter.forecast(horizon)

			return abg_filter.forecast(horizon)

	return Vector3.ZERO
