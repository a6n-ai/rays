---
title: "Queues and schedules"
description: "Group downloads into queues, run a queue on a schedule, and choose what your Mac does when it finishes."
---

**Queues** group downloads. Each queue has its own icon, speed limit and simultaneous count, and can have a schedule. The sidebar has a **Queues** section with two pages: **Queues** and **Schedules**.

## Queues

**Main** always exists and can't be deleted. New downloads go to Main unless you pick another queue.

The **Queues** page has three tabs: **Queues**, **Activity** and **Settings**. The **Queues** tab lists each queue as a row with its icon, its name, a status line, a switch that turns it on or off, and a **Run now** or **Stop** button. Main has a **Default** tag. Use the Filter and sort bar to narrow the list, and **+** to make a new queue.

Click a queue to open it. Its page has a picker with three parts:

- **Downloads** is the Downloads list, filtered to that queue.
- **Schedule** sets when the queue runs. See [Set a schedule](#set-a-schedule).
- **Options** sets:
  - **Icon & color**.
  - **Simultaneous:** **Same as Rays**, or a number of files at a time.
  - **Speed limit** for the whole queue.
  - **Retry failed downloads**.
  - **Wake the Mac to start**. See [Wake](#wake).
  - **When finished**. See [When finished](#when-finished).

Unsaved changes show a bar with **Revert** and **Save**. The on/off switch saves straight away.

## Activity

**Running now** lists the queues running at the moment. **History** keeps the last 200 runs. Each run ends with an outcome: **Finished**, **Window ended**, **Stopped** or **Rays quit**.

## Schedules

The **Schedules** page has three sections: **Upcoming**, **Paused** and **Not scheduled**. The Filter and sort bar works the same as on the Queues page.

Click **+ New schedule** for a menu with two parts:

- **Add schedule to…** lists the queues that have no schedule. Picking one opens it on **Schedule**, set to every day at 02:00. Nothing is saved until you click **Save**.
- **New queue with a schedule…** asks for a name and makes a queue with a schedule.

## Set a schedule

- **Repeat:** **Once**, **Every day** or **On days**.
- **Start at:** the time the queue starts.
- **Stop at:** optional. Files still downloading pause, and continue the next time the queue runs. Without a stop time, the queue runs until it is done.
- Times use your Mac's local time. A window can cross midnight.
- **Only when:** Wi-Fi (not a phone hotspot), Charging, or Mac is idle (5 minutes).
- **Use best time** fills in **Start at** and **Stop at** with the fastest window from [Speed test and best time](/docs/app/speed/).

If a condition stops being true, the queue waits. It picks up again when the condition returns.

## Best time queue

The **Best time** queue runs downloads in the window when your connection is usually fastest, 01:00–06:00 until Rays has 7 days of speed data. Rays creates it the first time you add downloads with **At best time (01:00–06:00, default)** from the **Download** button's menu.

The first time, Rays asks: "Let Rays test your speed a few times each night for a week? About 1 GB in total."

- **Allow** runs one speed test in each of 00–02, 02–04 and 04–06 for 7 nights, so Rays learns the window quickly. **Stop night tests** in the Speed page's **Settings** ends it early.
- **Not Now** runs no night tests.

Either way the queue uses 01:00–06:00 until Rays has data.

The queue follows the best window once a day. **Follow best time** in its **Schedule** tab keeps it on. If you edit its schedule, **Follow best time** turns off. Turn it back on in the **Schedule** tab.

Any queue's **Schedule** tab has **Use best time**, which fills in the start and stop times once.

## When finished

Choose what your Mac does when the queue is done:

- **Do nothing**
- **Play sound**
- **Quit Rays**
- **Sleep**
- **Lock screen**
- **Shut down**
- **Run command**. Runs as your user account, through zsh. After 1 hour Rays stops the shell. Programs it started may keep running.

**Sleep**, **Shut down** and **Quit Rays** show a 30 second countdown first. You can cancel during the countdown.

## Wake

Wake is off by default. With wake permission, Rays can wake your Mac to start a scheduled queue.

To set it up, open **Queues > Settings** and click **Set Up…** next to **Wake permission**. Your Mac asks for your administrator password once. That permission lets Rays set wake times and nothing else. To take it away, click **Remove**.

Then turn on **Wake the Mac to start** in a queue's **Options**.

Without wake permission, keep your Mac awake and Rays running at the start time.
