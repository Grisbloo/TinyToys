extends Node3D

@export_group("Execution")
@export var enabled: bool = false

@export var target: Node3D
@export var turret: CwisTurret
@export var marker_radius: float = 0.35

var actual_marker: MeshInstance3D
var radar_marker: MeshInstance3D
var estimate_marker: MeshInstance3D


func _ready() -> void:
	if not enabled:
		visible = false
		set_physics_process(false)
		set_process(false)
		return
	actual_marker = create_marker(Color.GREEN)
	radar_marker = create_marker(Color.ORANGE)
	estimate_marker = create_marker(Color.DODGER_BLUE)


func create_marker(color: Color) -> MeshInstance3D:
	var marker = MeshInstance3D.new()

	var sphere = SphereMesh.new()
	sphere.radius = marker_radius
	sphere.height = marker_radius * 2.0

	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	marker.mesh = sphere
	marker.material_override = material

	add_child(marker)

	return marker


func _process(_delta: float) -> void:
	if target == null or turret == null:
		return

	# GREEN: Actual location in the simulation
	actual_marker.global_position = target.global_position

	# ORANGE: Latest radar measurement
	radar_marker.visible = turret.has_observation

	if turret.has_observation:
		radar_marker.global_position = turret.observed_position

	# BLUE: Position estimated by the selected filter
	var estimate_available = (turret.has_observation or turret.tracking_mode == CwisTurret.TrackingMode.PERFECT)
	estimate_marker.visible = estimate_available

	if estimate_available:
		estimate_marker.global_position = (turret.get_estimated_position())
	print_tracking_error(_delta)


var error_timer: float = 0.0

func print_tracking_error(delta: float) -> void:
	error_timer += delta

	if error_timer < 1.0:
		return

	error_timer = 0.0

	if not estimate_marker.visible:
		return

	var error = actual_marker.global_position.distance_to(estimate_marker.global_position)

	#print("Tracking error: ", snappedf(error, 0.01), " m")
