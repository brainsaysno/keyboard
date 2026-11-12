/* SPDX-License-Identifier: MIT */

#pragma once

// Work dashboard on the right half's nice!view. The Mac app renders the whole screen
// (macos/dashboard/render.js) and streams it Mac -> left half -> right half; every hop carries
// the same messages, one per GATT write, multi-byte values little-endian:
//   DATA    [0x01][offset lo][offset hi][bytes...]  copy bytes into the back buffer at offset
//   PRESENT [0x02][crc lo][crc hi]                  show the back buffer if its CRC-16/CCITT-FALSE
//                                                  (crc16_itu_t(0xFFFF, ...)) equals crc
// Frame: 68 x 160 portrait, row-major, DASHBOARD_STRIDE bytes per row, most significant bit =
// leftmost pixel, 1 = black panel pixel, pad bits 0.
//
// No Zephyr includes: dashboard_stale.c and the host tests use this header too.

#include <stdbool.h>
#include <stdint.h>

#define DASHBOARD_WIDTH 68
#define DASHBOARD_HEIGHT 160
#define DASHBOARD_STRIDE ((DASHBOARD_WIDTH + 7) / 8)
#define DASHBOARD_FRAME_SIZE (DASHBOARD_STRIDE * DASHBOARD_HEIGHT)

#define DASHBOARD_MSG_DATA 0x01
#define DASHBOARD_MSG_PRESENT 0x02
// Type byte plus the 16-bit offset (DATA) or CRC (PRESENT).
#define DASHBOARD_HEADER_SIZE 3
// ATT MTU 65 minus the write's opcode and handle; the Mac never sends more.
#define DASHBOARD_MAX_MESSAGE 62

// Without a matching PRESENT for this long the right half shows its "no data" screen, and then
// redraws it every DASHBOARD_STALE_STEP_MS with the minutes since the last one.
#define DASHBOARD_FRESH_MS 120000
#define DASHBOARD_STALE_STEP_MS 60000

// 8F2A1Cxx-6D3B-4B8E-9C71-5E0A3B9D1F60, as bytes for Zephyr's BT_UUID_INIT_128.
#define DASHBOARD_UUID(first) BT_UUID_128_ENCODE(first, 0x6d3b, 0x4b8e, 0x9c71, 0x5e0a3b9d1f60)
// Left half, written by the Mac.
#define DASHBOARD_MAC_SERVICE_UUID DASHBOARD_UUID(0x8f2a1c40)
#define DASHBOARD_MAC_CHRC_UUID DASHBOARD_UUID(0x8f2a1c41)
// Right half, written by the left half over the split connection.
#define DASHBOARD_SPLIT_SERVICE_UUID DASHBOARD_UUID(0x8f2a1c50)
#define DASHBOARD_SPLIT_CHRC_UUID DASHBOARD_UUID(0x8f2a1c51)

// True for a DATA message that stays inside the frame or a PRESENT message.
static inline bool dashboard_message_valid(const uint8_t *msg, uint16_t len) {
    if (len == 0) {
        return false;
    }
    switch (msg[0]) {
    case DASHBOARD_MSG_DATA:
        return len > DASHBOARD_HEADER_SIZE &&
               (msg[1] | msg[2] << 8) + (len - DASHBOARD_HEADER_SIZE) <= DASHBOARD_FRAME_SIZE;
    case DASHBOARD_MSG_PRESENT:
        return len == DASHBOARD_HEADER_SIZE;
    default:
        return false;
    }
}
