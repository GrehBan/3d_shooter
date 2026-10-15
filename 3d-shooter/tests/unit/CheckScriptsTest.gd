extends GdUnitTestSuite
## tests/check_scripts.gd accepts valid scripts, including @abstract ones, and rejects scripts
## that failed to compile. Broken sources are compiled in memory, never stored on disk, so the
## full script walk stays green; their error output is silenced so the CI log scan is clean.

const CHECK_SCRIPTS: Script = preload("res://tests/check_scripts.gd")
const ABSTRACT_FIXTURE: Script = preload("res://tests/fixtures/AbstractScriptFixture.gd")


static func _compile(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	Engine.print_error_messages = false
	script.reload()
	Engine.print_error_messages = true
	return script


func test_valid_concrete_and_abstract_scripts_pass() -> void:
	assert_bool(ABSTRACT_FIXTURE.is_abstract()).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(ABSTRACT_FIXTURE)).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(preload("res://combat/StatBlock.gd"))).is_true()
	var abstract_in_memory: GDScript = _compile("@abstract
extends RefCounted
@abstract func f() -> int
")
	assert_bool(abstract_in_memory.is_abstract()).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(abstract_in_memory)).is_true()


func test_scripts_that_failed_to_compile_are_rejected() -> void:
	var syntax: GDScript = _compile("extends RefCounted
func f( -> int:
	return 1
")
	var abstract_syntax: GDScript = _compile("@abstract
extends RefCounted
func f( -> int
")
	var abstract_types: GDScript = _compile(
			"@abstract
extends RefCounted
func f() -> int:
	var x: int = \"s\"
	return x
")
	assert_bool(CHECK_SCRIPTS.is_loadable(syntax)).is_false()
	assert_bool(CHECK_SCRIPTS.is_loadable(abstract_syntax)).is_false()
	assert_bool(CHECK_SCRIPTS.is_loadable(abstract_types)).is_false()


func test_null_script_fails() -> void:
	assert_bool(CHECK_SCRIPTS.is_loadable(null)).is_false()
