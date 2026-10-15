extends RefCounted
## Counts the push/script errors captured by a gdUnit error assert.
## gdUnit4 6.2.1: is_push_error() finds a matching message but does not count messages. The
## assert's private `_logger` captures every push/script error of the callback regardless of
## suite settings. Reading it pins these tests to gdUnit4 6.2.1: when the addon is updated,
## check this helper first. The addon itself is not modified.


static func entries(notification: GdUnitGodotErrorAssert) -> int:
	var logger: GodotGdErrorMonitor.GdUnitLogger = notification.get("_logger")
	return logger.entries().size()
