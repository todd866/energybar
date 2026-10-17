# Vehicle cloud cache

Cloud helpers supply `soc`, `at` (actual vehicle measurement time), `checkedAt`
(helper check time), optional range/source, and an error on failure. Both clocks
must be fresh. Missing, malformed or future measurement time cannot supply a
battery anchor, even when the request just succeeded.

The existing private inference store also retains one `lastKnownSOC` record for
display: percentage, observation time, source and whether it was estimated.
Losing authentication, a telemetry gap, restart or unplug does not turn that
historical value into zero. It remains separate from `hasSOC`, current inference
and ETA inputs. The Car gauge uses muted blue and the existing stale-clock symbol;
Details identifies the last-known value and timestamp. A fully unknown level hides
the gauge rather than replacing it with charging power. Explicit Clear vehicle
data removes the historical record along with the active anchor. A new manual
reading remains labelled manual; zero charging power never establishes full.

`tools/geely_snapshot.py` is a pure optional Geely payload adapter. It has no
credentials, authentication, network calls or vehicle controls. It preserves
Geely's epoch-millisecond upload time and rejects invalid SoC/range values.
Supporting this provider does not identify any repository owner's vehicle.

More → Vehicle → Vehicle cloud exposes the configured cache's status even when
an inferred/manual level is available. The dialog can open the existing manual
anchor editor. It does not promise reauthentication or provision another device.
Phone and helper sessions are separate. Session restoration must be reviewed
against the existing provider integration; no credentials are included here.
