
extends Node
class_name AdaptiveSensorBenchmark

@export_group("Execution")
@export var enabled: bool = false

@export_group("References")
@export var target: Node3D
@export var turret: CwisTurret

@export_group("Experiments")
@export_range(1, 100, 1) var seed_count: int = 20
@export var first_seed: int = 20261111
@export var duration: float = 80.0
@export var forecast_horizon: float = 0.5
@export var warmup: float = 3.0

@export_group("Filter Comparison")
@export_range(0.0, 0.1, 0.001) var test_gamma: float = 0.025

@export_group("Sensor Health - Experimental Thresholds")
@export var degraded_threshold: float = 0.6
@export var recovered_threshold: float = 0.2
@export_range(1, 20, 1) var confirmation_scans: int = 5

@export_group("Diagnostics")
@export var log_switch_events: bool = false
@export var print_per_seed_switches: bool = true

var csv_path: String


# Independent filter state for each estimator.
class FilterState:
	var p: Vector3 = Vector3.ZERO
	var v: Vector3 = Vector3.ZERO
	var a: Vector3 = Vector3.ZERO

	var ready: bool = false
	var use_acceleration: bool
	var alpha: float
	var beta: float
	var gamma: float

	func _init(
		use_acc: bool,
		a_gain: float,
		b_gain: float,
		g_gain: float
	) -> void:
		use_acceleration = use_acc
		alpha = a_gain
		beta = b_gain
		gamma = g_gain

	# One observation step. Null means no measurement.
	# Returns the innovation before correction, if available.
	func step(z: Variant, dt: float) -> Variant:
		if not ready:
			if z == null:
				return null

			p = z
			ready = true
			return null

		var predicted_p: Vector3 = p + v * dt
		var predicted_v: Vector3 = v

		if use_acceleration:
			predicted_p += 0.5 * a * dt ** 2
			predicted_v += a * dt

		# Even with no measurement, the clock keeps advancing.
		p = predicted_p
		v = predicted_v

		if z == null:
			return null

		var residual: Vector3 = z - predicted_p

		p += alpha * residual
		v += (beta / dt) * residual

		if use_acceleration:
			a += (2.0 * gamma / dt ** 2) * residual

		return residual

	func forecast(h: float) -> Vector3:
		var result: Vector3 = p + v * h

		if use_acceleration:
			result += 0.5 * a * h ** 2

		return result


func _ready() -> void:
	if not enabled:
		return

	call_deferred("run_batch")


func orbit_position(t: float) -> Vector3:
	var radius: float = target.get("orbit_radius")
	var speed: float = target.get("speed")
	var clockwise: bool = target.get("orbit_clockwise")
	var start: Vector3 = target.get("starting_position")

	var sign_value: float = -1.0 if clockwise else 1.0
	var angle: float = t * speed / radius * sign_value

	var local_position: Vector3 = start + Vector3(
		(cos(angle) - 1.0) * radius,
		0.0,
		sin(angle) * radius
	)

	var parent := target.get_parent()

	if parent is Node3D:
		return parent.to_global(local_position)

	return local_position



func get_environment(t: float) -> Dictionary:
	if t < 20.0:
		return {
			"phase": 0,
			"name": "CLEAR",
			"noise": 0.0,
			"dropout": 0.0
		}

	elif t < 40.0:
		return {
			"phase": 1,
			"name": "DEGRADED",
			"noise": 0.1,
			"dropout": 0.05
		}

	elif t < 60.0:
		return {
			"phase": 2,
			"name": "UNRELIABLE",
			"noise": 0.5,
			"dropout": 0.2
		}

	else:
		return {
			"phase": 3,
			"name": "RECOVERY",
			"noise": 0.0,
			"dropout": 0.0
		}



func make_stats(name: String) -> Dictionary:
	return {
		"name": name,
		"count": 0,
		"ab_sum": 0.0,
		"abg_sum": 0.0,
		"adaptive_sum": 0.0,
		"adaptive_squared_sum": 0.0,
		"abg_selected": 0,
		"switches": 0
	}


# Scoring bins are defined relative to the start of recovery (60 s).
func recovery_window_index(t: float) -> int:
	if t < 60.0 or t >= 80.0:
		return -1
	if t < 62.0:
		return 0
	if t < 65.0:
		return 1
	if t < 70.0:
		return 2
	return 3


func make_window_stats(name: String) -> Dictionary:
	return {
		"name": name,
		"count": 0,
		"ab_sum": 0.0,
		"abg_sum": 0.0,
		"adaptive_sum": 0.0,
		"abg_selected": 0
	}


func run_batch() -> void:
	if not enabled:
		return

	if target == null or turret == null:
		push_error("Adaptive benchmark: Missing references!")
		return

	if turret.radar_sensor == null:
		push_error("Adaptive benchmark: No radar reference!")
		return

	if int(target.get("flight_profile")) != 4:
		push_error("Adaptive benchmark requires ORBIT.")
		return

	if float(target.get("orbit_radius")) <= 0.0:
		push_error("Adaptive benchmark: Invalid orbit radius.")
		return

	var dt: float = turret.radar_sensor.get("scan_interval")

	if dt <= 0.0 or forecast_horizon <= 0.0:
		push_error("Adaptive benchmark: Invalid timing.")
		return

	if duration != 80.0 or warmup >= duration:
		push_error("Adaptive benchmark: Invalid duration.")
		return

	var stats: Array[Dictionary] = [
		make_stats("CLEAR"),
		make_stats("DEGRADED"),
		make_stats("UNRELIABLE"),
		make_stats("RECOVERY")
	]
	var recovery_windows: Array[Dictionary] = [
		make_window_stats("0-2 s"),
		make_window_stats("2-5 s"),
		make_window_stats("5-10 s"),
		make_window_stats("10-20 s")
	]
	var per_seed_switch_counts: Array[int] = []
	var trials_with_repeat_recovery_switches: int = 0
	var return_then_left_abg: int = 0

	csv_path = "user://adaptive_%s.csv" % [
		str(Time.get_unix_time_from_system())
	]

	var file := FileAccess.open(csv_path, FileAccess.WRITE)

	if file == null:
		push_error("Adaptive benchmark: Cannot create CSV.")
		return

	file.store_csv_line(PackedStringArray([
		"seed", "time", "phase", "noise",
		"measurement_received", "innovation_ema",
		"dropout_ema", "selected_filter",
		"ab_error", "abg_error", "adaptive_error"
	]))

	# Separate event CSV: exactly one row per filter transition.
	var switch_csv_path: String = csv_path.replace("adaptive_", "adaptive_switches_")
	var switches_file := FileAccess.open(switch_csv_path, FileAccess.WRITE)
	if switches_file == null:
		file.close()
		push_error("Adaptive benchmark: Cannot create switch CSV.")
		return
	switches_file.store_csv_line(PackedStringArray([
		"seed", "time", "phase", "from_filter", "to_filter",
		"innovation_ema", "dropout_ema", "received"
	]))

	var recovery_successes: int = 0
	var total_recovery_time: float = 0.0

	for trial in range(seed_count):
		var seed_value: int = first_seed + trial
		var recovery_recorded: bool = false
		var trial_switches: int = 0
		var recovery_switches: int = 0
		var left_abg_after_return: bool = false

		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value

		# Both filters see the same observations.
		var ab := FilterState.new(
			false, turret.alpha, turret.beta, 0.0
		)
		var abg := FilterState.new(
			true, turret.alpha, turret.beta, test_gamma
		)

		# Health estimates. No access to ground truth.
		var innovation_ema: float = 0.0
		var dropout_ema: float = 0.0

		# Start with the acceleration-aware estimator.
		var selected: String = "ABG"
		var proposed: String = ""
		var proposal_count: int = 0

		var steps: int = int(round(duration / dt))

		for i in range(steps):
			var t: float = float(i + 1) * dt
			var environment: Dictionary = get_environment(t)

			var noise: float = environment["noise"]
			var dropout: float = environment["dropout"]

			var received: bool = rng.randf() >= dropout
			var measurement: Variant = null

			if received:
				measurement = orbit_position(t) + Vector3(
					rng.randfn(0.0, noise),
					rng.randfn(0.0, noise),
					rng.randfn(0.0, noise)
				)

			# Update both filters every scan.
			var innovation: Variant = ab.step(measurement, dt)
			abg.step(measurement, dt)

			# Estimate whether readings are becoming unreliable.
			# This is a consistency score, not true noise variance.
			if innovation != null:
				var residual: Vector3 = innovation
				innovation_ema = lerpf(
					innovation_ema,
					residual.length_squared(),
					0.12
				)

			dropout_ema = lerpf(
				dropout_ema,
				0.0 if received else 1.0,
				0.12
			)

			# Candidate selection using hysteresis thresholds.
			var candidate: String = selected

			if (
				innovation_ema > degraded_threshold
				or dropout_ema > 0.08
			):
				candidate = "AB"

			elif (
				innovation_ema < recovered_threshold
				and dropout_ema < 0.04
			):
				candidate = "ABG"

			# Require repeated agreement before switching.
			if candidate != selected:
				if candidate == proposed:
					proposal_count += 1
				else:
					proposed = candidate
					proposal_count = 1

				if proposal_count >= confirmation_scans:
					var previous_selection: String = selected
					selected = candidate
					proposed = ""
					proposal_count = 0

					var phase_index: int = environment["phase"]
					stats[phase_index]["switches"] += 1
					trial_switches += 1
					if t >= 60.0:
						recovery_switches += 1
						if recovery_recorded and selected != "ABG":
							left_abg_after_return = true

					switches_file.store_csv_line(PackedStringArray([
						str(seed_value), str(t), str(environment["name"]),
						previous_selection, selected, str(innovation_ema),
						str(dropout_ema), str(received)
					]))
					if log_switch_events:
						print("SWITCH seed=", seed_value, " t=", snappedf(t, 0.001),
							" phase=", environment["name"], " ", previous_selection,
							" -> ", selected, " innovation=",
							snappedf(innovation_ema, 0.001), " dropout=",
							snappedf(dropout_ema, 0.001))
			else:
				proposed = ""
				proposal_count = 0
			
			# Measure when the adaptive selector first returns to ABG
			# after the recovery phase begins.
			if (
				t >= 60.0
				and not recovery_recorded
				and selected == "ABG"
			):
				recovery_recorded = true
				recovery_successes += 1

				var recovery_time: float = maxf(
					0.0,
					t - 60.0
				)

				total_recovery_time += recovery_time


			if t < warmup or t + forecast_horizon > duration:
				continue

			if not ab.ready or not abg.ready:
				continue

			# The hidden ground truth is used ONLY for scoring.
			var actual_future: Vector3 = orbit_position(
				t + forecast_horizon
			)

			var ab_error: float = actual_future.distance_to(
				ab.forecast(forecast_horizon)
			)

			var abg_error: float = actual_future.distance_to(
				abg.forecast(forecast_horizon)
			)

			var adaptive_error: float = (
				ab_error if selected == "AB" else abg_error
			)

			var phase: int = environment["phase"]
			var s: Dictionary = stats[phase]

			s["count"] += 1
			s["ab_sum"] += ab_error
			s["abg_sum"] += abg_error
			s["adaptive_sum"] += adaptive_error
			s["adaptive_squared_sum"] += adaptive_error ** 2

			if selected == "ABG":
				s["abg_selected"] += 1

			var window_index: int = recovery_window_index(t)
			if window_index >= 0:
				var w: Dictionary = recovery_windows[window_index]
				w["count"] += 1
				w["ab_sum"] += ab_error
				w["abg_sum"] += abg_error
				w["adaptive_sum"] += adaptive_error
				if selected == "ABG":
					w["abg_selected"] += 1

			file.store_csv_line(PackedStringArray([
				str(seed_value),
				str(t),
				str(environment["name"]),
				str(noise),
				str(received),
				str(innovation_ema),
				str(dropout_ema),
				selected,
				str(ab_error),
				str(abg_error),
				str(adaptive_error)
			]))

		# Per-seed diagnostics, once that seed's full run has finished.
		per_seed_switch_counts.append(trial_switches)
		if recovery_switches > 1:
			trials_with_repeat_recovery_switches += 1
		if left_abg_after_return:
			return_then_left_abg += 1
		if print_per_seed_switches:
			print("SEED ", seed_value, ": total switches=", trial_switches,
				" | recovery switches=", recovery_switches,
				" | returned to ABG=", recovery_recorded,
				" | left ABG after return=", left_abg_after_return)

	file.flush()
	file.close()
	switches_file.flush()
	switches_file.close()

	print("")
	print("========== ADAPTIVE BENCHMARK ==========")
	print("Seeds: ", seed_count)
	print("Alpha: ", turret.alpha)
	print("Beta: ", turret.beta)
	print("Gamma: ", test_gamma)
	print("Scan interval: ", dt)
	print("Forecast horizon: ", forecast_horizon)
	print("Confirmation scans: ", confirmation_scans)
	print("Degraded threshold: ", degraded_threshold)
	print("Recovered threshold: ", recovered_threshold)

	for s in stats:
		var count: int = s["count"]

		if count == 0:
			continue

		var n: float = float(count)

		print("")
		print("--- ", s["name"], " ---")
		print("Samples: ", count)
		print("AB mean error: ",
			snappedf(s["ab_sum"] / n, 0.001))
		print("ABG mean error: ",
			snappedf(s["abg_sum"] / n, 0.001))
		print("Adaptive mean error: ",
			snappedf(s["adaptive_sum"] / n, 0.001))
		print("Adaptive RMSE: ",
			snappedf(sqrt(s["adaptive_squared_sum"] / n), 0.001))
		print("ABG selected: ",
			snappedf(100.0 * s["abg_selected"] / n, 0.1),
			"% of scored samples")
		print("Filter switches: ", s["switches"])

	print("")
	
	print("")
	print("========== RECOVERY ANALYSIS ==========")
	print(
		"Trials returning to ABG: ",
		recovery_successes, "/", seed_count
	)

	if recovery_successes > 0:
		var average_recovery: float = (
			total_recovery_time / float(recovery_successes)
		)

		print(
			"Mean time until ABG selected: ",
			snappedf(average_recovery, 0.001), " s"
		)
	else:
		print("No successful returns to ABG.")

	print("=======================================")

	print("")
	print("========== SWITCH STABILITY ==========")
	var total_switches: int = 0
	var max_switches: int = 0
	for value in per_seed_switch_counts:
		total_switches += value
		max_switches = maxi(max_switches, value)
	print("Mean switches per seed: ",
		snappedf(float(total_switches) / float(seed_count), 0.01))
	print("Maximum switches in one seed: ", max_switches)
	print("Seeds with multiple recovery switches: ",
		trials_with_repeat_recovery_switches, "/", seed_count)
	print("Seeds leaving ABG after first return: ",
		return_then_left_abg, "/", seed_count)

	print("")
	print("========== RECOVERY TIME WINDOWS ==========")
	for w in recovery_windows:
		if w["count"] == 0:
			continue
		var n: float = float(w["count"])
		print("--- ", w["name"], " ---")
		print("Samples: ", w["count"])
		print("AB mean error: ", snappedf(w["ab_sum"] / n, 0.001))
		print("ABG mean error: ", snappedf(w["abg_sum"] / n, 0.001))
		print("Adaptive mean error: ",
			snappedf(w["adaptive_sum"] / n, 0.001))
		print("ABG selected: ",
			snappedf(100.0 * float(w["abg_selected"]) / n, 0.1), "%")
	print("=======================================")

	print("CSV: ", ProjectSettings.globalize_path(csv_path))
	print("Switch events CSV: ", ProjectSettings.globalize_path(switch_csv_path))
	print("=======================================")
