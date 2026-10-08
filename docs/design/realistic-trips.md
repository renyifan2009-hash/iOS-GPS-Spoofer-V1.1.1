# Design: realistic trips

Status: built (2026-10-08). The owner asked for "stops at random stoplights"
and for research-backed features in the same spirit, and delegated the
decisions. Code map: [DEVELOPERS.md ▸ Realistic trips](../DEVELOPERS.md#realistic-trips).

## Goal

Routes and the joystick move the way a real person does, so the stream of
positions the iPhone sees looks like a real drive or walk:

- a car **stops at some traffic lights** (random red or green) and at **every
  stop sign**, slows at **give-way** signs, and **slows for turns and curves**;
- it **speeds up and brakes gradually** instead of jumping between speeds;
- it **drives at each road's speed limit**, with the chosen speed as the top
  speed;
- it **waits at the stops you choose** (for example 5 minutes at Stop 1);
- on long drives it **takes breaks**;
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

- **Traffic lights, stop signs, give-way signs, signal crossings and speed
  limits: OpenStreetMap**, through the public Overpass API. It's free and needs
  no key. The app asks for the features within a few metres of the route, in
  pieces of about 15 km, one request at a time, with a clear User-Agent, and
  caches the answers on disk for 30 days. Public servers are tried in turn
  (overpass-api.de, maps.mail.ru, overpass.private.coffee); a busy one gets one
  more try after a short wait, and the one that answers goes first next time.
  If none answers, the app retries after 20 s, 1 and 2 minutes, and meanwhile a
  car treats the route's sharp turns as junctions and sometimes waits there as at
  a red light (35% of turns slower than 7 m/s). The route card says the lights
  couldn't be loaded and offers Try Again.
- **Turns and curves: the route's own shape.** At each point, the radius of the
  curve through the points about 12 m before and after gives the fastest
  comfortable speed: `v = sqrt(lateral acceleration × radius)`.
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
within 5 km is extended by a 10 to 20 minute break; if there's none, the car
pulls over.

**GPS drift**: each update the error moves a little toward a new random value
(a first-order Gauss–Markov process), so it wanders over tens of seconds
instead of jumping. The existing "GPS wobble" setting is its size. It applies
while stopped too, as a real receiver's does.

**Joystick**: the speed eases up and down with the same acceleration values
instead of jumping to full speed and stopping dead.

## Physics values

Picked from the chosen speed: walk up to 2.2 m/s, run up to 4.5 m/s, cycle up
to 9 m/s, drive above that.

| | walk | run | cycle | drive |
|---|---|---|---|---|
| speed up (m/s²) | 0.5 | 1.0 | 1.0 | 1.8 |
| slow down (m/s²) | 0.8 | 1.5 | 2.0 | 2.7 |
| sideways in turns (m/s²) | – | – | 2.5 | 2.7 |
| slowest turn speed (m/s) | – | – | 3.0 | 3.5 |
| traffic lights | wait at red | wait at red | wait at red | wait at red |
| stop signs | – | – | slow to 2 m/s | full stop |
| breaks | – | – | – | every ~2 h |

Lights and signs:

| | value |
|---|---|
| chance a light is red when you reach it | 45% (car), 50% (on foot) |
| red light wait | 8 to 60 s, average about 34 s |
| stop sign | full stop, then 1.5 to 3.5 s |
| give-way | slow to 4 m/s; 25% of the time a full stop of 1 to 3 s |
| break | 10 to 20 min after about 2 h of driving |

These are the starting values; the research notes at the end give the sources
and any changes.

## What the app shows

- **Route panel**: a "Drive like a real person" switch (on by default) under
  "Follow roads & paths", with one line about it and the status of the map data:
  "23 traffic lights and 9 stop signs on this route", "Looking for traffic
  lights…", or "Couldn't load traffic lights. It still slows for turns. [Try
  Again]". Without Follow roads, it says to turn that on to find lights.
- **Settings ▸ Movement ▸ Realistic trips**: switches for traffic lights, stop
  signs, turns, speed limits and breaks, plus the existing speed variation and
  GPS wobble.
- **Stops**: each stop's row has a wait menu (none, 30 s, 1, 2, 5, 10 or 30
  min) and shows "Waits 5 min". Waits are saved with routes.
- **Status panel**: while stopped, the Speed figure becomes the reason and the
  time left ("Red light · 0:34", "Stop sign", "Waiting at Stop 1 · 4:12",
  "Break · 12:40"), so the panel doesn't change size.
- **Map**: small traffic-light and stop-sign markers along the route.
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

The physics values (acceleration 1.8 m/s², braking 2.7 m/s², sideways 2.7 m/s²)
and the red-light odds (45%, 8–60 s) are conventional starting points for
comfortable urban driving; a parallel research pass was asked to source or
correct them.
