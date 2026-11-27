#!/bin/sh

# The fixture filesystem has no immutable entries unless a test overrides this
# read-only probe. An I/O error and a genuinely clear flag are distinct states.
if [ "${0##*/}" = lsattr ]; then printf '%s\n' '---------------------- fixture'; exit 0; fi
# A real service command or HTTP client must never be reached by unit tests.
printf 'test isolation: unexpected external command: %s\n' "${0##*/}" >&2
exit 125
