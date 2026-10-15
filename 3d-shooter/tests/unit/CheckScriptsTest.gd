extends GdUnitTestSuite
## tests/check_scripts.gd must accept abstract classes and reject failed loads.

const CHECK_SCRIPTS: Script = preload("res://tests/check_scripts.gd")
const ABSTRACT_FIXTURE: Script = preload("res://tests/fixtures/AbstractScriptFixture.gd")


func test_abstract_and_concrete_scripts_pass_and_missing_script_fails() -> void:
	assert_bool(ABSTRACT_FIXTURE.is_abstract()).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(ABSTRACT_FIXTURE)).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(preload("res://combat/StatBlock.gd"))).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(null)).is_false()
