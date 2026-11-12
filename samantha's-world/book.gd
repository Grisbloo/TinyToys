extends Node3D

# Properties we can customize for each book in the Inspector.
@export var book_title: String = "Untitled"
@export var cover_color: Color = Color.BROWN
@export var cover_texture: Texture2D

# Reference to the child mesh representing the book cover.
@onready var cover: MeshInstance3D = $Cover

# Runs when the book and its children are ready.
func _ready() -> void:

	# Create a new material for this particular book.
	var material := StandardMaterial3D.new()

	# Start by giving it the selected cover color.
	material.albedo_color = cover_color

	# If an image was assigned, use it instead.
	if cover_texture != null:
		material.albedo_texture = cover_texture

		# White prevents the material from tinting the image.
		material.albedo_color = Color.WHITE

	# Apply our newly created material to the cover mesh.
	cover.material_override = material
