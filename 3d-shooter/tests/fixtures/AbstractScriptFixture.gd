@abstract
extends RefCounted
## Fixture: a valid abstract script must pass tests/check_scripts.gd. It guards against an
## engine change that would make can_instantiate() return false for abstract classes.


@abstract func value() -> int
