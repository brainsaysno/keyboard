/* SPDX-License-Identifier: MIT */

#pragma once

// Text the Mac companion app sends for the right-half display, as numbered slots of ASCII.
//
// Mac -> left half: GATT writes of [slot][offset][total][text bytes...], one per chunk, so the
// Mac can split a text to fit the link's MTU.
//
// Left half -> right half: one split behavior invocation of MAC_LINK_BEHAVIOR_NAME per
// MAC_LINK_RELAY_CHUNK bytes, because that is the only central-to-peripheral message in ZMK v0.3
// that carries arbitrary values:
//   position = slot | byte count << 4
//   param1   = offset | total << 8 | byte0 << 16 | byte1 << 24
//   param2   = byte2 | byte3 << 8 | byte4 << 16 | byte5 << 24

// Split messages carry at most 8 characters of behavior name.
#define MAC_LINK_BEHAVIOR_NAME "mac_txt"

#define MAC_LINK_SLOT_COUNT 4
#define MAC_LINK_MAX_TEXT 120
#define MAC_LINK_RELAY_CHUNK 6

enum mac_link_slot {
    MAC_LINK_SLOT_TIME,
    MAC_LINK_SLOT_DETAIL,
    MAC_LINK_SLOT_PHRASE,
    MAC_LINK_SLOT_AUTHOR,
};
