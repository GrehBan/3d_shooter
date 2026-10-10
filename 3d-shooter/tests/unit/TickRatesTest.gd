extends GdUnitTestSuite
## Частоты тиков (CLAUDE.md, догма 5) закреплены тестом, а не строкой в
## project.godot: редактор не хранит значения по умолчанию и удаляет
## physics_ticks_per_second=60 при сохранении проекта.


func test_physics_tick_is_60_hz() -> void:
	assert_int(Engine.physics_ticks_per_second).is_equal(60)
	assert_int(int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second"))).is_equal(60)


func test_physics_interpolation_is_enabled() -> void:
	assert_bool(bool(ProjectSettings.get_setting("physics/common/physics_interpolation"))).is_true()


func test_logic_tick_is_30_hz() -> void:
	assert_int(GameLoop.EXPECTED_PHYSICS_TICKS_PER_SECOND).is_equal(60)
	assert_int(Engine.physics_ticks_per_second / LogicClock.PHYSICS_TICKS_PER_LOGIC_TICK).is_equal(30)
