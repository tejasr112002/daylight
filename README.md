# Daylight

A small monochrome ghost keeps your daily priority nearby.

Add tasks for today. The first becomes your current focus; additional tasks
stay in Other tasks. Click Focus beside a task to switch, then Start focusing. The ghost stays visible;
its transparent message appears every 15 minutes for 7 seconds by default:
"Today's priority is" followed by your task.

Adjust the interval from 1–180 minutes and duration from 3–30 seconds.
Adjust Message background down to 0% for a fully transparent message.
Click the ghost for an immediate reminder. Drag it to move it.
Right-click the ghost, or use the Dock or sun menu, to edit your task.
Complete the current task to pause reminders, then choose another task to focus on.
Tasks never switch automatically. Your list and current focus save locally. Hiding the ghost pauses them too.
Changing timing or waking the Mac starts a fresh interval; missed reminders
are never queued. The app must be running for reminders to appear.

Tasks and settings save locally. Tasks carry over between days and are
never cleared automatically. No account, network, or analytics.

Apple Silicon, macOS 14+. Floating windows request fullscreen support,
but system screens and some fullscreen apps may cover them.
Locally signed, not notarized for distribution.

Source is included. Rebuild with: zsh Source/build.sh

## Build

```sh
./Source/build.sh   # builds Daylight.app (macOS 14+, Apple silicon)
```
