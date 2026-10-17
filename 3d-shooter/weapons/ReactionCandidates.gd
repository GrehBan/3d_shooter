class_name ReactionCandidates
extends Node3D
## Physics adapter of M2.3b reactions: a least-recently-refreshed neighbour cache (contracts
## §2, ReactionRuntime). Each physics tick it re-queries the `queries_per_tick` tracked
## targets whose cache is oldest (never refreshed first, ties to the lower index) with one
## preallocated ShapeCast3D sphere and keeps up to K neighbouring hitbox handles per target.
## A shot only copies the cache of each hit target into its ShotBatch trace before publish,
## so the shot frame runs no queries. No result arrays at the GDScript level (the ShapeCast3D
## keeps its results inside the engine).
##
## Cache age bound: a target is refreshed at most ceil((N0 + S) / Q) refresh steps (physics
## ticks while the adapter is active) after its previous refresh (or its track), where N0 is
## the number of tracked targets at that moment and S the number of targets tracked since;
## with no spawns that is ceil(N / Q). Which
## bodies overlap and how old a cache is are physics and stay outside the deterministic
## contour: the logic validates every handle by full handle and HP and sorts what it gets.
##
## Physics priority 0: after the Sandbox death marks (-1), before HitscanWeapon (10), so a
## shot copies caches refreshed in the same tick.

## Hitboxes (layer 7, "hitbox") are the only bodies that can be reaction candidates.
## Invariant: one hitbox per handle. untrack() takes a dead target's hitbox off layer 7 and
## track() puts it back, so a dead target is never a candidate after its death is applied.
const CANDIDATE_MASK: int = 64
const HITBOX_LAYER: int = 7
const OVERFLOW_WARNING: String = "ReactionCandidates: more hitboxes in the area than the candidate capacity; extra candidates dropped"
const CONFIGURATION_ERROR: String = "ReactionCandidates: invalid configuration, tracking or ticket"

var queries: int = 0
## Queries that found more candidates than the room's capacity K (normal in a crowd).
var overflows: int = 0
## Query results that are no candidate: a body without a handle or another hitbox of the
## queried target itself.
var ignored_results: int = 0
var configuration_errors: int = 0
## Set by the weapon: the cache is refreshed only while some pellet can need candidates.
var active: bool = false
var _cast: ShapeCast3D
var _batch: ShotBatch
var _capacity: int = 0
var _queries_per_tick: int = 0
var _bodies: Array[CollisionObject3D] = []
var _handles: PackedInt64Array = PackedInt64Array()
var _tracked: int = 0
var _index_by_slot: PackedInt32Array = PackedInt32Array()
var _cache: PackedInt64Array = PackedInt64Array()
var _cache_count: PackedInt32Array = PackedInt32Array()
# Refresh step of the last refresh (or of the track); 1 in _fresh until the first refresh.
var _since: PackedInt64Array = PackedInt64Array()
var _fresh: PackedByteArray = PackedByteArray()
var _step: int = 0
# Indices picked by the current refresh step, oldest first (Q entries).
var _pick: PackedInt32Array = PackedInt32Array()
var _bound: bool = false
var _warned: bool = false
var _reported: bool = false


## Cold: radius from the reaction preset, K from the batch, room slots and the per-tick
## query quota from RoomConfig. Queries ask for K + 2 results, so the target plus K + 1
## others reveal an overflow.
func initialize(batch: ShotBatch, radius_mm: int, slots: int, queries_per_tick: int,
		excluded_body: CollisionObject3D = null) -> bool:
	if _bound or batch == null or batch.candidate_capacity() <= 0 or radius_mm <= 0 \
			or slots <= 0 or slots > HandlePool.MAX_CAPACITY or queries_per_tick <= 0:
		_refuse()
		return false
	_batch = batch
	_capacity = batch.candidate_capacity()
	_queries_per_tick = queries_per_tick
	_bodies.resize(slots)
	_handles.resize(slots)
	_index_by_slot.resize(slots)
	_index_by_slot.fill(-1)
	_cache.resize(slots * _capacity)
	_cache_count.resize(slots)
	_since.resize(slots)
	_fresh.resize(slots)
	_pick.resize(queries_per_tick)
	_cast = ShapeCast3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = float(radius_mm) / 1000.0
	_cast.shape = sphere
	_cast.target_position = Vector3.ZERO
	_cast.enabled = false
	_cast.collision_mask = CANDIDATE_MASK
	_cast.max_results = _capacity + 2
	if excluded_body != null:
		_cast.add_exception(excluded_body)
	add_child(_cast)
	process_physics_priority = 0
	_bound = true
	return true


func is_initialized() -> bool:
	return _bound


func tracked_count() -> int:
	return _tracked


## Spawn or respawn: follows `body` as the hitbox of the full handle `target` and puts it on
## the hitbox layer. A new handle in a tracked slot replaces the old one and empties its
## cache. A never-refreshed target sorts before every refreshed one.
func track(body: CollisionObject3D, target: int) -> bool:
	if not _bound or body == null or target < 0:
		return _refuse()
	var slot: int = target % HandlePool.INDEX_SPAN
	if slot >= _index_by_slot.size():
		return _refuse()
	var index: int = _index_by_slot[slot]
	if index < 0:
		index = _tracked
		_tracked += 1
		_index_by_slot[slot] = index
	_bodies[index] = body
	_handles[index] = target
	_cache_count[index] = 0
	_since[index] = _step
	_fresh[index] = 1
	body.set_collision_layer_value(HITBOX_LAYER, true)
	return true


## Applied death or release: the target leaves the cache and its hitbox leaves layer 7, so
## other targets stop finding it from their next refresh on. Its handle may remain in other
## caches until then; the logic rejects it there by HP. An untracked or stale handle is a
## no-op.
func untrack(target: int) -> void:
	var index: int = _tracked_index(target)
	if index < 0:
		return
	var body: CollisionObject3D = _bodies[index]
	if is_instance_valid(body):
		body.set_collision_layer_value(HITBOX_LAYER, false)
	var last: int = _tracked - 1
	if index != last:
		_bodies[index] = _bodies[last]
		_handles[index] = _handles[last]
		_cache_count[index] = _cache_count[last]
		_since[index] = _since[last]
		_fresh[index] = _fresh[last]
		for candidate: int in _cache_count[last]:
			_cache[index * _capacity + candidate] = _cache[last * _capacity + candidate]
		_index_by_slot[_handles[index] % HandlePool.INDEX_SPAN] = index
	_bodies[last] = null
	_cache_count[last] = 0
	_index_by_slot[target % HandlePool.INDEX_SPAN] = -1
	_tracked = last


## Physics tick: refreshes the queries_per_tick targets with the oldest cache. One pass over
## the tracked targets keeps the Q oldest in a preallocated list (never refreshed first, then
## the oldest refresh, ties to the lower index); each is refreshed once.
func refresh_step() -> void:
	if not _bound or not active or _tracked == 0:
		return
	_step += 1
	var want: int = mini(_queries_per_tick, _tracked)
	var picked: int = 0
	for index: int in _tracked:
		var fresh: int = _fresh[index]
		var since: int = _since[index]
		if picked == want:
			var youngest: int = _pick[want - 1]
			if fresh < _fresh[youngest] or (fresh == _fresh[youngest] and since >= _since[youngest]):
				continue
		var at: int = picked if picked < want else want - 1
		while at > 0:
			var before: int = _pick[at - 1]
			if fresh < _fresh[before] or (fresh == _fresh[before] and since >= _since[before]):
				break
			_pick[at] = before
			at -= 1
		_pick[at] = index
		if picked < want:
			picked += 1
	for query: int in want:
		_refresh(_pick[query])


## Physics tick, before publish: copies the cached neighbours of `target` into the trace.
## An untracked target has no candidates. Returns how many were written.
func copy_to(ticket: int, trace: int, target: int) -> int:
	if not _bound:
		return 0
	var index: int = _tracked_index(target)
	var written: int = _batch.add_candidates(ticket, trace, _cache,
			0 if index < 0 else index * _capacity, 0 if index < 0 else _cache_count[index])
	if written < 0:
		_refuse()
		return 0
	return written


func cached_count(target: int) -> int:
	var index: int = _tracked_index(target)
	return 0 if index < 0 else _cache_count[index]


## Read-only: refresh steps since the target's cache was last refreshed (or since it was
## tracked, if never); -1 for an untracked target.
func cache_age(target: int) -> int:
	var index: int = _tracked_index(target)
	return -1 if index < 0 else _step - _since[index]


func reset_diagnostics() -> void:
	queries = 0
	overflows = 0
	ignored_results = 0
	configuration_errors = 0
	_warned = false
	_reported = false


func _physics_process(_delta: float) -> void:
	refresh_step()


func _refresh(index: int) -> void:
	_since[index] = _step
	_fresh[index] = 0
	var body: CollisionObject3D = _bodies[index]
	if not is_instance_valid(body) or not body.is_inside_tree():
		_cache_count[index] = 0
		return
	var own: int = _handles[index]
	_cast.global_position = body.global_position
	_cast.force_shapecast_update()
	queries += 1
	var written: int = 0
	var seen_self: bool = false
	var overflow: bool = false
	for result: int in _cast.get_collision_count():
		var handle: int = Damageable.handle_of(_cast.get_collider(result))
		if handle == own and not seen_self:
			seen_self = true
			continue
		if handle == Damageable.NO_HANDLE or handle == own:
			ignored_results += 1
			continue
		if written == _capacity:
			overflow = true
			continue
		_cache[index * _capacity + written] = handle
		written += 1
	_cache_count[index] = written
	if overflow:
		overflows += 1
		if not _warned:
			_warned = true
			push_warning(OVERFLOW_WARNING)


func _tracked_index(target: int) -> int:
	if not _bound or target < 0:
		return -1
	var slot: int = target % HandlePool.INDEX_SPAN
	if slot >= _index_by_slot.size() or _index_by_slot[slot] < 0 or _handles[_index_by_slot[slot]] != target:
		return -1
	return _index_by_slot[slot]


func _refuse() -> bool:
	configuration_errors += 1
	if not _reported:
		_reported = true
		push_error(CONFIGURATION_ERROR)
	return false
