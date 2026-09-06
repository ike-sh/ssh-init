#!/bin/sh

# A real service command or HTTP client must never be reached by unit tests.
printf 'test isolation: unexpected external command: %s\n' "${0##*/}" >&2
exit 125
