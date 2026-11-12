
extends Node
class_name RadarNoiseExperiment

@export_group("Execution")
@export var enabled: bool = false
@export var run_on_start: bool = true

@export_group("References")
@export var radar_sensor: Node
@export var tracking_manager: TrackingManager

@export_group("Timing")
@export var phase_duration: float = 20.0
@export var status_interval: float = 5.0

@export_group("Simulated Measurement Noise")
@export var clear_noise: float = 0.0
@export var mild_noise: float = 0.1
@export var heavy_noise: float = 0.5

var elapsed: float = 0.0
var next_status_time: float = 0.0
var current_phase: int = -1

var original_noise: float = 0.0
var original_noise_saved: bool = false
var running: bool = false


func _ready() -> void:
	set_process(false)

	if enabled and run_on_start:
		start_experiment()


func start_experiment() -> void:
	if running:
		return

	if radar_sensor == null or tracking_manager == null:
		push_error(
            "RadarNoiseExperiment: Assign radar and TrackingManager."
		)
		return

	if phase_duration <= 0.0:
		push_error("RadarNoiseExperiment: Invalid phase duration.")
		return

	# Confirm the radar exposes measurement_error.
	var property_found: bool = false

	for property in radar_sensor.get_property_list():
		if property["name"] == "measurement_error":
			property_found = true
			break

	if not property_found:
		push_error(
            "RadarNoiseExperiment: Radar has no measurement_error property."
		)
		return

	original_noise = float(radar_sensor.get("measurement_error"))
	original_noise_saved = true

	elapsed = 0.0
	next_status_time = maxf(status_interval, 0.0)
	current_phase = -1
	running = true

	print("")
	print("========== LIVE RADAR EXPERIMENT ==========")
	print("Original radar noise: ", original_noise)
	print("Phase duration: ", phase_duration, " seconds")
	print("==========================================")

	set_process(true)
	change_phase(0)


func _process(delta: float) -> void:
	if not running:
		return

	elapsed += delta

	var phase: int = int(floor(elapsed / phase_duration))

	if phase >= 4:
		finish_experiment()
		return

	if phase != current_phase:
		change_phase(phase)

	if status_interval > 0.0 and elapsed >= next_status_time:
		print_status()
		next_status_time += status_interval


func change_phase(phase: int) -> void:
	current_phase = phase

	var phase_name: String = ""
	var noise_value: float = 0.0

	match phase:
		0:
			phase_name = "CLEAR"
			noise_value = clear_noise

		1:
			phase_name = "MILD INTERFERENCE"
			noise_value = mild_noise

		2:
			phase_name = "HEAVY INTERFERENCE"
			noise_value = heavy_noise

		3:
			phase_name = "RECOVERY"
			noise_value = clear_noise

		_:
			return

	radar_sensor.set("measurement_error", noise_value)

	print("")
	print("========== RADAR CONDITION CHANGE ==========")
	print("Time: ", snappedf(elapsed, 0.1), " s")
	print("Condition: ", phase_name)
	print("Measurement error: ", noise_value)
	print("============================================")


func print_status() -> void:
	var manager := tracking_manager

	print(
		"[Radar Experiment] t=",
		snappedf(elapsed, 0.1),
		"s | Noise=",
		radar_sensor.get("measurement_error"),
		" | Health=",
		manager.sensor_health_status,
		" | Innovation EMA=",
		snappedf(manager.innovation_ema, 0.001),
		" | Selected=",
		manager.selected_estimator,
		" | Switches=",
		manager.filter_switch_count
	)


func finish_experiment() -> void:
	running = false
	set_process(false)

	restore_radar()

	print("")
	print("========== RADAR EXPERIMENT COMPLETE ==========")
	print("Duration: ", snappedf(elapsed, 0.1), " s")
	print("Final selected estimator: ",
		tracking_manager.selected_estimator)
	print("Total filter switches: ",
		tracking_manager.filter_switch_count)
	print("Original radar noise restored: ", original_noise)
	print("===============================================")


func restore_radar() -> void:
	if original_noise_saved and is_instance_valid(radar_sensor):
		radar_sensor.set("measurement_error", original_noise)
		original_noise_saved = false


func _exit_tree() -> void:
	restore_radar()
