extends Node
class_name FilterBatchBenchmark

@export_group("References")
@export var turret: CwisTurret
@export var target: Node3D

@export_group("Batch Settings")
@export var enabled: bool = true
@export_range(1, 100, 1) var seed_count: int = 20
@export var first_seed: int = 20261111

@export var gamma_values: Array[float] = [
	0.0, 0.005, 0.01, 0.017, 0.02, 0.025, 0.05
]

@export_group("Experiment")
@export var forecast_horizon: float = 0.5
@export var warmup_duration: float = 3.0
@export var test_duration: float = 60.0

var csv_path: String = ""


func _ready() -> void:
	if not enabled:
		return
	call_deferred("run_batch")


# Reproduce the orbit formula from Target.gd.
# This calculates ground truth without moving the real target.
func orbit_position(t: float) -> Vector3:
	var radius: float = target.get("orbit_radius")
	var speed: float = target.get("speed")
	var clockwise: bool = target.get("orbit_clockwise")
	var start: Vector3 = target.get("starting_position")

	var direction: float = -1.0 if clockwise else 1.0
	var angle: float = t * speed / radius * direction

	var local_position: Vector3 = start + Vector3(
		(cos(angle) - 1.0) * radius,
		0.0,
		sin(angle) * radius
	)

	var parent := target.get_parent()

	if parent is Node3D:
		return parent.to_global(local_position)

	return local_position


# Create exactly one radar measurement sequence for a seed.
func generate_measurements(
	seed_value: int,
	interval: float,
	noise: float
) -> Array[Vector3]:

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var measurements: Array[Vector3] = []
	var steps: int = int(round(test_duration / interval))

	for i in range(steps):
		var t: float = float(i + 1) * interval
		var actual: Vector3 = orbit_position(t)

		var measured: Vector3 = actual + Vector3(
			rng.randfn(0.0, noise),
			rng.randfn(0.0, noise),
			rng.randfn(0.0, noise)
		)

		measurements.append(measured)

	return measurements


# Run either Alpha-Beta or Alpha-Beta-Gamma
# against a previously generated observation sequence.
func evaluate_filter(
	measurements: Array[Vector3],
	interval: float,
	use_gamma: bool,
	gamma_value: float
) -> Dictionary:

	var alpha: float = turret.alpha
	var beta: float = turret.beta

	var position_estimate: Vector3 = Vector3.ZERO
	var velocity_estimate: Vector3 = Vector3.ZERO
	var acceleration_estimate: Vector3 = Vector3.ZERO

	var initialized: bool = false

	var count: int = 0
	var total_error: float = 0.0
	var total_squared_error: float = 0.0
	var maximum_error: float = 0.0
	var total_directional_error: float = 0.0

	var baseline_total_error: float = 0.0

	for i in range(measurements.size()):
		var t: float = float(i + 1) * interval
		var measured: Vector3 = measurements[i]

		# First measurement establishes initial position.
		if not initialized:
			position_estimate = measured
			initialized = true
		else:
			var predicted_position: Vector3 = (
				position_estimate
				+ velocity_estimate * interval
			)

			var predicted_velocity: Vector3 = velocity_estimate

			if use_gamma:
				predicted_position += (
					0.5 * acceleration_estimate * interval ** 2
				)

				predicted_velocity += (
					acceleration_estimate * interval
				)

			var residual: Vector3 = measured - predicted_position

			position_estimate = (
				predicted_position + alpha * residual
			)

			velocity_estimate = (
				predicted_velocity
				+ (beta / interval) * residual
			)

			if use_gamma:
				acceleration_estimate += (
					(2.0 * gamma_value / interval ** 2)
					* residual
				)

		# Warm-up updates the filter but scores nothing.
		if t < warmup_duration or t >= test_duration:
			continue

		# Predict the future from the current filter state.
		var forecast: Vector3 = (
			position_estimate
			+ velocity_estimate * forecast_horizon
		)

		if use_gamma:
			forecast += (
				0.5 * acceleration_estimate
				* forecast_horizon ** 2
			)

		# Baseline: assume the estimated position stays fixed.
		var baseline: Vector3 = position_estimate

		var actual_now: Vector3 = orbit_position(t)
		var actual_future: Vector3 = orbit_position(
			t + forecast_horizon
		)

		var error_vector: Vector3 = actual_future - forecast
		var error: float = error_vector.length()

		var baseline_error: float = (
			actual_future - baseline
		).length()

		var displacement: Vector3 = actual_future - actual_now
		var directional_error: float = 0.0

		if displacement.length() > 0.001:
			directional_error = error_vector.dot(
				displacement.normalized()
			)

		count += 1
		total_error += error
		total_squared_error += error ** 2
		maximum_error = maxf(maximum_error, error)
		total_directional_error += directional_error
		baseline_total_error += baseline_error

	if count == 0:
		return {}

	var mean_error: float = total_error / count
	var baseline_mean: float = baseline_total_error / count

	var improvement: float = 0.0

	if baseline_mean > 0.00001:
		improvement = (
			(baseline_mean - mean_error) / baseline_mean
		) * 100.0

	return {
		"mean": mean_error,
		"rmse": sqrt(total_squared_error / count),
		"max": maximum_error,
		"bias": total_directional_error / count,
		"baseline": baseline_mean,
		"improvement": improvement,
		"count": count
	}


func run_batch() -> void:
	if not enabled:
		return
	if turret == null or target == null:
		push_error("Batch benchmark: Assign turret and target!")
		return

	if turret.radar_sensor == null:
		push_error("Batch benchmark: Radar reference missing!")
		return

	if int(target.get("flight_profile")) != 4:
		push_error("Batch benchmark requires ORBIT flight profile.")
		return

	if float(target.get("orbit_radius")) <= 0.0:
		push_error("Orbit radius must be positive!")
		return

	var interval: float = turret.radar_sensor.get(
        "scan_interval"
	)
	var noise: float = turret.radar_sensor.get(
        "measurement_error"
	)

	if interval <= 0.0 or forecast_horizon <= 0.0:
		push_error("Batch benchmark: Invalid timing settings!")
		return

	if test_duration <= warmup_duration + interval:
		push_error("Batch benchmark: Insufficient test duration!")
		return

	# Register all configurations.
	var configurations: Array[Dictionary] = [
		{"name": "ALPHA_BETA", "gamma": 0.0, "abg": false}
	]

	for g in gamma_values:
		configurations.append({
			"name": "ABG_" + str(g),
			"gamma": g,
			"abg": true
		})

	var aggregates: Array[Dictionary] = []

	for config in configurations:
		aggregates.append({
			"name": config["name"],
			"mean_sum": 0.0,
			"rmse_sum": 0.0,
			"max_sum": 0.0,
			"bias_sum": 0.0,
			"improvement_sum": 0.0,
			"wins": 0
		})

	csv_path = "user://filter_batch_%s.csv" % [
		str(Time.get_unix_time_from_system())
	]

	var file := FileAccess.open(csv_path, FileAccess.WRITE)

	if file == null:
		push_error("Batch benchmark: Could not create CSV!")
		return

	file.store_csv_line(PackedStringArray([
		"seed", "filter", "alpha", "beta", "gamma",
		"mean_error", "rmse", "max_error",
		"directional_bias", "baseline_mean",
        "improvement_percent"
	]))

	print("")
	print("========== FILTER BATCH START ==========")
	print("Seeds: ", seed_count)
	print("First seed: ", first_seed)
	print("Alpha: ", turret.alpha, " | Beta: ", turret.beta)
	print("Radar noise: ", noise)
	print("Radar interval: ", interval)
	print("Forecast horizon: ", forecast_horizon)
	print("Warm-up: ", warmup_duration)
	print("Test duration: ", test_duration)
	print("Target speed: ", target.get("speed"))
	print("Orbit radius: ", target.get("orbit_radius"))
	print("========================================")

	for seed_index in range(seed_count):
		var seed_value: int = first_seed + seed_index

		# Generate ONCE, reuse for EVERY filter.
		var measurements := generate_measurements(
			seed_value, interval, noise
		)

		var baseline_ab_mean: float = 0.0

		for j in range(configurations.size()):
			var config: Dictionary = configurations[j]

			var result := evaluate_filter(
				measurements,
				interval,
				config["abg"],
				config["gamma"]
			)

			if result.is_empty():
				continue

			var aggregate: Dictionary = aggregates[j]

			aggregate["mean_sum"] += result["mean"]
			aggregate["rmse_sum"] += result["rmse"]
			aggregate["max_sum"] += result["max"]
			aggregate["bias_sum"] += result["bias"]
			aggregate["improvement_sum"] += result["improvement"]

			if j == 0:
				baseline_ab_mean = result["mean"]
			elif result["mean"] < baseline_ab_mean:
				aggregate["wins"] += 1

			file.store_csv_line(PackedStringArray([
				str(seed_value),
				str(config["name"]),
				str(turret.alpha),
				str(turret.beta),
				str(config["gamma"]),
				str(result["mean"]),
				str(result["rmse"]),
				str(result["max"]),
				str(result["bias"]),
				str(result["baseline"]),
				str(result["improvement"])
			]))

	file.flush()
	file.close()

	print("")
	print("========== BATCH RESULTS ==========")

	for aggregate in aggregates:
		var n: float = float(seed_count)

		print("")
		print("--- ", aggregate["name"], " ---")
		print("Average mean error: ",
			snappedf(aggregate["mean_sum"] / n, 0.001))
		print("Average RMSE: ",
			snappedf(aggregate["rmse_sum"] / n, 0.001))
		print("Average maximum error: ",
			snappedf(aggregate["max_sum"] / n, 0.001))
		print("Average directional bias: ",
			snappedf(aggregate["bias_sum"] / n, 0.001))
		print("Average improvement vs stationary: ",
			snappedf(aggregate["improvement_sum"] / n, 0.01), "%")

		if aggregate["name"] != "ALPHA_BETA":
			print("Seeds beating Alpha-Beta: ",
				aggregate["wins"], "/", seed_count)

	print("")
	print("CSV: ", ProjectSettings.globalize_path(csv_path))
	print("===================================")
