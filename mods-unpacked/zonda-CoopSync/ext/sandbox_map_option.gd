extends "res://scenes/sandbox_map_option.gd"


func setup(map_data: SandboxMapData, menu: CanvasLayer):
	super(map_data, menu)
	if image.texture != null or not map_data.scene_path.begins_with("res://mods-unpacked/"):
		return
	var png: String = map_data.scene_path.get_basename() + ".png"
	if not FileAccess.file_exists(png):
		return
	var img: Image = Image.load_from_file(png)
	if img:
		image.texture = ImageTexture.create_from_image(img)
