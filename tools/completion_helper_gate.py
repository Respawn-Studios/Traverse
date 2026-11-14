"""Closed compatibility gate for retired compiler qualifications.

Ordinary helper builds keep their normal audits. An old environment marker
cannot select a historical resource envelope in a public source checkout.
"""


def admitted():
    return False


def create_gate(*args, **kwargs):
    raise RuntimeError("Historical helper admission is retired. Use tools/dev.py.")
