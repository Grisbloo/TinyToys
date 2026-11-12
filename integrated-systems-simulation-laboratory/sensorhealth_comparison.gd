extends Node
class_name SensorHealthComparison

# Standalone laboratory experiment. Does not control a turret.
@export_group("Execution")
@export var enabled: bool = false
@export_group("References")
@export var target: Node3D
@export var turret: CwisTurret
@export_group("Experiment")
@export_range(1, 100, 1) var seed_count: int = 20
@export var first_seed: int = 20261111
@export var duration: float = 80.0
@export var warmup: float = 3.0
@export var forecast_horizon: float = 0.5
@export var test_gamma: float = 0.025
@export_group("Original Monitor")
@export var old_degrade: float = 0.6
@export var old_recover: float = 0.2
@export var old_confirm: int = 5
@export_group("Candidate Monitor - Untuned Hypothesis")
@export var new_degrade: float = 0.85
@export var new_recover: float = 0.25
@export var new_dropout_degrade: float = 0.16
@export var new_dropout_recover: float = 0.05
@export var new_confirm_degrade: int = 5
@export var new_confirm_recover: int = 3

class FilterState:
	var p: Vector3 = Vector3.ZERO
	var v: Vector3 = Vector3.ZERO
	var a: Vector3 = Vector3.ZERO
	var ready: bool = false
	var use_acc: bool
	var alpha: float
	var beta: float
	var gamma: float

	func _init(acc: bool, alpha_value: float, beta_value: float, gamma_value: float) -> void:
		use_acc = acc
		alpha = alpha_value
		beta = beta_value
		gamma = gamma_value

	func step(z: Variant, dt: float) -> Variant:
		if not ready:
			if z == null:
				return null
			p = z
			ready = true
			return null
		var predicted_p: Vector3 = p + v * dt
		var predicted_v: Vector3 = v
		if use_acc:
			predicted_p += 0.5 * a * dt * dt
			predicted_v += a * dt
		p = predicted_p
		v = predicted_v
		if z == null:
			return null
		var residual: Vector3 = z - predicted_p
		p += alpha * residual
		v += (beta / dt) * residual
		if use_acc:
			a += (2.0 * gamma / (dt * dt)) * residual
		return residual

	func forecast(h: float) -> Vector3:
		var out: Vector3 = p + v * h
		if use_acc:
			out += 0.5 * a * h * h
		return out

class Monitor:
	var selected: String = "ABG"
	var proposed: String = ""
	var consecutive: int = 0
	var innovation_ema: float = 0.0
	var dropout_ema: float = 0.0
	var switches: int = 0
	var recovery_switches: int = 0
	var first_recovery_time: float = -1.0
	var left_after_recovery: bool = false

	func update(innovation: Variant, received: bool, t: float, revised: bool,
				old_hi: float, old_lo: float, old_n: int,
				new_hi: float, new_lo: float, new_drop_hi: float,
				new_drop_lo: float, new_n_hi: int, new_n_lo: int) -> bool:
		# Both algorithms use the same innovations; ground truth is never read here.
		if innovation != null:
			var residual: Vector3 = innovation
			innovation_ema = lerpf(innovation_ema, residual.length_squared(), 0.12)
		dropout_ema = lerpf(dropout_ema, 0.0 if received else 1.0, 0.12)

		var candidate: String = selected
		var confirmations: int = old_n
		if revised:
			# Separate dropout and innovation thresholds; faster recovery confirmation.
			if innovation_ema > new_hi or dropout_ema > new_drop_hi:
				candidate = "AB"
				confirmations = new_n_hi
			elif innovation_ema < new_lo and dropout_ema < new_drop_lo:
				candidate = "ABG"
				confirmations = new_n_lo
		else:
			if innovation_ema > old_hi or dropout_ema > 0.08:
				candidate = "AB"
			elif innovation_ema < old_lo and dropout_ema < 0.04:
				candidate = "ABG"

		var changed: bool = false
		if candidate != selected:
			if candidate == proposed:
				consecutive += 1
			else:
				proposed = candidate
				consecutive = 1
			if consecutive >= maxi(1, confirmations):
				selected = candidate
				proposed = ""
				consecutive = 0
				switches += 1
				changed = true
				if t >= 60.0:
					recovery_switches += 1
					if first_recovery_time >= 0.0 and selected != "ABG":
						left_after_recovery = true
		else:
			proposed = ""
			consecutive = 0
		if t >= 60.0 and first_recovery_time < 0.0 and selected == "ABG":
			first_recovery_time = t - 60.0
		return changed

func _ready() -> void:
	if enabled:
		call_deferred("run_experiment")

func orbit_position(t: float) -> Vector3:
	var radius: float = target.get("orbit_radius")
	var speed: float = target.get("speed")
	var clockwise: bool = target.get("orbit_clockwise")
	var start: Vector3 = target.get("starting_position")
	var sign_value: float = -1.0 if clockwise else 1.0
	var angle: float = t * speed / radius * sign_value
	var local_p: Vector3 = start + Vector3((cos(angle) - 1.0) * radius, 0.0, sin(angle) * radius)
	var parent: Node = target.get_parent()
	if parent is Node3D:
		return (parent as Node3D).to_global(local_p)
	return local_p

func environment(t: float) -> Dictionary:
	if t < 20.0:
		return {"phase": 0, "name": "CLEAR", "noise": 0.0, "drop": 0.0}
	if t < 40.0:
		return {"phase": 1, "name": "DEGRADED", "noise": 0.1, "drop": 0.05}
	if t < 60.0:
		return {"phase": 2, "name": "UNRELIABLE", "noise": 0.5, "drop": 0.2}
	return {"phase": 3, "name": "RECOVERY", "noise": 0.0, "drop": 0.0}

func make_stats() -> Dictionary:
	return {"n": 0, "ab": 0.0, "abg": 0.0, "old": 0.0, "new": 0.0,
			"old_abg": 0, "new_abg": 0, "old_switches": 0, "new_switches": 0,
			"new_wins": 0}

func window_index(t: float) -> int:
	if t < 60.0 or t >= 80.0:
		return -1
	if t < 62.0:
		return 0
	if t < 65.0:
		return 1
	if t < 70.0:
		return 2
	return 3

func run_experiment() -> void:
	if not enabled:
		return
	if target == null or turret == null or turret.radar_sensor == null:
		push_error("SensorHealthComparison: Set target and turret (with radar sensor).")
		return
	if int(target.get("flight_profile")) != 4 or float(target.get("orbit_radius")) <= 0.0:
		push_error("SensorHealthComparison: Target must have ORBIT profile and positive radius.")
		return
	var dt: float = turret.radar_sensor.get("scan_interval")
	if dt <= 0.0 or forecast_horizon <= 0.0 or warmup >= 80.0:
		push_error("SensorHealthComparison: Invalid time settings.")
		return
	if not is_equal_approx(duration, 80.0):
		push_error("SensorHealthComparison: This four-phase experiment requires duration = 80.0.")
		return

	var stats: Array[Dictionary] = [make_stats(), make_stats(), make_stats(), make_stats()]
	var windows: Array[Dictionary] = [make_stats(), make_stats(), make_stats(), make_stats()]
	var old_success: int = 0
	var new_success: int = 0
	var old_time_sum: float = 0.0
	var new_time_sum: float = 0.0
	var old_reversals: int = 0
	var new_reversals: int = 0
	var old_total_switches: int = 0
	var new_total_switches: int = 0

	var path: String = "user://sensor_health_compare_%d.csv" % int(Time.get_unix_time_from_system())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SensorHealthComparison: Could not create CSV.")
		return
	f.store_csv_line(PackedStringArray([
		"seed", "time", "phase", "received", "innovation_ema", "dropout_ema",
		"old_selected", "new_selected", "old_switched", "new_switched",
		"ab_error", "abg_error", "old_error", "new_error"
	]))

	for trial in range(seed_count):
		var seed_value: int = first_seed + trial
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var ab := FilterState.new(false, turret.alpha, turret.beta, 0.0)
		var abg := FilterState.new(true, turret.alpha, turret.beta, test_gamma)
		var old_monitor := Monitor.new()
		var new_monitor := Monitor.new()
		var prev_old_switches: int = 0
		var prev_new_switches: int = 0
		var steps: int = int(round(duration / dt))
		for i in range(steps):
			var t: float = float(i + 1) * dt
			var env: Dictionary = environment(t)
			var noise: float = env["noise"]
			var received: bool = rng.randf() >= float(env["drop"])
			var z: Variant = null
			if received:
				z = orbit_position(t) + Vector3(
					rng.randfn(0.0, noise), rng.randfn(0.0, noise), rng.randfn(0.0, noise)
				)
			var innovation: Variant = ab.step(z, dt)
			abg.step(z, dt)
			var old_changed: bool = old_monitor.update(
				innovation, received, t, false, old_degrade, old_recover, old_confirm,
				new_degrade, new_recover, new_dropout_degrade, new_dropout_recover,
				new_confirm_degrade, new_confirm_recover
			)
			var new_changed: bool = new_monitor.update(
				innovation, received, t, true, old_degrade, old_recover, old_confirm,
				new_degrade, new_recover, new_dropout_degrade, new_dropout_recover,
				new_confirm_degrade, new_confirm_recover
			)
			var phase: int = int(env["phase"])
			stats[phase]["old_switches"] += old_monitor.switches - prev_old_switches
			stats[phase]["new_switches"] += new_monitor.switches - prev_new_switches
			prev_old_switches = old_monitor.switches
			prev_new_switches = new_monitor.switches

			if t < warmup or t + forecast_horizon > duration or not ab.ready or not abg.ready:
				continue
			# Ground truth is used only to score the forecasts, never by either monitor.
			var future: Vector3 = orbit_position(t + forecast_horizon)
			var ab_err: float = future.distance_to(ab.forecast(forecast_horizon))
			var abg_err: float = future.distance_to(abg.forecast(forecast_horizon))
			var old_err: float = ab_err if old_monitor.selected == "AB" else abg_err
			var new_err: float = ab_err if new_monitor.selected == "AB" else abg_err
			var s: Dictionary = stats[phase]
			s["n"] += 1
			s["ab"] += ab_err
			s["abg"] += abg_err
			s["old"] += old_err
			s["new"] += new_err
			if old_monitor.selected == "ABG":
				s["old_abg"] += 1
			if new_monitor.selected == "ABG":
				s["new_abg"] += 1
			if new_err < old_err:
				s["new_wins"] += 1
			var w_idx: int = window_index(t)
			if w_idx >= 0:
				var w: Dictionary = windows[w_idx]
				w["n"] += 1
				w["old"] += old_err
				w["new"] += new_err
				if old_monitor.selected == "ABG":
					w["old_abg"] += 1
				if new_monitor.selected == "ABG":
					w["new_abg"] += 1
			f.store_csv_line(PackedStringArray([
				str(seed_value), str(t), str(env["name"]), str(received),
				str(old_monitor.innovation_ema), str(old_monitor.dropout_ema),
				old_monitor.selected, new_monitor.selected, str(old_changed), str(new_changed),
				str(ab_err), str(abg_err), str(old_err), str(new_err)
			]))
		old_total_switches += old_monitor.switches
		new_total_switches += new_monitor.switches
		if old_monitor.first_recovery_time >= 0.0:
			old_success += 1
			old_time_sum += old_monitor.first_recovery_time
		if new_monitor.first_recovery_time >= 0.0:
			new_success += 1
			new_time_sum += new_monitor.first_recovery_time
		if old_monitor.left_after_recovery:
			old_reversals += 1
		if new_monitor.left_after_recovery:
			new_reversals += 1

	f.flush()
	f.close()
	print("\n========== SENSOR HEALTH COMPARISON ==========")
	print("Seeds: ", seed_count, " | Gamma: ", test_gamma, " | dt: ", dt)
	var names: Array[String] = ["CLEAR", "DEGRADED", "UNRELIABLE", "RECOVERY"]
	for phase in range(4):
		var s: Dictionary = stats[phase]
		if int(s["n"]) == 0:
			continue
		var n: float = float(s["n"])
		print("\n--- ", names[phase], " ---")
		print("Samples: ", int(s["n"]))
		print("AB mean: ", snappedf(float(s["ab"]) / n, 0.001),
			" | ABG mean: ", snappedf(float(s["abg"]) / n, 0.001))
		print("Original mean: ", snappedf(float(s["old"]) / n, 0.001),
			" | Candidate mean: ", snappedf(float(s["new"]) / n, 0.001))
		print("Original ABG selected: ", snappedf(100.0 * float(s["old_abg"]) / n, 0.1),
			"% | Candidate: ", snappedf(100.0 * float(s["new_abg"]) / n, 0.1), "%")
		print("Original switches: ", int(s["old_switches"]),
			" | Candidate switches: ", int(s["new_switches"]))
	print("\n========== RECOVERY WINDOWS ==========")
	var window_names: Array[String] = ["0-2 s", "2-5 s", "5-10 s", "10-20 s"]
	for i in range(4):
		var w: Dictionary = windows[i]
		if int(w["n"]) == 0:
			continue
		var n: float = float(w["n"])
		print(window_names[i], " | Original error: ", snappedf(float(w["old"]) / n, 0.001),
			" | Candidate error: ", snappedf(float(w["new"]) / n, 0.001),
			" | Original ABG%: ", snappedf(100.0 * float(w["old_abg"]) / n, 0.1),
			" | Candidate ABG%: ", snappedf(100.0 * float(w["new_abg"]) / n, 0.1))
	print("\n========== SWITCHING SUMMARY ==========")
	print("Original total switches: ", old_total_switches,
		" | Candidate total switches: ", new_total_switches)
	print("Original recoveries: ", old_success, "/", seed_count,
		" | Candidate recoveries: ", new_success, "/", seed_count)
	if old_success > 0 and new_success > 0:
		print("Original mean recovery delay: ", snappedf(old_time_sum / float(old_success), 0.001),
			" s | Candidate: ", snappedf(new_time_sum / float(new_success), 0.001), " s")
	print("Original post-recovery reversals: ", old_reversals,
		" | Candidate: ", new_reversals)
	print("CSV: ", ProjectSettings.globalize_path(path))
	print("=======================================")
