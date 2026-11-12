extends Area3D

signal observation_received(
	measured_position: Vector3,
	identification: String
)

@export var measurement_error: float = 0.5
@export var scan_interval: float = 0.2

var scan_timer: float = 0.0

func _physics_process(delta: float) -> void:
	scan_timer += delta

	if scan_timer < scan_interval:
		return

	scan_timer = 0.0

	var detected_areas = get_overlapping_areas()


	for area in detected_areas:

		var target = area.get_parent()

		if not target.has_method("get_iff_response"):
			continue

		var measured_position = target.global_position

		measured_position += Vector3(
			randfn(0.0, measurement_error),
			randfn(0.0, measurement_error),
			randfn(0.0, measurement_error)
		)

		var identification = "UNKNOWN"

		if target.get_iff_response():
			identification = "FRIENDLY"


		observation_received.emit(
			measured_position,
			identification
		)
