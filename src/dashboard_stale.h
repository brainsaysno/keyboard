/* SPDX-License-Identifier: MIT */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "dashboard_protocol.h"

// Draws the "no data" screen into frame (DASHBOARD_FRAME_SIZE bytes, packed as in
// dashboard_protocol.h), pixel for pixel what render.js draw({stale: ...}) packs: "waiting for
// Mac app" when never is set, otherwise the minutes since the last frame.
void dashboard_stale_render(uint8_t *frame, bool never, uint32_t mins);
