extends Node3D

@export_group("Execution")
@export var enabled: bool = false

@export_group("References")
@export var target: Node3D
@export var turret: CwisTurret

@export_group("Experiment")
@export_range(0.05, 2.0, 0.05) var prediction_horizon: float = 0.5
@export_range(0.05, 1.0, 0.05) var sample_interval: float = 0.2
@export var test_duration: float = 60.0
@export var warmup_duration: float = 3.0

# Experiment clock
var elapsed: float = 0.0
var sample_timer: float = 0.0

# Forecasts awaiting evaluation
var pending_predictions: Array[Dictionary] = []

# Prediction statistics
var completed_predictions: int = 0
var total_error: float = 0.0
var total_squared_error: float = 0.0
var maximum_error: float = 0.0
var total_along_motion_error: float = 0.0

# Stationary baseline statistics
var baseline_total_error: float = 0.0
var baseline_total_squared_error: float = 0.0
var baseline_maximum_error: float = 0.0
var baseline_total_directional_error: float = 0.0

# CSV output
var csv_file: FileAccess
var csv_path: String


func _ready() -> void:
	if not enabled:
		set_physics_process(false)
		return
	if target == null or turret == null:
		push_error("Forecast benchmark: Missing references!")
		set_physics_process(false)
		return

	if prediction_horizon <= 0.0 or sample_interval <= 0.0:
		push_error("Forecast benchmark: Invalid timing settings!")
		set_physics_process(false)
		return

	if test_duration <= warmup_duration:
		push_error("Test duration must exceed warm-up duration!")
		set_physics_process(false)
		return

	csv_path = "user://forecast_%s.csv" % [
		str(Time.get_unix_time_from_system())
	]

	csv_file = FileAccess.open(csv_path, FileAccess.WRITE)

	if csv_file == null:
		push_error("Forecast benchmark: Cannot open CSV!")
		set_physics_process(false)
		return

	csv_file.store_line(
        "issued_at,due_at,prediction_error,"
		+ "baseline_error,prediction_directional_error,"
		+ "baseline_directional_error"
	)

	print("")
	print("========== FORECAST BENCHMARK STARTED ==========")
	print("Warm-up duration: ", warmup_duration, " s")
	print("Test duration: ", test_duration, " s")
	print("Forecast horizon: ", prediction_horizon, " s")
	print("================================================")


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		finish_benchmark()
		return

	elapsed += delta
	sample_timer += delta

	# Evaluate forecasts that have reached their due time.
	evaluate_predictions()

	# Sampling occurs throughout the experiment.
	if sample_timer >= sample_interval:
		sample_timer -= sample_interval

		# Do not score anything during warm-up.
		if (
			elapsed >= warmup_duration
			and elapsed < test_duration
		):
			create_prediction()

	# Allow the final forecasts to mature.
	if elapsed >= test_duration + prediction_horizon + delta:
		finish_benchmark()


func create_prediction() -> void:
	if (turret.tracking_mode != CwisTurret.TrackingMode.ALPHA_BETA
		and turret.tracking_mode != CwisTurret.TrackingMode.ALPHA_BETA_GAMMA):
		return

	if not turret.has_observation:
		return

	if turret.time_since_observation > turret.contact_timeout:
		return

	# Both methods start from the same estimated position.
	var current_estimate: Vector3 = turret.get_estimated_position()

	# Method A: Constant-velocity extrapolation.
	var h: float = prediction_horizon
	var predicted_position: Vector3

	match turret.tracking_mode:
		CwisTurret.TrackingMode.ALPHA_BETA:
			predicted_position = (
				current_estimate
				+ turret.filtered_velocity * h
			)

		CwisTurret.TrackingMode.ALPHA_BETA_GAMMA:
			var velocity_now = (
			turret.filtered_velocity
			+ turret.filtered_acceleration
			* turret.time_since_observation
			)

			predicted_position = (
			current_estimate
			+ velocity_now * h
			+ 0.5 * turret.filtered_acceleration * h * h
			)

	# Method B: No future movement assumed.
	var baseline_position: Vector3 = current_estimate

	pending_predictions.append({
		"issued_at": elapsed,
		"due_at": elapsed + prediction_horizon,
		"origin": target.global_position,
		"predicted": predicted_position,
		"baseline": baseline_position
	})


func evaluate_predictions() -> void:
	for i in range(pending_predictions.size() - 1, -1, -1):
		var prediction: Dictionary = pending_predictions[i]

		if elapsed < prediction["due_at"]:
			continue

		var origin: Vector3 = prediction["origin"]
		var predicted: Vector3 = prediction["predicted"]
		var baseline: Vector3 = prediction["baseline"]
		var actual: Vector3 = target.global_position

		# Compare both predictions against the same actual position.
		var prediction_error_vector: Vector3 = actual - predicted
		var baseline_error_vector: Vector3 = actual - baseline

		var prediction_error: float = prediction_error_vector.length()
		var baseline_error: float = baseline_error_vector.length()

		# Calculate the actual displacement over this interval.
		var displacement: Vector3 = actual - origin

		var prediction_directional_error: float = 0.0
		var baseline_directional_error: float = 0.0

		if displacement.length() > 0.001:
			var motion_direction: Vector3 = displacement.normalized()

			prediction_directional_error = (
				prediction_error_vector.dot(motion_direction)
			)

			baseline_directional_error = (
				baseline_error_vector.dot(motion_direction)
			)

		# Accumulate prediction statistics.
		completed_predictions += 1

		total_error += prediction_error
		total_squared_error += prediction_error * prediction_error
		maximum_error = maxf(maximum_error, prediction_error)
		total_along_motion_error += prediction_directional_error

		# Accumulate baseline statistics.
		baseline_total_error += baseline_error
		baseline_total_squared_error += baseline_error * baseline_error
		baseline_maximum_error = maxf(
			baseline_maximum_error, baseline_error
		)
		baseline_total_directional_error += baseline_directional_error

		# Record this paired comparison.
		csv_file.store_line(
			"%.3f,%.3f,%.6f,%.6f,%.6f,%.6f" % [
				prediction["issued_at"],
				prediction["due_at"],
				prediction_error,
				baseline_error,
				prediction_directional_error,
				baseline_directional_error
			]
		)

		pending_predictions.remove_at(i)


func finish_benchmark() -> void:
	set_physics_process(false)

	if csv_file != null:
		csv_file.flush()
		csv_file.close()
		csv_file = null

	if completed_predictions == 0:
		print("FORECAST BENCHMARK: No predictions evaluated.")
		return

	var count: float = float(completed_predictions)
	var filter_name: String = CwisTurret.TrackingMode.keys()[turret.tracking_mode]


	# Alpha-Beta forecast statistics.
	var mean_error: float = total_error / count
	var rmse: float = sqrt(total_squared_error / count)
	var mean_directional_error: float = total_along_motion_error / count

	# Stationary baseline statistics.
	var baseline_mean: float = baseline_total_error / count
	var baseline_rmse: float = sqrt(
		baseline_total_squared_error / count
	)
	var baseline_directional_mean: float = (
		baseline_total_directional_error / count
	)

	# Positive improvement means the velocity forecast was better.
	var improvement: float = 0.0

	if baseline_mean > 0.00001:
		improvement = (
			(baseline_mean - mean_error) / baseline_mean
		) * 100.0

	print("")
	print("========== EXPERIMENT SETTINGS ==========")
	print("Tracking mode: ", filter_name)
	print("Alpha: ", turret.alpha)
	print("Beta: ", turret.beta)
	print("Gamma: ", turret.gamma)
	print("Forecast horizon: ", prediction_horizon, " s")
	print("Sample interval: ", sample_interval, " s")
	print("Warm-up: ", warmup_duration, " s")
	print("Test duration: ", test_duration, " s")

	if turret.radar_sensor != null:
		print(
			"Radar measurement error: ",
			turret.radar_sensor.get("measurement_error")
		)
		print(
			"Radar scan interval: ",
			turret.radar_sensor.get("scan_interval")
		)

	print("Target profile ID: ", target.get("flight_profile"))
	print("Target speed: ", target.get("speed"))
	print("Orbit radius: ", target.get("orbit_radius"))
	print("=========================================")

	print("")
	print("========== FORECAST RESULTS ==========")
	print("Predictions: ", completed_predictions)

	print("")
	print("---", filter_name, " PREDICTION ---")
	print("Mean error: ", snappedf(mean_error, 0.001))
	print("RMSE: ", snappedf(rmse, 0.001))
	print("Maximum error: ", snappedf(maximum_error, 0.001))
	print(
		"Mean directional error: ",
		snappedf(mean_directional_error, 0.001)
	)

	print("")
	print("--- STATIONARY BASELINE ---")
	print("Mean error: ", snappedf(baseline_mean, 0.001))
	print("RMSE: ", snappedf(baseline_rmse, 0.001))
	print(
		"Maximum error: ",
		snappedf(baseline_maximum_error, 0.001)
	)
	print(
		"Mean directional error: ",
		snappedf(baseline_directional_mean, 0.001)
	)

	print("")
	print("--- COMPARISON ---")
	print(
		"Mean error improvement: ",
		snappedf(improvement, 0.01), "%"
	)

	if improvement > 0.0:
		print("Winner: ", filter_name, " PREDICTION")
	elif improvement < 0.0:
		print("Winner: STATIONARY BASELINE")
	else:
		print("Winner: TIE")

	print("")
	print("CSV: ", ProjectSettings.globalize_path(csv_path))
	print("======================================")
