# Independent household telemetry

The Evnex site CT's signed `supplyActivePower` is grid flow, independent of the
car's charging power. Fronius PV alone is insufficient to recover home load:
time-aligned home = PV + grid import − car AC power. Missing grid is unknown.

The normal charge-point detail route carries cached meter uploads. Only
`connectors[].meter.updatedDate` establishes power age. A recent status check,
HTTP response, document modification or `lastHeard` cannot freshen the meter.
A known idle connector may omit car watts without invalidating fresh numeric CT
power; idle sets car power to zero, never site power.

An existing read-only `get-energy-meter-reading` RPC can return a separate
`data.timestamp`, `supplyActivePower` and `chargingActivePower`. Its behavior
while unplugged needs validation on each installation. HTTP 200/Accepted alone
is not evidence of a new measurement; compare source times and readings across
bounded requests. Do not replace measurement time with local retrieval time.

Version 0.5.1 removed 30-second live-meter polling after a quota failure. That
429 had also gated detail/session reads; those schedules are now independent.
No numeric long-term allowance is established here. Do not enable an unattended
fallback without verifying both idle behavior and a sustainable vendor allowance.
A slow fallback can provide occasional snapshots but must retain visible age,
normal stale thresholds and gaps in energy integration.

The maintained [residential client](https://github.com/hardbyte/python-evnex)
exposes request/response reads. No supported household subscription was verified.
The separate [enterprise API](https://docs.evnex.com/reference/authorization-1)
requires different credentials; its existence is not permission to reuse a
residential token there. An independently exposed inverter site meter is another
possible source, but PV production by itself is not a substitute.
