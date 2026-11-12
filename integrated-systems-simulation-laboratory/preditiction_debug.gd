extends Node3D

@export_group("Execution")
@export var enabled: bool = false

@export var turret: CwisTurret
@export_range(0.0, 2.0, 0.05) var prediction_horizon: float = 0.5

var prediction_marker: MeshInstance3D


func _ready() -> void:
	if not enabled:
		visible = false
		set_physics_process(false)
		set_process(false)
		return
	prediction_marker = MeshInstance3D.new()

	var sphere = SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6

	var material = StandardMaterial3D.new()
	material.albedo_color = Color.MAGENTA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	prediction_marker.mesh = sphere
	prediction_marker.material_override = material
	add_child(prediction_marker)


func _physics_process(_delta: float) -> void:
	if turret == null:
		return

	if not turret.has_observation:
		prediction_marker.visible = false
		return

	if turret.tracking_mode != CwisTurret.TrackingMode.ALPHA_BETA:
		prediction_marker.visible = false
		return

	if turret.time_since_observation > turret.contact_timeout:
		prediction_marker.visible = false
		return

	var forecast_time = (
		turret.time_since_observation + prediction_horizon
	)

	var predicted_position = (
		turret.filtered_position
		+ turret.filtered_velocity * forecast_time
	)

	prediction_marker.global_position = predicted_position
	prediction_marker.visible = true
