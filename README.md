pointer-lock-test
=================

This repo contains a reproducer for pointer capture issues in games for Cosmic-Comp running on wayland.

In several cases, some games seem to fail to lock the pointer onto a game's surface when entering fullscreen.

This repo reproduces what happens (as sniffed on a live game) for Helldivers 2, and turned this knowlege into a test.

## Usage

It is a bit primitive:

- checkout this repository in some folder (e.g. /home/blah/workspace/pointer-lock-test)
- checkout a copy of cosmic-comp in a folder next to it (e.g. /home/blah/workspace/cosmic-comp)
- cd /home/blah/workspace/pointer-lock-test
- run ./run-tests.sh

Assuming you are on a wayland/COSMIC session a nested wayland will be started and start reproducing 3 use cases.

On a "trunk" cosmic-comp, tests fail. On the branch introduced in parallel to this project, tests pass.
