extends RefCounted

const MAX_SNAPS := 64
const MAX_EXTRAPOLATE_MS := 120.0
const MIN_SENDER_SPAN_MS := 12.0     # never extrapolate from a span shorter than this
const SENDER_RESET_MS := 5000        # sender clock jumped back this far: the peer restarted

var _t: Array = []                   # local render time of each snap
var _st: Array = []                  # the sender's own timestamp of each snap
var _snaps: Array = []
var _offset := 0
var _offset_valid := false
var _last_sender_t := -1


func push(sender_t: int, snap) -> void:
	# Drop stale, duplicate and out-of-order packets (unreliable channel). A big backwards
	# jump means the sender restarted its game: start over instead of dropping forever.
	if _last_sender_t >= 0 and sender_t <= _last_sender_t:
		if _last_sender_t - sender_t < SENDER_RESET_MS:
			return
		clear()
		_offset_valid = false
	var now := Time.get_ticks_msec()
	var off := now - sender_t
	if not _offset_valid or off < _offset:
		_offset = off
		_offset_valid = true
	else:
		_offset += int(round(float(off - _offset) * 0.02))
	var t := sender_t + _offset
	if _t.size() > 0:
		# a re-synced (smaller) offset must not squeeze two snaps together: keep at least
		# half of their real send spacing, so extrapolation never sees a 1 ms span
		var min_gap: int = maxi(1, int(float(sender_t - _last_sender_t) * 0.5))
		var floor_t: int = int(_t[_t.size() - 1]) + min_gap
		if t < floor_t:
			t = floor_t
	_t.append(t)
	_st.append(sender_t)
	_snaps.append(snap)
	_last_sender_t = sender_t
	while _snaps.size() > MAX_SNAPS:
		_t.pop_front()
		_st.pop_front()
		_snaps.pop_front()


func is_empty() -> bool:
	return _snaps.is_empty()


func latest():
	if _snaps.is_empty():
		return null
	return _snaps[_snaps.size() - 1]


func clear() -> void:
	_t.clear()
	_st.clear()
	_snaps.clear()
	_last_sender_t = -1


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
	# past the newest snap: extrapolate along the last step, measured in the sender's own
	# time (local times can be compressed by a clock re-sync) and capped in real time
	var sspan: float = maxf(float(int(_st[n - 1]) - int(_st[n - 2])), MIN_SENDER_SPAN_MS)
	var over: float = clampf(float(render_t - int(_t[n - 1])), 0.0, MAX_EXTRAPOLATE_MS)
	var alpha2: float = 1.0 + over / sspan
	return {"a": _snaps[n - 2], "b": _snaps[n - 1], "alpha": alpha2}
