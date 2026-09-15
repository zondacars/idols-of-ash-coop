extends RefCounted

const MAX_SNAPS := 64
const MAX_EXTRAPOLATE_MS := 120.0

var _t: Array = []
var _snaps: Array = []
var _offset := 0
var _offset_valid := false


func push(sender_t: int, snap) -> void:
	var now := Time.get_ticks_msec()
	var off := now - sender_t
	if not _offset_valid or off < _offset:
		_offset = off
		_offset_valid = true
	else:
		_offset += int(round(float(off - _offset) * 0.02))
	var t := sender_t + _offset
	if _t.size() > 0 and t <= _t[_t.size() - 1]:
		t = _t[_t.size() - 1] + 1
	_t.append(t)
	_snaps.append(snap)
	while _snaps.size() > MAX_SNAPS:
		_t.pop_front()
		_snaps.pop_front()


func is_empty() -> bool:
	return _snaps.is_empty()


func latest():
	if _snaps.is_empty():
		return null
	return _snaps[_snaps.size() - 1]


func clear() -> void:
	_t.clear()
	_snaps.clear()


func sample(delay_ms: int) -> Dictionary:
	var n := _snaps.size()
	if n == 0:
		return {}
	var render_t := Time.get_ticks_msec() - delay_ms
	if n == 1 or render_t <= _t[0]:
		return {"a": _snaps[0], "b": _snaps[0], "alpha": 0.0}
	for i in range(n - 1):
		if render_t >= _t[i] and render_t <= _t[i + 1]:
			var span: int = _t[i + 1] - _t[i]
			var alpha := 0.0
			if span > 0:
				alpha = float(render_t - _t[i]) / float(span)
			return {"a": _snaps[i], "b": _snaps[i + 1], "alpha": alpha}
	var span2: int = _t[n - 1] - _t[n - 2]
	var alpha2 := 1.0
	if span2 > 0:
		alpha2 = clampf(1.0 + float(render_t - _t[n - 1]) / float(span2), 1.0, 1.0 + MAX_EXTRAPOLATE_MS / float(span2))
	return {"a": _snaps[n - 2], "b": _snaps[n - 1], "alpha": alpha2}
