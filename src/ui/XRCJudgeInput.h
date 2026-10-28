#pragma once

// UI input only; the gameplay judgement engine is unchanged.
static inline int xrc_judge_parse_windows(const char *const text[4], int values[4]) {
    int previous = 0;
    for (int i = 0; i < 4; i++) {
        const char *s = text[i];
        int value = 0, length = 0;
        if (!s || !*s) return 0;
        for (; *s; s++) {
            if (*s < '0' || *s > '9' || ++length > 4) return 0;
            value = value * 10 + *s - '0';
        }
        if (value <= previous || value > 2000) return 0;
        values[i] = previous = value;
    }
    return 1;
}

static inline void xrc_judge_clamp_windows(int values[4]) {
    for (int i = 0; i < 4; i++) {
        if (values[i] < i + 1) values[i] = i + 1;
        if (values[i] > 1997 + i) values[i] = 1997 + i;
        if (i && values[i] <= values[i-1]) values[i] = values[i-1] + 1;
    }
}
