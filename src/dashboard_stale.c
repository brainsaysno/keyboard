/* SPDX-License-Identifier: MIT */

// Port of renderStale() in macos/dashboard/render.js, which is the reference: the right half
// draws this screen itself because it has to appear when the Mac app is not running. Plain C
// with no Zephyr or LVGL includes, so tests/test_dashboard.py can compile it on the host and
// compare it with render.js pixel for pixel.

#include "dashboard_stale.h"

#include <stddef.h>
#include <string.h>

#define GLYPH_WIDTH 5
#define GLYPH_HEIGHT 7
// render.js draws a "⊔" (inbox) glyph; the strings below spell it as this byte.
#define INBOX_CHAR '\x01'
#define INBOX "\x01"

struct glyph {
    char ch;
    uint8_t rows[GLYPH_HEIGHT]; // bit 4 is the leftmost column
};

// The render.js FONT glyphs this screen can use; anything else draws UNKNOWN_GLYPH, as there.
static const struct glyph font[] = {
    {' ', {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
    {'A', {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}},
    {'C', {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E}},
    {'D', {0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C}},
    {'E', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F}},
    {'F', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10}},
    {'G', {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F}},
    {'H', {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}},
    {'I', {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E}},
    {'K', {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}},
    {'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F}},
    {'M', {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11}},
    {'N', {0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11}},
    {'O', {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}},
    {'P', {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10}},
    {'R', {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11}},
    {'S', {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E}},
    {'T', {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
    {'V', {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04}},
    {'W', {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A}},
    {'Y', {0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04}},
    {'0', {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}},
    {'1', {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E}},
    {'2', {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}},
    {'3', {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E}},
    {'4', {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}},
    {'5', {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E}},
    {'6', {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}},
    {'7', {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
    {'8', {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}},
    {'9', {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C}},
    {'-', {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00}},
    {INBOX_CHAR, {0x00, 0x11, 0x11, 0x1B, 0x15, 0x11, 0x1F}},
};
static const uint8_t unknown_glyph[GLYPH_HEIGHT] = {0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F};

static const char *const calendar_icon[] = {
    ".#...#.", "#######", "#.....#", "#.#.#.#", "#.....#", "#.#.#.#", "#######",
};

// render.js draws ink (1) on clear (0), and packs ink as a 0 bit: the panel shows light text on
// black.
static void ink(uint8_t *frame, int x, int y) {
    if (x < 0 || y < 0 || x >= DASHBOARD_WIDTH || y >= DASHBOARD_HEIGHT) {
        return;
    }
    frame[y * DASHBOARD_STRIDE + (x >> 3)] &= (uint8_t)~(0x80 >> (x & 7));
}

static void fill(uint8_t *frame, int x, int y, int width, int height) {
    for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
            ink(frame, x + i, y + j);
        }
    }
}

static void hline(uint8_t *frame, int x0, int x1, int y, int step) {
    for (int x = x0; x <= x1; x += step) {
        ink(frame, x, y);
    }
}

static void bmp(uint8_t *frame, int x, int y, const char *const *rows, size_t count) {
    for (size_t j = 0; j < count; j++) {
        for (size_t i = 0; rows[j][i] != '\0'; i++) {
            if (rows[j][i] == '#') {
                ink(frame, x + (int)i, y + (int)j);
            }
        }
    }
}

static const uint8_t *glyph(char ch) {
    for (size_t i = 0; i < sizeof(font) / sizeof(font[0]); i++) {
        if (font[i].ch == ch) {
            return font[i].rows;
        }
    }
    return unknown_glyph;
}

// Glyphs are scale x scale blocks with a scale-pixel gap, as render.js text() with {s: scale}.
static int text_width(const char *str, int scale) {
    int count = (int)strlen(str);
    return count ? count * (GLYPH_WIDTH * scale + scale) - scale : 0;
}

static void text(uint8_t *frame, int x, int y, const char *str, int scale) {
    for (; *str != '\0'; str++, x += GLYPH_WIDTH * scale + scale) {
        const uint8_t *rows = glyph(*str);
        for (int r = 0; r < GLYPH_HEIGHT; r++) {
            for (int c = 0; c < GLYPH_WIDTH; c++) {
                if ((rows[r] >> (GLYPH_WIDTH - 1 - c)) & 1) {
                    fill(frame, x + c * scale, y + r * scale, scale, scale);
                }
            }
        }
    }
}

static void rtext(uint8_t *frame, int right, int y, const char *str) {
    text(frame, right - text_width(str, 1) + 1, y, str, 1);
}

static char *put_uint(char *out, uint32_t n) {
    char digits[10];
    int count = 0;
    do {
        digits[count++] = (char)('0' + n % 10);
        n /= 10;
    } while (n != 0);
    while (count > 0) {
        *out++ = digits[--count];
    }
    return out;
}

// render.js ageLbl(): minutes, then whole hours, days, weeks.
static char *put_age(char *out, uint32_t mins) {
    if (mins < 60) {
        out = put_uint(out, mins);
        *out++ = 'M';
    } else if (mins < 1440) {
        out = put_uint(out, mins / 60);
        *out++ = 'H';
    } else if (mins < 10080) {
        out = put_uint(out, mins / 1440);
        *out++ = 'D';
    } else {
        out = put_uint(out, mins / 10080);
        *out++ = 'W';
    }
    return out;
}

void dashboard_stale_render(uint8_t *frame, bool never, uint32_t mins) {
    static const struct {
        int y;
        const char *label;
    } my_prs[] = {{136, "READY"}, {144, "IN REVIEW"}, {152, "NOT ASKED"}};
    const int right = DASHBOARD_WIDTH - 1;

    for (int y = 0; y < DASHBOARD_HEIGHT; y++) {
        uint8_t *row = frame + y * DASHBOARD_STRIDE;
        memset(row, 0xFF, DASHBOARD_STRIDE);
        row[DASHBOARD_STRIDE - 1] = (uint8_t)(0xFF << (DASHBOARD_STRIDE * 8 - DASHBOARD_WIDTH));
    }

    text(frame, 0, 1, INBOX "-", 1);
    hline(frame, 0, right, 10, 1);
    bmp(frame, 0, 14, calendar_icon, sizeof(calendar_icon) / sizeof(calendar_icon[0]));
    text(frame, 10, 14, "NO DATA", 1);
    text(frame, 0, 26, "--", 5);
    if (never) {
        text(frame, 0, 66, "WAITING FOR", 1);
        text(frame, 0, 76, "MAC APP", 1);
    } else {
        char line[sizeof("LAST 4294967295W AGO")] = "LAST ";
        char *end = put_age(line + strlen(line), mins);
        strcpy(end, " AGO");
        text(frame, 0, 66, line, 1);
        text(frame, 0, 76, "CHECK MAC", 1);
    }
    hline(frame, 0, right, 86, 1);
    text(frame, 0, 89, "TO REVIEW", 1);
    text(frame, 0, 98, "-", 4);
    hline(frame, 0, right, 126, 2);
    text(frame, 0, 128, "MY PRS", 1);
    for (size_t i = 0; i < sizeof(my_prs) / sizeof(my_prs[0]); i++) {
        text(frame, 0, my_prs[i].y, my_prs[i].label, 1);
        rtext(frame, right, my_prs[i].y, "-");
    }
}
