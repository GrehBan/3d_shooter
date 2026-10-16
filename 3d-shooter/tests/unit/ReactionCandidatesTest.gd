extends GdUnitTestSuite
## Physics adapter of M2.3b reactions: the least-recently-refreshed neighbour cache, its age
## bound, counters and lifecycle, and the copy into ShotBatch on the shot path of
## HitscanWeapon.

var _root: Node3D


func before_test() -> void:
	_root = Node3D.new()
	add_child(_root)


func after_test() -> void:
	if is_instance_valid(_root):
		_root.free()


func _body(position: Vector3, layer: int, handle: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 1.6, 0.6)
	shape.shape = box
	body.add_child(shape)
	body.position = position
	body.collision_layer = layer
	body.collision_mask = 0
	_root.add_child(body)
	if handle >= 0:
		Damageable.attach(body, handle)
	return body


func _adapter(batch: ShotBatch, queries_per_tick: int = 4) -> ReactionCandidates:
	var adapter := ReactionCandidates.new()
	assert_bool(adapter.initialize(batch, 3000, 64, queries_per_tick)).is_true()
	_root.add_child(adapter)
	adapter.set_physics_process(false)  # the tests drive refresh_step() themselves
	adapter.active = true
	return adapter


func _copied(batch: ShotBatch, adapter: ReactionCandidates, target: int) -> Array[int]:
	var ticket: int = batch.reserve(0, 1, 1000)
	batch.write_trace(ticket, 0, target)
	adapter.copy_to(ticket, 0, target)
	batch.publish(ticket)
	batch.prepare()
	var out: Array[int] = []
	for index: int in batch.candidate_count_at(0, 0):
		out.append(batch.candidate_at(0, 0, index))
	batch.consume_prepared()
	out.sort()
	return out


func test_refresh_caches_hitboxes_in_the_sphere_and_copy_writes_them() -> void:
	var primary: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 10)
	_body(Vector3(2, 0, 0), ReactionCandidates.CANDIDATE_MASK, 11)
	_body(Vector3(0, 0, -2), ReactionCandidates.CANDIDATE_MASK, 12)
	_body(Vector3(5, 0, 0), ReactionCandidates.CANDIDATE_MASK, 13)  # outside 3 m
	_body(Vector3(-1, 0, 0), 1, 14)  # world layer: never a candidate
	_body(Vector3(0, 0, 1.5), ReactionCandidates.CANDIDATE_MASK, -1)  # hitbox without a handle
	var batch := ShotBatch.new(1, 1, 64, 8)
	var adapter: ReactionCandidates = _adapter(batch)
	assert_bool(adapter.track(primary, 10)).is_true()
	await get_tree().physics_frame
	adapter.refresh_step()
	assert_int(adapter.queries).is_equal(1)
	assert_int(adapter.cached_count(10)).is_equal(2)
	assert_int(adapter.ignored_results).is_equal(1)
	assert_int(adapter.overflows).is_equal(0)
	assert_array(_copied(batch, adapter, 10)).is_equal([11, 12])
	assert_array(_copied(batch, adapter, 11)).is_empty()  # untracked target: no candidates
	assert_int(adapter.queries).is_equal(1)  # copying never queries


func test_crowd_over_capacity_counts_an_overflow_and_keeps_k() -> void:
	var primary: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 10)
	for index: int in 3:
		_body(Vector3(1.5 * (index + 1) - 2.5, 0, 1.5), ReactionCandidates.CANDIDATE_MASK, 20 + index)
	var batch := ShotBatch.new(1, 1, 64, 2)
	var adapter: ReactionCandidates = _adapter(batch)
	adapter.track(primary, 10)
	await get_tree().physics_frame
	var refresh := func() -> void: adapter.refresh_step()
	await assert_error(refresh).is_push_warning(ReactionCandidates.OVERFLOW_WARNING)
	assert_int(adapter.overflows).is_equal(1)
	assert_int(adapter.cached_count(10)).is_equal(2)
	assert_int(adapter.configuration_errors).is_equal(0)  # a crowd is not a configuration error
	assert_int(batch.configuration_errors).is_equal(0)


func test_invalid_ticket_or_trace_is_a_configuration_error() -> void:
	var batch := ShotBatch.new(1, 1, 64, 2)
	var adapter: ReactionCandidates = _adapter(batch)
	await assert_error(func() -> void: assert_int(adapter.copy_to(12345, 0, 10)).is_equal(0)) \
			.is_push_error(ReactionCandidates.CONFIGURATION_ERROR)
	var ticket: int = batch.reserve(0, 1, 1000)
	assert_int(batch.candidate_space(ticket, 0)).is_equal(2)
	assert_int(batch.candidate_space(ticket, 1)).is_equal(-1)
	assert_int(adapter.copy_to(ticket, 1, 10)).is_equal(0)
	assert_int(adapter.configuration_errors).is_equal(2)
	adapter.reset_diagnostics()
	await assert_error(func() -> void: assert_bool(adapter.track(null, 1)).is_false()) \
			.is_push_error(ReactionCandidates.CONFIGURATION_ERROR)


func test_candidates_are_written_only_before_publish() -> void:
	var batch := ShotBatch.new(1, 2, 8, 2)
	var ticket: int = batch.reserve(0, 2, 1000)
	assert_bool(batch.add_candidate(ticket, 2, 5)).is_false()  # trace out of range
	assert_bool(batch.add_candidate(ticket, 0, 5)).is_true()
	assert_bool(batch.add_candidate(ticket, 0, 6)).is_true()
	assert_bool(batch.add_candidate(ticket, 0, 7)).is_false()  # full
	batch.write_trace(ticket, 0, 1)
	batch.write_trace(ticket, 1, 1)
	batch.publish(ticket)
	assert_bool(batch.add_candidate(ticket, 1, 8)).is_false()  # published: physics is done
	assert_int(batch.candidate_space(ticket, 1)).is_equal(-1)
	assert_int(batch.prepare()).is_equal(1)
	assert_int(batch.candidate_count_at(0, 0)).is_equal(2)
	assert_int(batch.candidate_at(0, 0, 1)).is_equal(6)


func test_new_targets_go_first_and_untracked_targets_leave_the_cache_and_layer() -> void:
	var a: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 1)
	var b: StaticBody3D = _body(Vector3(2, 0, 0), ReactionCandidates.CANDIDATE_MASK, 2)
	var c: StaticBody3D = _body(Vector3(-2, 0, 0), ReactionCandidates.CANDIDATE_MASK, 3)
	var batch := ShotBatch.new(1, 1, 64, 8)
	var adapter: ReactionCandidates = _adapter(batch, 1)
	adapter.track(a, 1)
	adapter.track(b, 2)
	await get_tree().physics_frame
	adapter.refresh_step()
	adapter.refresh_step()
	assert_int(adapter.cached_count(1)).is_equal(2)  # b and the not yet tracked c both stand nearby
	assert_int(adapter.cached_count(2)).is_equal(1)  # c is 4 m from b
	adapter.track(c, 3)  # a spawn sorts first: refreshed on the very next step
	var before_spawn: int = adapter.queries
	assert_int(adapter.cached_count(3)).is_equal(0)
	adapter.refresh_step()
	assert_int(adapter.queries - before_spawn).is_equal(1)
	assert_int(adapter.cached_count(3)).is_greater(0)
	adapter.untrack(2)  # applied death: out of the cache, hitbox off layer 7
	assert_int(adapter.tracked_count()).is_equal(2)
	assert_bool(b.get_collision_layer_value(ReactionCandidates.HITBOX_LAYER)).is_false()
	assert_int(adapter.cached_count(2)).is_equal(0)
	assert_array(_copied(batch, adapter, 2)).is_empty()
	adapter.untrack(2)  # already gone: a no-op
	adapter.untrack(65538)  # stale handle of slot 2: a no-op
	var queries: int = adapter.queries
	await get_tree().physics_frame  # the layer change reaches the physics space
	for step: int in 2:
		adapter.refresh_step()
	assert_int(adapter.queries - queries).is_equal(2)
	# b's hitbox left layer 7, so a only finds c now.
	assert_array(_copied(batch, adapter, 1)).is_equal([3])
	# Respawn of slot 2 with a new generation: back on layer 7, refreshed first.
	Damageable.attach(b, 65538)
	assert_bool(adapter.track(b, 65538)).is_true()
	assert_bool(b.get_collision_layer_value(ReactionCandidates.HITBOX_LAYER)).is_true()
	assert_int(adapter.tracked_count()).is_equal(3)
	assert_int(adapter.cache_age(2)).is_equal(-1)  # the old generation is gone
	assert_int(adapter.cache_age(65538)).is_equal(0)
	await get_tree().physics_frame
	adapter.refresh_step()
	assert_array(_copied(batch, adapter, 65538)).is_equal([1])
	assert_int(adapter.cache_age(65538)).is_equal(0)
	assert_int(adapter.configuration_errors).is_equal(0)


## A new generation tracked over a slot that was never untracked replaces the stale handle
## in place: no second entry, the old handle has no cache.
func test_retracking_a_slot_with_a_new_generation_replaces_it() -> void:
	var a: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 5)
	_body(Vector3(1, 0, 0), ReactionCandidates.CANDIDATE_MASK, 6)
	var batch := ShotBatch.new(1, 1, 64, 8)
	var adapter: ReactionCandidates = _adapter(batch, 1)
	adapter.track(a, 5)
	await get_tree().physics_frame
	adapter.refresh_step()
	assert_int(adapter.cached_count(5)).is_equal(1)
	Damageable.attach(a, 5 + HandlePool.INDEX_SPAN)
	assert_bool(adapter.track(a, 5 + HandlePool.INDEX_SPAN)).is_true()
	assert_int(adapter.tracked_count()).is_equal(1)
	assert_int(adapter.cached_count(5)).is_equal(0)
	assert_int(adapter.cached_count(5 + HandlePool.INDEX_SPAN)).is_equal(0)  # emptied
	adapter.untrack(5)  # the stale generation is a no-op
	assert_int(adapter.tracked_count()).is_equal(1)
	adapter.refresh_step()
	assert_int(adapter.cached_count(5 + HandlePool.INDEX_SPAN)).is_equal(1)


## Contracts §2: a target is refreshed at most ceil((N0 + S) / Q) refresh steps after its
## previous refresh or its track (N0 tracked targets at that moment, S tracked since).
## Off-tree bodies: the bound is about the selection, not the queries.
func test_cache_age_bound_holds_under_seeded_death_and_respawn_churn() -> void:
	var violations: int = 0
	var checks: int = 0
	for queries_per_tick: int in [1, 2, 3]:
		for population: int in [5, 20, 40]:
			var result: PackedInt32Array = _churn(queries_per_tick, population, 97 * population + queries_per_tick)
			violations += result[0]
			checks += result[1]
	assert_int(checks).is_greater(10000)
	assert_int(violations).is_equal(0)


## No spawns: every target is refreshed exactly every ceil(N / Q) steps.
func test_cache_age_without_spawns_is_ceil_n_over_q() -> void:
	for queries_per_tick: int in [1, 2, 3]:
		for population: int in [5, 20, 40]:
			var batch := ShotBatch.new(1, 1, 64, 8)
			var adapter: ReactionCandidates = _adapter(batch, queries_per_tick)
			var bodies: Array[StaticBody3D] = []
			for target: int in population:
				bodies.append(StaticBody3D.new())
				adapter.track(bodies[target], target)
			var worst: int = 0
			for step: int in 4 * population:
				adapter.refresh_step()
				for target: int in population:
					worst = maxi(worst, adapter.cache_age(target))
			for body: StaticBody3D in bodies:
				body.free()
			adapter.free()
			# Ages are read after each step, so the longest interval is worst + 1.
			assert_int(worst + 1).is_equal(ceili(float(population) / float(queries_per_tick)))


## Returns [violations, checks] of one seeded churn run.
func _churn(queries_per_tick: int, population: int, seed_value: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var batch := ShotBatch.new(1, 1, 64, 8)
	var adapter: ReactionCandidates = _adapter(batch, queries_per_tick)
	var bodies: Array[StaticBody3D] = []
	var handle: PackedInt64Array = PackedInt64Array()
	var alive: PackedByteArray = PackedByteArray()
	var n0: PackedInt32Array = PackedInt32Array()
	var spawned_since: PackedInt32Array = PackedInt32Array()
	for slot: int in population:
		bodies.append(StaticBody3D.new())
		handle.append(slot)
		alive.append(0)
		n0.append(0)
		spawned_since.append(0)
	var live: int = 0
	var out := PackedInt32Array([0, 0])
	for step: int in 300 + population * 10:
		if step == 0:
			for slot: int in population:
				_churn_track(adapter, bodies, handle, alive, n0, spawned_since, slot)
			live = population
		else:
			if live > 0 and rng.randf() < 0.3:
				var victim: int = rng.randi_range(0, population - 1)
				while alive[victim] == 0:
					victim = (victim + 1) % population
				adapter.untrack(handle[victim])
				alive[victim] = 0
				live -= 1
			if live < population and rng.randf() < 0.3:
				var slot: int = rng.randi_range(0, population - 1)
				while alive[slot] != 0:
					slot = (slot + 1) % population
				handle[slot] += HandlePool.INDEX_SPAN  # respawn: next generation of the slot
				_churn_track(adapter, bodies, handle, alive, n0, spawned_since, slot)
				live += 1
		adapter.refresh_step()
		for slot: int in population:
			if alive[slot] == 0:
				continue
			var age: int = adapter.cache_age(handle[slot])
			var bound: int = ceili(float(n0[slot] + spawned_since[slot]) / float(queries_per_tick))
			out[1] += 1
			if age < 0 or age + 1 > bound:
				out[0] += 1
			if age == 0:
				n0[slot] = adapter.tracked_count()
				spawned_since[slot] = 0
	for body: StaticBody3D in bodies:
		body.free()
	adapter.free()
	return out


func _churn_track(adapter: ReactionCandidates, bodies: Array[StaticBody3D], handle: PackedInt64Array,
		alive: PackedByteArray, n0: PackedInt32Array, spawned_since: PackedInt32Array, slot: int) -> void:
	for other: int in alive.size():
		if alive[other] != 0:
			spawned_since[other] += 1
	adapter.track(bodies[slot], handle[slot])
	alive[slot] = 1
	n0[slot] = adapter.tracked_count()
	spawned_since[slot] = 0


func _weapon(element: DamagePayload.Element) -> Array:
	var stats := StatBlock.new(16)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	var statuses := StatusRuntime.new(stats)
	var reactions := ReactionRuntime.new(stats, statuses)
	var batch := ShotBatch.new(4, 8, 16, 8)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_root.add_child(weapon)
	var data := WeaponData.new()
	data.element = element
	assert_bool(weapon.initialize(data, stats, batch, source)).is_true()
	weapon.set_physics_process(false)
	assert_bool(weapon.bind_reactions(reactions, 16, 2)).is_true()
	assert_bool(weapon.bind_reactions(reactions, 16, 2)).is_false()  # bound once
	weapon.reaction_candidates.set_physics_process(false)
	return [weapon, batch]


func test_weapon_copies_the_cache_without_queries_on_the_shot() -> void:
	var wall: StaticBody3D = _body(Vector3(0, 0, -6), ReactionCandidates.CANDIDATE_MASK, 3)
	((wall.get_child(0) as CollisionShape3D).shape as BoxShape3D).size = Vector3(4, 4, 0.5)  # every pellet
	var side: StaticBody3D = _body(Vector3(2.5, 0, -6), ReactionCandidates.CANDIDATE_MASK, 4)
	var parts: Array = _weapon(DamagePayload.Element.ELECTRIC)
	var weapon: HitscanWeapon = parts[0]
	var batch: ShotBatch = parts[1]
	weapon.reaction_candidates.track(wall, 3)
	weapon.reaction_candidates.track(side, 4)
	await get_tree().physics_frame
	weapon.reaction_candidates.refresh_step()
	var queries: int = weapon.reaction_candidates.queries
	weapon.set_fire_pressed(true)
	weapon._physics_process(1.0 / 60.0)
	assert_int(weapon.reaction_candidates.queries).is_equal(queries)
	assert_int(batch.prepare()).is_equal(1)
	for trace: int in batch.trace_count_at(0):
		assert_int(batch.target_at(0, trace)).is_equal(3)
		assert_int(batch.candidate_count_at(0, trace)).is_equal(1)
		assert_int(batch.candidate_at(0, trace, 0)).is_equal(4)


func test_weapon_without_area_reaction_never_refreshes() -> void:
	var wall: StaticBody3D = _body(Vector3(0, 0, -6), ReactionCandidates.CANDIDATE_MASK, 3)
	var parts: Array = _weapon(DamagePayload.Element.ICE)
	var weapon: HitscanWeapon = parts[0]
	weapon.reaction_candidates.track(wall, 3)
	await get_tree().physics_frame
	assert_bool(weapon.reaction_candidates.active).is_false()
	weapon.reaction_candidates.refresh_step()
	weapon.set_fire_pressed(true)
	weapon._physics_process(1.0 / 60.0)
	assert_int(weapon.reaction_candidates.queries).is_equal(0)
	assert_int(weapon.traces_cast).is_equal(8)
