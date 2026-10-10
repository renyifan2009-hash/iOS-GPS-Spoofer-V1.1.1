# Design: realistic trips

Status: built (2026-10-08), then tuned the same day to the research notes at
the end. The owner asked for "stops at random stoplights" and for
research-backed features in the same spirit, and delegated the decisions. Code
map: [DEVELOPERS.md ▸ Realistic trips](../DEVELOPERS.md#realistic-trips).

## Goal

Routes and the joystick move the way a real person does, so the stream of
positions the iPhone sees looks like a real drive or walk:

- a car **stops at some traffic lights** (random red or green, sometimes behind
  a short queue), **stops or rolls slowly through stop signs**, slows at
  **give-way** signs, and **slows for turns, curves and speed bumps**;
- lights and signs only count when they **face the route's direction**;
- it **speeds up and brakes gradually** instead of jumping between speeds;
- it **drives at each road's speed limit**, with the chosen speed as the top
  speed;
- it **waits at the stops you choose** (for example 5 minutes at Stop 1);
- on long drives it **takes breaks**, and on foot it **pauses now and then**;
- a walker **waits at crossing lights**;
- the GPS position **drifts slowly** like a real receiver, instead of jumping
  randomly every update.

The app shows what's happening ("Red light · 0:34"), marks the lights and stop
signs on the map, and gives an arrival time that includes the stops.

## Non-goals

- Live traffic or real signal timing. There's no public source for either, so
  lights are random with realistic odds and waits.
- Setting speed, course, altitude or accuracy on the iPhone. Apple's developer
  location service only takes latitude and longitude.
- Lane-level positions.

## Where the data comes from

- **Traffic lights, stop signs, give-way signs, signal crossings, speed bumps
  and speed limits: OpenStreetMap**, through the public Overpass API. It's free and needs
  no key. The app asks for the features within a few metres of the route, in
  pieces of about 15 km, one request at a time, with a clear User-Agent, and
  caches the answers on disk for 30 days. Public servers are tried in turn
  (overpass-api.de, maps.mail.ru, overpass.private.coffee); a busy one gets one
  more try after a short wait, and the one that answers goes first next time.
  If none answers, the app retries after 20 s, 1 and 2 minutes, and meanwhile a
  car treats the route's sharp turns as junctions and sometimes waits there as at
  a red light (35% of turns slower than 7 m/s). The route card says the lights
  couldn't be loaded and offers Try Again.
- **Which way a sign faces: the roads under the route** (loaded for driving,
  with their node ids). A `traffic_signals:direction` or `direction` tag says
  it outright. An untagged stop or yield sign is for traffic heading into the
  junction just past it (within 40 m), since mappers put signs on the approach.
  A sign on a road the route only crosses is a side street's and doesn't count.
  Each direction keeps the first light it meets at a junction.
- **Turns and curves: the route's own shape.** At a sharp corner, the radius of
  the circle through the points 16 m before and after it gives the fastest
  comfortable speed: `v = sqrt(lateral acceleration × radius)`. A car cuts a
  corner drawn as a point, so a right angle counts as an 11 m arc (about
  17 km/h). A gentle bend is spread over its segments, up to 100 m.
- **Everything else: fixed physics per kind of movement** (walk, run, cycle,
  drive), picked from the chosen speed. The values are in the table below.

## How a trip is planned

Everything below lives in SpooferCore, has no UI, and has unit tests.

A route plays as **laps**: the route once, the route closed into a loop, or the
route out and back. For each lap the planner makes the random choices up front
(which lights are red, how long each wait is), so the arrival time for the lap
is exact. A new lap gets new choices.

The plan is a sorted list of **constraints** along the lap:

| Constraint | Effect |
|---|---|
| stop (red light, stop sign, your stop, a break, the destination) | speed 0 at that point, then wait N seconds |
| speed limit point (a curve, a give-way sign, a U-turn at the end of a back-and-forth) | at most V m/s at that point |
| speed zone (a road's limit) | the cruise speed between two points |

**Each tick** (every update, about 0.5 s) the controller picks the next speed:

1. If it's waiting at a stop, count the wait down and stay put.
2. The target is the cruise speed here: the zone's limit times a per-trip
   "driver" factor, capped at the chosen top speed, times the existing slow
   random speed variation.
3. For every constraint within braking range ahead, the speed must still allow
   a comfortable stop or slow-down in time: `v ≤ sqrt(v_limit² + 2·b·distance)`.
4. Speed up toward the target at `a`, or brake toward it at up to `1.6·b`.
5. Move `(v_old + v_new) / 2 × dt` metres. If that passes an active stop, end
   exactly on it with speed 0 and start its wait.

**Arrival time** comes from the same constraints: a backward pass (what speed
each point allows, given the braking ahead), a forward pass (what speed the
trip can actually reach, given the acceleration), then the time for each
stretch from the usual speed-up / cruise / slow-down shape, plus the waits.
Before a route starts, the lap time shown is the average of several sampled
laps.

**Breaks** (driving only): after about two hours of driving, the next stop
within 5 km is extended by a 13 to 22 minute break; if there's none, the car
pulls over.

**GPS drift**: each update the error moves a little toward a new random value
(a first-order Gauss–Markov process with a 60 s time constant), so it wanders
over about a minute instead of jumping. The existing "GPS wobble" setting is its
size. It applies while stopped too, as a real receiver's does.

**Joystick**: the speed eases up and down with the same acceleration values
instead of jumping to full speed and stopping dead.

**Time-of-day traffic** (driving, opt-in): cruising speed is scaled by a daily
congestion curve (`Congestion`) — a weekday morning peak near 8am and a worse
evening peak near 5–6pm slow a drive to about 55% of the limit, with a mild
midday lull, free-flowing nights, and no commute peaks on weekends. It scales
cruising speed only; the waits at lights, signs and your stops don't change, and
it re-reads the clock each time the settings are rebuilt. There's no live-traffic
source, so it's a believable daily pattern, not the real congestion on a road
right now. Off by default (Settings ▸ Realistic trips, or the CLI `--traffic`
flag with `--realistic`).

## Physics values

Picked from the chosen speed: walk up to 2.2 m/s, run up to 4.5 m/s, cycle up
to 9 m/s, drive above that.

| | walk | run | cycle | drive |
|---|---|---|---|---|
| speed up (m/s²) | 0.5 | 1.0 | 1.0 | 1.8 |
| slow down (m/s²) | 0.8 | 1.5 | 2.0 | 2.7 |
| sideways in turns (m/s²) | – | – | 2.5 | 2.0 |
| slowest turn speed (m/s) | – | – | 3.0 | 3.5 |
| traffic lights | wait at red | wait at red | wait at red | wait at red |
| stop signs | – | – | slow to 2 m/s | full stop half the time, else roll at 1–2.5 m/s |
| speed bumps | – | – | – | hump 18 mph, table 23, cushion 25, bump 8 |
| breaks | 5–25 s pause every 3–8 min | same as walking | – | 13–22 min every ~2 h |

Lights and signs:

| | value |
|---|---|
| a light's timing (made up per pass) | cycle 60–120 s; green 40–60% of it for traffic, 25–55% for someone on foot |
| chance it's red when you get there | 1 − green share: about 50% (car), 60% (on foot) |
| red light wait | what's left of the red, so anywhere from 0 to 72 s; about 27 s on average with the queue |
| queue | cars that came earlier in the red wait ahead: about one per 15 s of red (at most 5), 7.5 m each; each pulls away 1.5 s after the one before |
| turns green as you arrive | under 3 s of red left and nobody waiting: slow to 2–5 m/s, don't stop |
| on foot | under 2 s left: keep going; otherwise wait, plus 1.5–4 s to step off |
| crossing light on its own | traffic: red 1 pass in 4, for 2–25 s; on foot: like a light |
| stop sign (car) | full stop 50% of the time, then 0.8–3.2 s (about 1.9 s); otherwise a rolling stop at 1–2.5 m/s |
| give-way | slow to 4 m/s; 30% of the time a full stop of 1 to 4 s |
| no map data | a sharp turn has lights 70% of the time (so about 35% of turns are a red light) |
| break | 13 to 22 min after about 2 h of driving |

The research notes at the end give the sources.

## What the app shows

- **Route panel**: a "Drive like a real person" switch (on by default) under
  "Follow roads & paths", with one line about it and the status of the map data:
  "23 traffic lights and 9 stop signs on this route", "Looking for traffic
  lights…", or "Couldn't load traffic lights. It still slows for turns. [Try
  Again]". Without Follow roads, it says to turn that on to find lights.
- **Settings ▸ Movement ▸ Realistic trips**: switches for traffic lights, stop
  signs, turns and speed bumps, speed limits and breaks, plus the existing
  speed variation and GPS wobble.
- **Stops**: each stop's row has a wait menu (none, 30 s, 1, 2, 5, 10 or 30
  min) and shows "Waits 5 min". Waits are saved with routes.
- **Status panel**: while stopped, the Speed figure becomes the reason and the
  time left ("Red light · 0:34", "Stop sign", "Waiting at Stop 1 · 4:12",
  "Break · 12:40"), so the panel doesn't change size.
- **Map**: small traffic-light, stop-sign and (driving) speed-bump markers
  along the route, only for the ones the route meets in its direction.
- **Lap time**: "about 5m 25s", including the expected stops.

## Engines and the command line

- **Live engine** (iOS 17+, and iOS 16 streaming): the controller runs every
  tick, as above.
- **Classic engine** (pymobiledevice3 replays a GPX file): the GPX is built by
  running the same controller in one-second steps. A stop is the same point
  repeated over time, which pymobiledevice3 holds.
- **Command line**: `iosgpsspoof route --realistic` builds the same kind of
  track.

## Settings and saved data

- Preferences: `realisticTrips` (master, on), `trafficLights`, `stopSigns`,
  `slowForTurns`, `speedLimits`, `drivingBreaks` (all on).
- Each waypoint has a `wait` (seconds). The route draft and saved routes store
  the waits as an optional array, so older files still load.

## Testing

Unit tests (no network): speed-limit parsing; curve speeds for a right-angle
corner and a straight line; the controller on a straight route with a stop
(never above the limits, accelerations within the values, stops within 1 m,
waits the right time, arrival time within 3% of the prediction); lap
randomness with a fixed seed; back-and-forth mirroring; parsing and matching a
saved Overpass answer; the drift's spread and how fast it changes; the timed
GPX track for the classic engine.

In the app: the debug snapshot mode plays a road loop with realism on;
`SNAPSHOT-STATS` reports the controller's state; screenshots show the status
panel at a red light and the markers on the map (CI draws the map).

## Research notes

Measured while building (2026-10-08):

- The Cupertino test loop (about 7 mi through Apple Park and the arterials
  around it) has 37 mapped traffic lights, 3 stop signs and speed limits for
  most of its length. A crossing light next to a junction's lights is folded
  into that junction, so a car isn't stopped twice at one corner.
- Overpass answered our query in about 15 s from maps.mail.ru. From a Mac on
  Cloudflare WARP, overpass-api.de never accepted the connection and the
  private.coffee and kumi.systems instances returned errors, which is why the
  loader tries several servers and the planner can guess junctions.
- With real data, a 69 mph top speed on that loop settles at the roads' 30–40
  mph limits, and a lap takes about half an hour with the expected red lights.

After the direction tuning (same day), that loop counts 31 lights the route
meets and 4 stop signs. One junction showed why it matters: Mariani Avenue has
a light for each approach, 34 m apart (each tagged with its direction). The
first version counted both and stopped twice, the second time after crossing
the junction. Now the car stops once, at its own light.

### Sources

A research pass collected these (2026-10-08). "Derived" means our own
arithmetic on the cited inputs.

- **Pulling away and braking.** Drivers pulling away from a stop averaged
  0.21 g over the first 3 s
  ([Kodsi & Muttart 2010](https://jsheld.com/uploads/Modeling-Passenger-Vehicle-Acceleration-Profiles-from-Naturalistic-Observations-and-Driver-Testing-at-Two-way-stop-Controlled-Intersections.pdf)).
  Yellow-light timing assumes 3.0 m/s² of braking
  ([FHWA Signal Timing Manual, ch. 5](https://ops.fhwa.dot.gov/publications/fhwahop08024/chapter5.htm)).
  We kept 1.8 m/s² (an average over a whole speed-up, which tails off at speed)
  and 2.7 m/s².
- **Sideways in turns.** Left-turning drivers' peak sideways acceleration
  averaged 0.17 g, and 81% stayed under 0.25 g
  ([Carter 2019](https://jsheld.com/uploads/PDFs/Lateral-and-Tangential-Accelerations-of-Left-Turning-Vehicles-from-Naturalistic-Observations.pdf)),
  so a car now takes 2.0 m/s² instead of 2.7. Left turns without stopping run
  6.0–6.6 m/s in the same study; with an 11 m arc our right angle is 4.8 m/s,
  and a 20 m left-turn arc would be 6.3 m/s (derived).
- **Light timing.** Cycles of 120 s or less are preferred, 60 s is the
  minimum, and 60–90 s or 90–135 s are typical for minor or major arterials
  ([Signal Timing Manual, ch. 6](https://ops.fhwa.dot.gov/publications/fhwahop08024/chapter6.htm)).
  With random arrivals, the share arriving on green is the green share of the
  cycle ([HCM arrival type 3](https://archive.nptel.ac.in/content/storage2/courses/105101008/543_TrProg/point3/point.html)),
  and the average delay over all arrivals is r²/2C
  ([FHWA](https://www.fhwa.dot.gov/publications/research/safety/pedbike/98107/section4.cfm)).
  So a car that stops waits anywhere from 0 to the whole red (derived), which
  replaced the fixed 8–60 s.
- **Queues.** A queue of one car per 15 s of red is our assumption (about 240
  cars an hour in the lane), not a measured value; 7.5 m per car and 1.5 s
  between cars pulling away are the usual rules of thumb, not cited.
- **On foot at lights.** Pedestrians step off 2.5 s (median) after the walk
  signal starts, and the walk signal typically lasts 7 s
  ([FHWA](https://www.fhwa.dot.gov/publications/research/safety/pedbike/98107/section2.cfm),
  [Signal Timing Manual, ch. 5](https://ops.fhwa.dot.gov/publications/fhwahop08024/chapter5.htm)).
- **Stop signs.** Roadside counts found 35% full stops, 52% rolling (5 mph or
  less) and 13% no stop
  ([TRF](https://trforum.org/wp-content/uploads/2017/04/2012v51n3_07_StopControlledIntersections.pdf));
  dashcams found 21% / 62% / 17% ([arXiv](https://arxiv.org/pdf/2207.07341));
  with frequent cross traffic, 73% stopped fully, and rolling stops ran at
  1–2 m/s (Kodsi & Muttart). After stopping, drivers took 1.82 s on average to
  press the accelerator ([FHWA via TRID](https://trid.trb.org/View/273874)).
  Hence half full stops, 0.8–3.2 s, else a 1–2.5 m/s roll.
- **Yield.** Only 30.2% of right-on-red drivers stop fully
  ([naturalistic study](https://trid.trb.org/View/1495096)); we use 30% for
  give-way signs.
- **Speed bumps.** After a speed hump goes in, 85th-percentile speeds are most
  often 25–27 mph, and about 5 mph higher (30–32 mph) at speed tables
  ([FHWA Traffic Calming ePrimer, module 4](https://highways.dot.gov/safety/speed-management/traffic-calming-eprimer/module-4-effects-traffic-calming-measures-motor)).
  Typical drivers go slower than the 85th percentile, and slowest on the device
  itself, so we use 18 mph for a hump and 23 for a table. Cars "drive
  considerably faster over speed cushions than speed humps or speed tables"
  ([Cambridgeshire County Council](https://www.cambridgeshire.gov.uk/residents/travel-roads-and-parking/roads-and-pathways/improving-the-local-highway/speeding/vertical-speeding-treatments)),
  so a cushion is 25 mph. A short sharp bump is 8 mph. These are our estimates
  from those figures, not measured speeds.
- **Breaks.** The UK Highway Code (rule 91) asks for at least 15 minutes every
  2 hours ([gov.uk](https://www.gov.uk/guidance/the-highway-code/rules-for-drivers-and-motorcyclists-89-to-102)).
  Car drivers at a Minnesota rest area stayed 13.9–17.9 minutes
  ([MnDOT survey](https://www.dot.mn.gov/restareas/pdf/user-surveys/1992MarionUserSurvey.pdf)).
  Hence 13–22 minutes.
- **GPS drift.** Phones are typically within about 4.9 m under open sky
  ([GPS.gov, archived](https://web.archive.org/web/20241221041257/https://www.gps.gov/systems/gps/performance/accuracy/)),
  and their errors are strongly correlated from one second to the next
  ([Rostami et al.](https://www.winlab.rutgers.edu/~gruteser/papers/VTC_camera_ready.pdf)).
  The PX4 drone simulator models GPS with a 60 s correlation time
  ([PX4 constants](https://github.com/PX4/PX4-SITL_gazebo-classic/blob/main/include/gazebo_gps_plugin.h)),
  so the drift's time constant went from 30 s to 60 s.
- **OpenStreetMap tags and etiquette.** One-way lights and signs use
  `traffic_signals:direction` and `direction`; stop and yield signs go on the
  approach, not the junction
  ([traffic_signals](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dtraffic_signals),
  [stop](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dstop)). The Overpass
  policy asks clients to wait 30 s after a 429
  ([Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API)).
- **Default speed limits.** OSRM's car profile uses lower speeds for untagged
  roads (residential 25 km/h), but those are travel speeds with junction delays
  built in ([car.lua](https://github.com/Project-OSRM/osrm-backend/blob/master/profiles/car.lua)).
  We model stops and turns ourselves, so our defaults stay at typical legal
  limits (residential 40 km/h).
