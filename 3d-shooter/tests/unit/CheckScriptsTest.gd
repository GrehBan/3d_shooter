extends GdUnitTestSuite
## tests/check_scripts.gd accepts valid scripts, including @abstract ones, and rejects scripts
## that failed to compile. Broken sources are compiled in memory, never stored on disk, so the
## full script walk stays green; their error output is silenced so the CI log scan is clean.

const CHECK_SCRIPTS: Script = preload("res://tests/check_scripts.gd")
const ABSTRACT_FIXTURE: Script = preload("res://tests/fixtures/AbstractScriptFixture.gd")


## Returns the script and the reload() code; restores the previous error-printing state.
static func _compile(source: String) -> Array:
	var script := GDScript.new()
	script.source_code = source
	var printing: bool = Engine.print_error_messages
	Engine.print_error_messages = false
	var code: int = script.reload()
	Engine.print_error_messages = printing
	return [script, code]


func test_valid_concrete_and_abstract_scripts_pass() -> void:
	assert_bool(ABSTRACT_FIXTURE.is_abstract()).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(ABSTRACT_FIXTURE)).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(preload("res://combat/StatBlock.gd"))).is_true()
	var abstract_in_memory: Array = _compile("@abstract
extends RefCounted
@abstract func f() -> int
")
	assert_int(abstract_in_memory[1]).is_equal(OK)
	assert_bool((abstract_in_memory[0] as GDScript).is_abstract()).is_true()
	assert_bool(CHECK_SCRIPTS.is_loadable(abstract_in_memory[0])).is_true()
	var concrete_in_memory: Array = _compile("extends RefCounted
func f() -> int:
	return 1
")
	assert_int(concrete_in_memory[1]).is_equal(OK)
	assert_bool(CHECK_SCRIPTS.is_loadable(concrete_in_memory[0])).is_true()


func test_scripts_that_failed_to_compile_are_rejected() -> void:
	var printing_before: bool = Engine.print_error_messages
	var broken: Array[Array] = [
		_compile("extends RefCounted
func f( -> int:
	return 1
"),
		_compile("@abstract
extends RefCounted
func f( -> int
"),
		_compile("@abstract
extends RefCounted
func f() -> int:
	var x: int = \"s\"
	return x
"),
	]
	assert_bool(Engine.print_error_messages).is_equal(printing_before)
	for compiled: Array in broken:
		assert_int(compiled[1]).is_not_equal(OK)
		assert_bool(CHECK_SCRIPTS.is_loadable(compiled[0])).is_false()


func test_null_script_fails() -> void:
	assert_bool(CHECK_SCRIPTS.is_loadable(null)).is_false()
