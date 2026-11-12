extends Node3D

@export_group("Execution")
@export var enabled: bool = false

@export_group("Components")
@export var target: Node3D
@export var radar_sensor: Area3D

@export_group("Experiment")
@export var test_duration: float = 60.0
@export var sample_interval: float = 0.1

@export_group("Filter Gains")
@export_range(0.01, 1.0) var alpha: float = 0.6
@export_range(0.0, 1.0) var beta: float = 0.15

# The three estimators
var raw_position: Vector3 = Vector3.ZERO
var alpha_position: Vector3 = Vector3.ZERO
var ab_position: Vector3 = Vector3.ZERO
var ab_velocity: Vector3 = Vector3.ZERO

var has_observation: bool = false
var last_observation_time: float = 0.0

# Benchmark timing
var elapsed_time: float = 0.0
var sample_timer: float = 0.0
var progress_timer: float = 0.0
var finished: bool = false

var csv_file: FileAccess
var csv_path: String

var modes = ["RAW_RADAR", "ALPHA", "ALPHA_BETA"]

var statistics: Dictionary = {}


func _ready() -> void:
	if not enabled:
		set_physics_process(false)
		set_process(false)
		return
	if target == null or radar_sensor == null:
		push_error("Benchmark: Missing target or radar!")
		set_physics_process(false)
		return

	if not radar_sensor.has_signal("observation_received"):
		push_error("Benchmark: Radar signal not found!")
		set_physics_process(false)
		return

	if test_duration <= 0.0 or sample_interval <= 0.0:
		push_error("Benchmark: Invalid timing settings!")
		set_physics_process(false)
		return

	for mode in modes:
		statistics[mode] = {
			"count": 0,
			"sum": 0.0,
			"squared_sum": 0.0,
			"maximum": 0.0
		}

	radar_sensor.connect(
		"observation_received",
		_on_observation_received
	)

	csv_path = "user://comparison_%s.csv" % [
		str(Time.get_unix_time_from_system())
	]

	csv_file = FileAccess.open(csv_path, FileAccess.WRITE)

	if csv_file == null:
		push_error("Benchmark: CSV creation failed!")
		set_physics_process(false)
		return

	csv_file.store_line("time,profile,mode,error")

	print("BENCHMARK STARTED")
	print("CSV: ", ProjectSettings.globalize_path(csv_path))


func _on_observation_received(
	measured_position: Vector3,
	_identification: String
) -> void:

	raw_position = measured_position

	# First observation initializes all three estimators.
	if not has_observation:
		alpha_position = measured_position
		ab_position = measured_position
		ab_velocity = Vector3.ZERO

		last_observation_time = elapsed_time
		has_observation = true
		return

	var dt = maxf(
		elapsed_time - last_observation_time,
		0.0001
	)

	# ALPHA: Smooth position measurements
	alpha_position = (
		alpha * measured_position
		+ (1.0 - alpha) * alpha_position
	)

	# ALPHA-BETA: Predict
	var predicted_position = ab_position + ab_velocity * dt

	# Calculate residual
	var residual = measured_position - predicted_position

	# Correct position and velocity
	ab_position = predicted_position + alpha * residual
	ab_velocity += (beta / dt) * residual

	last_observation_time = elapsed_time


func _physics_process(delta: float) -> void:
	if finished:
		return

	elapsed_time += delta
	sample_timer += delta
	progress_timer += delta

	if progress_timer >= 5.0:
		progress_timer -= 5.0
		print("Benchmark progress: ", snappedf(elapsed_time, 0.1))

	if sample_timer >= sample_interval:
		sample_timer -= sample_interval

		if has_observation:
			record_samples()

	if elapsed_time >= test_duration:
		finish_benchmark()


func record_samples() -> void:
	var actual = target.global_position
	var profile_name = target.FlightProfile.keys()[target.flight_profile]

	# Predict between observations using velocity
	var time_since_scan = elapsed_time - last_observation_time

	var ab_estimate = (
		ab_position + ab_velocity * time_since_scan
	)

	var estimates = {
		"RAW_RADAR": raw_position,
		"ALPHA": alpha_position,
		"ALPHA_BETA": ab_estimate
	}

	for mode in modes:
		var estimate: Vector3 = estimates[mode]
		var error = actual.distance_to(estimate)

		var data: Dictionary = statistics[mode]

		data["count"] += 1
		data["sum"] += error
		data["squared_sum"] += error * error
		data["maximum"] = maxf(data["maximum"], error)

		csv_file.store_line("%.3f,%s,%s,%.6f" % [
			elapsed_time,
			profile_name,
			mode,
			error
		])


func finish_benchmark() -> void:
	if finished:
		return

	finished = true

	if csv_file != null:
		csv_file.flush()
		csv_file.close()
		csv_file = null

	print("")
	print("========== COMPARISON RESULTS ==========")

	for mode in modes:
		var data: Dictionary = statistics[mode]
		var count: int = data["count"]

		if count == 0:
			print(mode, ": No observations")
			continue

		var mean: float = data["sum"] / count
		var rmse: float = sqrt(data["squared_sum"] / count)

		print("")
		print("MODE: ", mode)
		print("Samples: ", count)
		print("Mean error: ", snappedf(mean, 0.001))
		print("RMSE: ", snappedf(rmse, 0.001))
		print("Maximum error: ", snappedf(data["maximum"], 0.001))

	print("")
	print("CSV: ", ProjectSettings.globalize_path(csv_path))
	print("========================================")

	set_physics_process(false)


func _exit_tree() -> void:
	if not finished and csv_file != null:
		print("Benchmark interrupted; saving partial results.")
		finish_benchmark()
