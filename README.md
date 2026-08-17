# CrankCave

A cave-crawling horror roguelike for the [Playdate](https://play.date) console, where the crank powers your only light source.

This A personal side project I'm building in my spare time: a crawling horror game inspired by Rodland of Pipes.

## Status

Early prototyping. Not playable yet.

## Concept

You explore a procedurally generated cave with a hand-cranked dynamo lamp. Cranking charges your light — but the dynamo whines while you do it, and things in the dark can hear you. Fast cranking gets you bright light quickly but loud; slow cranking is quiet but leaves you standing still longer.

Light you've spent is remembered permanently, so the core loop is: light up new ground, memorize it, then move through it in the dark to stay quiet.

**Goal:** find the exit of each generated cave. Gems along the way are optional risk/reward.

## Controls (planned)

| Input | Action |
|---|---|
| D-pad | Move |
| Crank | Charge the lamp |
| Dock crank | Kill the light instantly |
| A | Dig through blocked paths |
| B (hold) | View the map of what you've explored |

## Tech

- **Engine:** Playdate SDK (Lua)
- **Platform:** Windows, developed in VS Code
- **Tools:** [Playdate SDK](https://play.date/dev/) + Playdate Simulator

## Roadmap

- [ ] Core movement + crank/light prototype
- [ ] Noise system
- [ ] Cave generation
- [ ] First enemy (Stalker)
- [ ] Second enemy (Blind)
- [ ] Gems + escape condition
- [ ] Playtest and tune

## Running it

```bash
pdc source YourGame.pdx
```
Then open the `.pdx` in the Playdate Simulator.

## License

TBD