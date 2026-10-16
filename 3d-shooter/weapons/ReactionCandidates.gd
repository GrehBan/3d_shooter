class_name ReactionCandidates
extends Node3D
## Physics adapter of M2.3b reactions: in the physics tick, before a shot is published, it
## finds the damageable hitboxes around a pellet's primary target and writes their full
## handles into that trace of ShotBatch. One preallocated ShapeCast3D sphere; no result
## arrays. Which bodies overlap is physics and stays outside the deterministic contour;
## the logic sorts whatever it receives by full handle (contracts §2, ReactionRuntime).

## Hitboxes (layer 7, "hitbox") are the only bodies that can be reaction candidates.
const CANDIDATE_MASK: int = 64
const OVERFLOW_WARNING: String = "ReactionCandidates: more hitboxes in the area than the candidate capacity; extra candidates dropped"

var queries: int = 0
## Queries that found more candidates than the room's capacity K (normal in a crowd).
var overflows: int = 0
var _cast: ShapeCast3D
var _batch: ShotBatch
var _bound: bool = false
var _warned: bool = false


## Cold: radius from the reaction preset; the capacity K comes from the batch. The query
## asks for K + 2 results so that the primary plus K + 1 others reveal an overflow.
func initialize(batch: ShotBatch, radius_mm: int, excluded_body: CollisionObject3D = null) -> bool:
	if _bound or batch == null or batch.candidate_capacity() <= 0 or radius_mm <= 0:
		return false
	_batch = batch
	_cast = ShapeCast3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = float(radius_mm) / 1000.0
	_cast.shape = sphere
	_cast.target_position = Vector3.ZERO
	_cast.enabled = false
	_cast.collision_mask = CANDIDATE_MASK
	_cast.max_results = batch.candidate_capacity() + 2
	if excluded_body != null:
		_cast.add_exception(excluded_body)
	add_child(_cast)
	_bound = true
	return true


func is_initialized() -> bool:
	return _bound


## Physics tick only: writes up to K candidates other than `primary` found around `body`
## into the reserved ticket's trace. Returns how many were written.
func collect(ticket: int, trace: int, body: Node3D, primary: int) -> int:
	if not _bound or body == null:
		return 0
	_cast.global_position = body.global_position
	_cast.force_shapecast_update()
	queries += 1
	var written: int = 0
	var overflow: bool = false
	for result: int in _cast.get_collision_count():
		var handle: int = Damageable.handle_of(_cast.get_collider(result))
		if handle == Damageable.NO_HANDLE or handle == primary:
			continue
		if not _batch.add_candidate(ticket, trace, handle):
			overflow = true
			break
		written += 1
	if overflow:
		overflows += 1
		if not _warned:
			_warned = true
			push_warning(OVERFLOW_WARNING)
	return written


func reset_diagnostics() -> void:
	queries = 0
	overflows = 0
	_warned = false
