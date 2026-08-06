extends RefCounted

## Screenshot capture command

var bridge: Node


func execute(method: String, params: Dictionary) -> Dictionary:
	match method:
		"capture_screenshot":
			return _capture_screenshot(params)
	return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


func _capture_screenshot(params: Dictionary) -> Dictionary:
	var viewport = bridge.get_viewport()
	if not viewport:
		return {"error": {"code": -32000, "message": "No viewport available"}}

	var image = viewport.get_texture().get_image()
	if not image:
		return {"error": {"code": -32000, "message": "Failed to capture viewport image"}}

	# Optional region crop
	if params.has("region"):
		var region = params["region"]
		var rect = Rect2i(
			int(region.get("x", 0)),
			int(region.get("y", 0)),
			int(region.get("width", image.get_width())),
			int(region.get("height", image.get_height()))
		)
		image = image.get_region(rect)

	# Optional downscale to reduce data size
	var max_width = int(params.get("max_width", 0))
	var max_height = int(params.get("max_height", 0))
	if max_width > 0 or max_height > 0:
		var orig_w = image.get_width()
		var orig_h = image.get_height()
		var scale_x = float(max_width) / orig_w if max_width > 0 else 1.0
		var scale_y = float(max_height) / orig_h if max_height > 0 else 1.0
		var scale = min(scale_x, scale_y)
		if scale < 1.0:
			var new_w = int(orig_w * scale)
			var new_h = int(orig_h * scale)
			image.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)

	# Encode to PNG and base64
	var png_data = image.save_png_to_buffer()
	var base64 = Marshalls.raw_to_base64(png_data)

	return {"result": {
		"image": base64,
		"width": image.get_width(),
		"height": image.get_height(),
		"format": "png",
	}}
