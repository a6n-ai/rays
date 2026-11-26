---
title: "Stats"
description: "See how much you downloaded over the last 7, 30 or 90 days, which days were busiest and which sites you download from most."
---

The **Stats** page adds up your finished downloads. Open it from **Stats** under **Tools** in the sidebar, or from the Rays menu bar panel.

Pick a range at the top: **7 days**, **30 days** or **90 days**. Rays remembers your choice. The page shows:

- **Downloaded**: the total size of the files that finished in the range.
- **Files**: how many finished.
- **Average speed**: the average of the speed samples Rays saved in the range. It shows a dash when there are none.
- A bar chart of bytes downloaded per day. Days with nothing show as empty, so the chart always covers the whole range.
- **Top sites**: the eight sites you downloaded the most bytes from, with file counts and a bar sized against the biggest one. A site is the host of the link without `www.`. Files from an S3 bucket count under `s3://bucket`.

A download counts on the day it finished, by your local time. Downloads that failed or are still running do not count.

Stats count downloads still in your list. If you remove a finished download from the list, it drops out of the totals.

The same numbers are available in Terminal with [`dl stats`](/docs/dl/) and to AI tools through the `stats` tool in [MCP](/docs/mcp/).
